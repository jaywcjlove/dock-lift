//
//  DockActivationMonitor.swift
//  DockLift
//
//  Observes Dock clicks + app activation and lifts windows onto the Dock screen.
//
//  Important multi-display case: if the target app is *already* frontmost (its
//  window sits on another display), `didActivateApplication` does **not** fire
//  when the Dock icon is clicked. We therefore also handle a delayed re-click
//  of the current frontmost app after a Dock-region mouse down.
//
//  Event ordering note (critical on recent macOS):
//  `NSEvent.addGlobalMonitorForEvents` delivers copies *after* the event has
//  already been handled by the Dock. App activation therefore often races
//  ahead of our click recorder. Lifts are deferred briefly so Dock-click
//  metadata (display + ⇧) is available before we act.
//

import AppKit
import Combine
import CoreGraphics
import Foundation
import os.log

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "DockLift", category: "DockMonitor")

/// Configuration snapshot used for a single activation handling pass.
struct LiftPolicy: Sendable {
    var isEnabled: Bool
    var onlyWhenDockClick: Bool
    var includeMinimizedWindows: Bool
    var preferMoveToCurrentSpace: Bool
    var moveToDockScreen: Bool
    var useMinimizeFallback: Bool
    var ignoredBundleIdentifiers: Set<String>
}

/// Thread-safe snapshot of the most recent Dock-strip interaction.
/// Updated from global event-monitor callbacks (may run off the main actor).
private final class DockClickState: @unchecked Sendable {
    private let lock = NSLock()
    private var clickedAt: Date?
    private var displayID: CGDirectDisplayID?
    private var shiftHeld = false
    private var generation: UInt64 = 0

    struct Snapshot: Sendable {
        var clickedAt: Date?
        var displayID: CGDirectDisplayID?
        var shiftHeld: Bool
        var generation: UInt64
    }

    /// Begin a new Dock press (mouse down). Resets shift unless this down has ⇧.
    func beginClick(displayID: CGDirectDisplayID?, shiftHeld: Bool) {
        lock.lock()
        defer { lock.unlock() }
        clickedAt = Date()
        self.displayID = displayID
        self.shiftHeld = shiftHeld
        generation &+= 1
    }

    /// Refresh an in-flight Dock press (mouse up / drag within strip).
    func refreshClick(displayID: CGDirectDisplayID?, shiftHeld: Bool) {
        lock.lock()
        defer { lock.unlock() }
        clickedAt = Date()
        if let displayID {
            self.displayID = displayID
        }
        if shiftHeld {
            self.shiftHeld = true
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            clickedAt: clickedAt,
            displayID: displayID,
            shiftHeld: shiftHeld,
            generation: generation
        )
    }

    func isRecent(within interval: TimeInterval = 1.0) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let clickedAt else { return false }
        return Date().timeIntervalSince(clickedAt) < interval
    }
}

/// Listens for `NSWorkspace.didActivateApplicationNotification` and Dock clicks.
@MainActor
final class DockActivationMonitor: ObservableObject {
    @Published private(set) var lastLiftedAppName: String?
    @Published private(set) var lastEventDescription: String = String(localized: "Waiting for Dock activity…")
    @Published private(set) var isRunning = false

    private let windowManager: WindowManager
    private var activationObserver: NSObjectProtocol?
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?

    private let dockClick = DockClickState()

    /// Debounce repeated handling for the same pid.
    private var lastHandled: (pid: pid_t, at: Date)?
    /// Serial generation so delayed tasks can be cancelled logically.
    private var dockClickGeneration: UInt64 = 0
    private var activationGeneration: UInt64 = 0

    /// Supplies the current policy (read from settings by the view model).
    var policyProvider: (() -> LiftPolicy)?

    init(windowManager: WindowManager? = nil) {
        self.windowManager = windowManager ?? .shared
    }

    // MARK: - Lifecycle

    func start() {
        if isRunning {
            // Re-install monitors if they failed (e.g. registered before AX trust).
            ensureEventMonitorsInstalled()
            return
        }
        isRunning = true
        installActivationObserver()
        ensureEventMonitorsInstalled()
        lastEventDescription = String(localized: "Monitoring Dock activations")
        log.info("DockActivationMonitor started")
    }

