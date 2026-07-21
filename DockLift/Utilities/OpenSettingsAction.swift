//
//  OpenSettingsAction.swift
//  DockLift
//
//  Reliable Settings presentation for MenuBarExtra (LSUIElement) apps.
//  Gates Settings behind Accessibility authorization via PermissionFlow.
//

import AppKit
import PermissionFlow
import SwiftUI

extension Notification.Name {
    /// Open Settings only when Accessibility is already granted.
    static let dockLiftOpenSettings = Notification.Name("dockLiftOpenSettings")
    /// Present the permission gate window (no Settings until authorized).
    static let dockLiftOpenPermissionGate = Notification.Name("dockLiftOpenPermissionGate")
}

enum OpenSettingsAction {
    static let bootstrapWindowID = "docklift.settings.bootstrap"
    static let permissionGateWindowID = "docklift.permission.gate"

    /// Live Accessibility check (PermissionFlow built-in provider).
    static func isAccessibilityGranted() -> Bool {
        AccessibilityPermissionStatusProvider().authorizationState() == .granted
    }

    /// Public entry: Settings if trusted, otherwise permission gate.
    static func request() {
        DispatchQueue.main.async {
            if isAccessibilityGranted() {
                requestSettings(force: true)
            } else {
                requestPermissionGate()
            }
        }
    }

    /// Open Settings scene (caller must ensure Accessibility is granted, or pass force after check).
    static func requestSettings(force: Bool = false) {
        DispatchQueue.main.async {
            if force || isAccessibilityGranted() {
                NotificationCenter.default.post(name: .dockLiftOpenSettings, object: nil)
            } else {
                requestPermissionGate()
            }
        }
    }

    static func requestPermissionGate() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .dockLiftOpenPermissionGate, object: nil)
        }
    }

    /// Best-effort locate the SwiftUI Settings window.
    static func findSettingsWindow() -> NSWindow? {
        let candidates = NSApp.windows.filter { window in
            guard window.frame.width > 50, window.frame.height > 50 else { return false }
            if window.identifier?.rawValue.contains("SwiftUI.Settings") == true {
                return true
            }
            let title = window.title.lowercased()
            if title.contains("settings") || title.contains("preferences") || title.contains("docklift") {
                return window.styleMask.contains(.titled)
            }
            let typeName = String(describing: type(of: window))
            if typeName.contains("Settings") { return true }
            if let vc = window.contentViewController {
                let vcName = String(describing: type(of: vc))
                if vcName.contains("Settings") { return true }
            }
            return false
        }
        return candidates.first
    }

    static func focusSettingsWindow() {
        guard let window = findSettingsWindow() else { return }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    // MARK: - Own window multi-display (DockLift Settings)

    /// Content windows belonging to DockLift that should follow the Dock click screen.
    static func ownContentWindows() -> [NSWindow] {
        NSApp.windows.filter { window in
            guard window.frame.width > 50, window.frame.height > 50 else { return false }
            // Skip the invisible bootstrap helper.
            if window.identifier?.rawValue.contains(bootstrapWindowID) == true { return false }
            if window.alphaValue < 0.05 { return false }
            if !window.isVisible && window.isMiniaturized == false {
                // Still consider non-visible titled windows that exist (e.g. ordered out briefly).
            }
            let title = window.title.lowercased()
            let id = window.identifier?.rawValue ?? ""
            if id.contains(permissionGateWindowID) { return true }
            if id.contains("SwiftUI.Settings") { return true }
            if title.contains("settings") || title.contains("preferences")
                || title.contains("docklift") || title.contains("accessibility")
                || title.contains("设置") || title.contains("設定") || title.contains("辅助")
            {
                return true
            }
            // Any normal titled keyable window of this process (Settings / gate).
            return window.styleMask.contains(.titled) && window.canBecomeKey
        }
    }

    /// Screen implied by the latest pointer / Dock interaction.
    static func preferredScreenForDockInteraction() -> NSScreen {
        if let dock = DockGeometry.screenHostingDock(at: NSEvent.mouseLocation) {
            return dock
        }
        if let under = ScreenCoordinates.screen(containingAppKitPoint: NSEvent.mouseLocation) {
            return under
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    /// Move DockLift’s own Settings / permission windows onto `screen` and key them.
    /// Used when the user clicks DockLift in the Dock while a window is open on another display.
    static func bringOwnWindows(to screen: NSScreen) {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)

        let windows = ownContentWindows()
        if windows.isEmpty {
            // No prefs open yet — open Settings / permission gate as usual.
            request()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                placeWindows(ownContentWindows(), on: screen)
            }
            return
        }

        placeWindows(windows, on: screen)
    }

    /// Convenience: bring own windows to the screen of the current Dock / pointer.
    static func bringOwnWindowsToDockScreen() {
        bringOwnWindows(to: preferredScreenForDockInteraction())
    }

    private static func placeWindows(_ windows: [NSWindow], on screen: NSScreen) {
        let visible = screen.visibleFrame
        for window in windows {
            var frame = window.frame
            let onTarget: Bool = {
                let inter = frame.intersection(visible)
                guard !inter.isNull, !inter.isEmpty else { return false }
                return (inter.width * inter.height) >= (frame.width * frame.height * 0.4)
            }()

            if !onTarget {
                // Center on the destination display, keep size, clamp into visible frame.
                frame.size.width = min(frame.width, visible.width)
                frame.size.height = min(frame.height, visible.height)
                frame.origin.x = visible.midX - frame.width / 2
                frame.origin.y = visible.midY - frame.height / 2
                frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
                frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
                window.setFrame(frame, display: true, animate: false)
            }

            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

/// Lives inside the hidden bootstrap `Window` scene.
struct SettingsBootstrapView: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    @State private var didAutoOpenThisSession = false

    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .accessibilityHidden(true)
            .background(BootstrapWindowHider())
            .task {
                guard !didAutoOpenThisSession else { return }
                didAutoOpenThisSession = true
                try? await Task.sleep(for: .milliseconds(450))
                await handleLaunchOrRequest()
            }
            .onReceive(NotificationCenter.default.publisher(for: .dockLiftOpenSettings)) { _ in
                Task { @MainActor in
                    await openSettingsFlow()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .dockLiftOpenPermissionGate)) { _ in
                Task { @MainActor in
                    await openPermissionGateFlow()
                }
            }
    }

    @MainActor
    private func handleLaunchOrRequest() async {
        if OpenSettingsAction.isAccessibilityGranted() {
            await openSettingsFlow()
        } else {
            await openPermissionGateFlow()
        }
    }

    @MainActor
    private func openPermissionGateFlow() async {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            try? await Task.sleep(for: .milliseconds(80))
        }
        NSApp.activate(ignoringOtherApps: true)
        openWindow(id: OpenSettingsAction.permissionGateWindowID)
    }

    @MainActor
    private func openSettingsFlow() async {
        // Never open Settings without Accessibility.
        guard OpenSettingsAction.isAccessibilityGranted() else {
            await openPermissionGateFlow()
            return
        }

        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
            try? await Task.sleep(for: .milliseconds(80))
        }

        NSApp.activate(ignoringOtherApps: true)
        openSettings()

        try? await Task.sleep(for: .milliseconds(180))
        OpenSettingsAction.focusSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Keeps the bootstrap window invisible and out of the window cycle.
private struct BootstrapWindowHider: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.alphaValue = 0
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.transient, .ignoresCycle, .stationary]
            window.isExcludedFromWindowsMenu = true
            window.level = .normal
            window.orderOut(nil)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.orderOut(nil)
        }
    }
}