    /// Tear down and start again — call after Accessibility is newly granted.
    func restart() {
        stop()
        start()
    }

    func stop() {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        removeEventMonitors()
        isRunning = false
        lastEventDescription = String(localized: "Monitoring paused")
        log.info("DockActivationMonitor stopped")
    }

    private func installActivationObserver() {
        guard activationObserver == nil else { return }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                self?.handleActivation(notification)
            }
        }
    }

    /// Global monitors only — local monitors break Settings hit-testing.
    /// Must be installed **after** `AXIsProcessTrusted()` is true or they may
    /// return `nil` and never receive Dock clicks.
    private func ensureEventMonitorsInstalled() {
        if mouseDownMonitor == nil {
            mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                guard let self else { return }
                let location = NSEvent.mouseLocation
                let shift = event.modifierFlags.contains(.shift)
                // Record *synchronously* so a later main-queue activation task
                // (scheduled with a short delay) can see this click.
                self.recordPotentialDockClickSync(at: location, shiftHeld: shift)
                Task { @MainActor [weak self] in
                    self?.scheduleFrontmostReclickIfNeeded()
                }
            }
            if mouseDownMonitor == nil {
                log.error("Failed to install global mouse-down monitor (Accessibility?)")
            }
        }

        if mouseUpMonitor == nil {
            mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
                guard let self else { return }
                let location = NSEvent.mouseLocation
                let shift = event.modifierFlags.contains(.shift)
                self.recordPotentialDockMouseUpSync(at: location, shiftHeld: shift)
            }
            if mouseUpMonitor == nil {
                log.error("Failed to install global mouse-up monitor (Accessibility?)")
            }
        }
    }

    private func removeEventMonitors() {
        if let mouseDownMonitor {
            NSEvent.removeMonitor(mouseDownMonitor)
            self.mouseDownMonitor = nil
        }
        if let mouseUpMonitor {
            NSEvent.removeMonitor(mouseUpMonitor)
            self.mouseUpMonitor = nil
        }
    }

    // MARK: - Click tracking (may run off main actor)

    /// Synchronous Dock hit-test + state update (safe from monitor callbacks).
    nonisolated private func recordPotentialDockClickSync(at location: CGPoint, shiftHeld: Bool) {
        guard let dockScreen = DockGeometry.screenHostingDock(at: location) else { return }
        let displayID = ScreenCoordinates.displayID(of: dockScreen)
        dockClick.beginClick(displayID: displayID, shiftHeld: shiftHeld)
        log.debug("Dock click on display \(displayID, privacy: .public) shift=\(shiftHeld, privacy: .public)")
    }

    nonisolated private func recordPotentialDockMouseUpSync(at location: CGPoint, shiftHeld: Bool) {
        // If the press started on the Dock, keep the dock-click timestamp fresh
        // through mouse-up (activation often lands between down and up).
        guard dockClick.isRecent(within: 0.9) else { return }
        if DockGeometry.screenHostingDock(at: location) != nil || DockGeometry.contains(location) {
            let displayID = DockGeometry.screenHostingDock(at: location)
                .map { ScreenCoordinates.displayID(of: $0) }
            dockClick.refreshClick(displayID: displayID, shiftHeld: shiftHeld)
        }
    }

    /// Already-frontmost apps do not emit didActivateApplication when their
    /// Dock icon is clicked. Schedule a follow-up after the click settles.
    private func scheduleFrontmostReclickIfNeeded() {
        guard dockClick.isRecent(within: 0.9) else { return }
        dockClickGeneration &+= 1
        let generation = dockClickGeneration

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(240))
            guard let self, self.isRunning, self.dockClickGeneration == generation else { return }
            self.handleDockReclickOfFrontmostApp()
        }
    }

    /// Whether the last Dock interaction was a ⇧-click (lift all windows).
    private func isShiftDockClick() -> Bool {
        let snap = dockClick.snapshot()
        guard snap.shiftHeld else { return false }
        guard let clickedAt = snap.clickedAt, Date().timeIntervalSince(clickedAt) < 1.0 else {
            return false
        }
        return true
    }

    /// Heuristic: activation soon after a Dock-region click, or pointer still over Dock.
    private func isLikelyDockTriggered() -> Bool {
        if dockClick.isRecent(within: 1.0) {
            return true
        }
        return DockGeometry.screenHostingDock(at: NSEvent.mouseLocation) != nil
    }

    /// Display that should receive the window after a Dock activation.
    private func targetDisplayID() -> CGDirectDisplayID? {
        let snap = dockClick.snapshot()
        if let clickedAt = snap.clickedAt,
           Date().timeIntervalSince(clickedAt) < 1.0,
           let displayID = snap.displayID
        {
            return displayID
        }
        if let dockScreen = DockGeometry.screenHostingDock(at: NSEvent.mouseLocation) {
            return ScreenCoordinates.displayID(of: dockScreen)
        }
        // Prefer the screen under the pointer (where the user is working).
        if let underPointer = ScreenCoordinates.screen(containingAppKitPoint: NSEvent.mouseLocation) {
            return ScreenCoordinates.displayID(of: underPointer)
        }
        if let screen = DockGeometry.activeDockScreen() {
            return ScreenCoordinates.displayID(of: screen)
        }
        return nil
    }

    // MARK: - Already-active app Dock re-click

    /// Handles Dock clicks when the app is already frontmost (no activation notification).
    private func handleDockReclickOfFrontmostApp() {
        let policy = currentPolicy()
        guard policy.isEnabled else { return }
        guard windowManager.isAccessibilityTrusted else { return }
        guard policy.moveToDockScreen || policy.preferMoveToCurrentSpace else { return }

        // Still consider this a recent Dock interaction.
        guard dockClick.isRecent(within: 1.0) else { return }

        guard let app = NSWorkspace.shared.frontmostApplication else { return }

        // DockLift itself: Settings may sit on another display while we are frontmost.
        // Do not use AX lift (we ignore our own bundle); move NSWindows directly.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            OpenSettingsAction.bringOwnWindowsToDockScreen()
            lastEventDescription = String(localized: "Brought Settings to Dock screen")
            return
        }

        if app.isTerminated || app.activationPolicy != .regular { return }

        if let bundleID = app.bundleIdentifier, policy.ignoredBundleIdentifiers.contains(bundleID) {
            return
        }

        // If activation handling already lifted this app, skip.
        if let lastHandled,
           lastHandled.pid == app.processIdentifier,
           Date().timeIntervalSince(lastHandled.at) < 0.55
        {
            return
        }

        // Only pull windows that are actually off the Dock's display (or Space).
        let displayID = targetDisplayID()
        let needsWork: Bool
        do {
            needsWork = try windowManager.needsLift(
                for: app,
                targetDisplayID: displayID,
                includeMinimized: policy.includeMinimizedWindows
            )
        } catch {
            needsWork = true
        }
        guard needsWork else {
            log.debug("Frontmost app already on Dock screen — skip re-click lift")
            return
        }

        lastHandled = (app.processIdentifier, Date())
        let shift = isShiftDockClick()
        log.info(
            "Dock re-click of already-frontmost app \(app.localizedName ?? "?", privacy: .public) shift=\(shift, privacy: .public)"
        )
        lift(app: app, policy: policy, liftAllWindows: shift)
    }

    // MARK: - Activation

    private func currentPolicy() -> LiftPolicy {
        policyProvider?() ?? LiftPolicy(
            isEnabled: true,
            onlyWhenDockClick: true,
            includeMinimizedWindows: true,
            preferMoveToCurrentSpace: true,
            moveToDockScreen: true,
            useMinimizeFallback: true,
            ignoredBundleIdentifiers: []
        )
    }

    private func handleActivation(_ notification: Notification) {
        let policy = currentPolicy()

        guard policy.isEnabled else { return }
        guard windowManager.isAccessibilityTrusted else {
            lastEventDescription = String(localized: "Skipped: Accessibility not granted")
            return
        }

        guard
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        else {
            return
        }

        // Own app activation via Dock — move Settings to the Dock's screen.
        if app.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            // Defer so dock-click state from the global monitor can settle.
            activationGeneration &+= 1
            let generation = activationGeneration
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(90))
                guard let self, self.isRunning, self.activationGeneration == generation else { return }
                if self.isLikelyDockTriggered() {
                    OpenSettingsAction.bringOwnWindowsToDockScreen()
                    self.lastEventDescription = String(localized: "Brought Settings to Dock screen")
                }
            }
            return
        }

        if app.isTerminated { return }

        if let bundleID = app.bundleIdentifier, policy.ignoredBundleIdentifiers.contains(bundleID) {
            let name = app.localizedName ?? bundleID
            lastEventDescription = String(format: String(localized: "Ignored %@"), name)
            return
        }

        if app.activationPolicy != .regular { return }

        // Global monitors fire *after* Dock handles the click, so activation
        // often arrives before our dock-click recorder. Defer the lift briefly
        // so display id + ⇧ are available, then re-check the dock heuristic.
        activationGeneration &+= 1
        let generation = activationGeneration
        let pid = app.processIdentifier

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard let self, self.isRunning, self.activationGeneration == generation else { return }

            // App may have changed again; re-resolve by pid.
            guard let live = NSRunningApplication(processIdentifier: pid), !live.isTerminated else {
                return
            }

            let policy = self.currentPolicy()
            guard policy.isEnabled else { return }

            if policy.onlyWhenDockClick && !self.isLikelyDockTriggered() {
                let name = live.localizedName ?? String(localized: "App")
                self.lastEventDescription = String(
                    format: String(localized: "Activation of %@ (not Dock)"),
                    name
                )
                return
            }

            if let lastHandled,
               lastHandled.pid == live.processIdentifier,
               Date().timeIntervalSince(lastHandled.at) < 0.35
            {
                return
            }
            self.lastHandled = (live.processIdentifier, Date())

            let shift = self.isShiftDockClick()
            self.lift(app: live, policy: policy, liftAllWindows: shift)
        }
    }

    private func lift(
        app: NSRunningApplication,
        policy: LiftPolicy,
        liftAllWindows: Bool
    ) {
        let name = app.localizedName ?? app.bundleIdentifier ?? String(localized: "App")
        let displayID = targetDisplayID()

        let target = LiftTarget(
            screenDisplayID: displayID,
            preferMoveToCurrentSpace: policy.preferMoveToCurrentSpace,
            moveToDockScreen: policy.moveToDockScreen,
            useMinimizeFallback: policy.useMinimizeFallback,
            includeMinimized: policy.includeMinimizedWindows,
            liftAllWindows: liftAllWindows
        )

        do {
            if liftAllWindows {
                let all = try windowManager.liftAllWindows(of: app, target: target)
                lastLiftedAppName = name
                let count = all.results.count
                lastEventDescription = String(
                    format: String(localized: "Lifted %lld windows of %@ to Dock screen"),
                    Int64(count),
                    name
                )
                log.info("Lifted \(count, privacy: .public) windows for \(name, privacy: .public) (⇧-Dock)")
                return
            }

            let result = try windowManager.liftMostRecentWindow(of: app, target: target)
            lastLiftedAppName = name

            var notes: [String] = []
            if result.movedToScreen {
                notes.append(String(localized: "moved to Dock screen"))
            }
            if result.movedAcrossSpace {
                notes.append(String(localized: "from other Space"))
            }
            let suffix: String
            if notes.isEmpty {
                suffix = ""
            } else {
                suffix = String(
                    format: String(localized: " (%@)"),
                    notes.joined(separator: ", ")
                )
            }
            let title = result.window.title.isEmpty ? name : result.window.title
            lastEventDescription = String(
                format: String(localized: "Lifted “%@”%@"),
                title,
                suffix
            )
            log.info("Lifted window for \(name, privacy: .public)\(suffix, privacy: .public)")
        } catch WindowManagerError.noWindows {
            lastEventDescription = String(
                format: String(localized: "%@ has no windows to lift"),
                name
            )
        } catch {
            lastEventDescription = String(
                format: String(localized: "Failed for %@: %@"),
                name,
                error.localizedDescription
            )
            log.error("Lift failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
