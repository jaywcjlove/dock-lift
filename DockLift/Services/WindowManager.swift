//
//  WindowManager.swift
//  DockLift
//
//  All Accessibility (AXUIElement) window queries and mutations live here.
//

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Errors produced while inspecting or controlling windows via Accessibility.
enum WindowManagerError: LocalizedError {
    case notTrusted
    case noWindows
    case attributeFailed(String, AXError)
    case actionFailed(String, AXError)
    case applicationUnavailable

    var errorDescription: String? {
        switch self {
        case .notTrusted:
            return String(localized: "Accessibility permission is required.")
        case .noWindows:
            return String(localized: "No suitable windows were found for the application.")
        case .attributeFailed(let name, let error):
            return String(
                format: String(localized: "Failed to read %@ (AX error %lld)."),
                name,
                Int64(error.rawValue)
            )
        case .actionFailed(let name, let error):
            return String(
                format: String(localized: "Failed to perform %@ (AX error %lld)."),
                name,
                Int64(error.rawValue)
            )
        case .applicationUnavailable:
            return String(localized: "The target application is not running.")
        }
    }
}

/// Context describing where the user triggered a lift (Dock screen / Space).
struct LiftTarget: Sendable {
    /// Display that should host the window after the lift (Dock click screen).
    var screenDisplayID: CGDirectDisplayID?
    var preferMoveToCurrentSpace: Bool
    var moveToDockScreen: Bool
    var useMinimizeFallback: Bool
    var includeMinimized: Bool
    /// ⇧-Dock click: lift every window of the app, not only the most recent one.
    var liftAllWindows: Bool
}

/// Result of a lift, including whether Space/display relocation happened.
struct LiftResult {
    let window: ManagedWindow
    var movedToScreen: Bool
    var movedAcrossSpace: Bool
}

/// Aggregate result when lifting multiple windows (⇧-Dock).
struct LiftAllResult {
    var results: [LiftResult]
    var movedToScreenCount: Int { results.filter(\.movedToScreen).count }
    var movedAcrossSpaceCount: Int { results.filter(\.movedAcrossSpace).count }
    var primaryWindow: ManagedWindow? { results.first?.window }
}

/// Encapsulates every `AXUIElement` interaction used by DockLift.
///
/// Marked nonisolated from the default MainActor isolation so Accessibility
/// work can run off the UI actor when needed.
final class WindowManager: @unchecked Sendable {
    static let shared = WindowManager()

    private init() {}

    // MARK: - Trust

    var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    // MARK: - Listing

    /// Returns standard application windows for `app`, newest/frontmost first.
    ///
    /// - Parameters:
    ///   - targetDisplayID: Dock / destination display when pulling windows across screens.
    ///   - preferOffTargetDisplay: When `true`, windows *not* on `targetDisplayID` rank first
    ///     so multi-display Dock clicks pull the window from the other screen.
    func windows(
        for app: NSRunningApplication,
        includeMinimized: Bool = true,
        targetDisplayID: CGDirectDisplayID? = nil,
        preferOffTargetDisplay: Bool = false
    ) throws -> [ManagedWindow] {
        guard isAccessibilityTrusted else { throw WindowManagerError.notTrusted }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let rawWindows: [AXUIElement] = try copyArrayAttribute(
            kAXWindowsAttribute,
            of: appElement
        )

        let onScreenIDs = SpaceMover.onScreenWindowIDs(for: app.processIdentifier)
        let orderedIDs = SpaceMover.orderedWindowIDs(for: app.processIdentifier)
        let orderIndex = Dictionary(uniqueKeysWithValues: orderedIDs.enumerated().map { ($1, $0) })

        var result: [ManagedWindow] = []
        result.reserveCapacity(rawWindows.count)

        for element in rawWindows {
            guard let role: String = try? copyStringAttribute(kAXRoleAttribute, of: element),
                  role == kAXWindowRole as String
            else {
                continue
            }

            let subrole: String? = try? copyStringAttribute(kAXSubroleAttribute, of: element)
            _ = subrole

            let title = (try? copyStringAttribute(kAXTitleAttribute, of: element)) ?? ""
            let isMinimized = (try? copyBoolAttribute(kAXMinimizedAttribute, of: element)) ?? false
            let isHidden = app.isHidden

            if !includeMinimized && isMinimized { continue }

            let cgID = SpaceMover.cgWindowID(for: element)
                ?? matchCGWindowID(
                    pid: app.processIdentifier,
                    title: title,
                    element: element,
                    orderedIDs: orderedIDs
                )
                ?? 0

            let isOnScreen = cgID != 0 && onScreenIDs.contains(cgID)
            // Prefer CGWindow bounds for multi-display placement (more reliable than AX alone).
            let cgBounds = SpaceMover.cgBounds(for: cgID)
            let axPosition = try? copyPointAttribute(kAXPositionAttribute, of: element)
            let axSize = try? copySizeAttribute(kAXSizeAttribute, of: element)
            let position = cgBounds.map(\.origin) ?? axPosition
            let size = cgBounds.map(\.size) ?? axSize
            let zOrder = orderIndex[cgID] ?? Int.max

            var displayID: CGDirectDisplayID?
            if let position, let size,
               let host = ScreenCoordinates.screen(hostingAXTopLeft: position, size: size)
            {
                displayID = ScreenCoordinates.displayID(of: host)
            }

            let id = "\(app.processIdentifier)-\(cgID)-\(title)-\(Unmanaged.passUnretained(element).toOpaque())"

            result.append(
                ManagedWindow(
                    id: id,
                    element: element,
                    processIdentifier: app.processIdentifier,
                    title: title,
                    role: role,
                    subrole: subrole,
                    isMinimized: isMinimized,
                    isHidden: isHidden,
                    cgWindowID: cgID,
                    isOnScreen: isOnScreen,
                    position: position,
                    size: size,
                    zOrder: zOrder,
                    displayID: displayID
                )
            )
        }

        return result.sorted { lhs, rhs in
            let lRank = rank(
                lhs,
                targetDisplayID: targetDisplayID,
                preferOffTargetDisplay: preferOffTargetDisplay
            )
            let rRank = rank(
                rhs,
                targetDisplayID: targetDisplayID,
                preferOffTargetDisplay: preferOffTargetDisplay
            )
            if lRank != rRank { return lRank < rRank }
            return lhs.zOrder < rhs.zOrder
        }
    }

    /// Most recently used suitable window for a lift toward `targetDisplayID`.
    func mostRecentWindow(
        for app: NSRunningApplication,
        includeMinimized: Bool = true,
        targetDisplayID: CGDirectDisplayID? = nil,
        preferOffTargetDisplay: Bool = false
    ) throws -> ManagedWindow? {
        try windows(
            for: app,
            includeMinimized: includeMinimized,
            targetDisplayID: targetDisplayID,
            preferOffTargetDisplay: preferOffTargetDisplay
        ).first
    }

    /// Whether the app still has work for DockLift on `targetDisplayID`.
    func needsLift(
        for app: NSRunningApplication,
        targetDisplayID: CGDirectDisplayID?,
        includeMinimized: Bool
    ) throws -> Bool {
        let list = try windows(
            for: app,
            includeMinimized: includeMinimized,
            targetDisplayID: targetDisplayID,
            preferOffTargetDisplay: true
        )
        guard !list.isEmpty else { return false }

        // Minimized / off-space windows always need a lift.
        if list.contains(where: { $0.isMinimized || $0.isLikelyOnOtherSpace }) {
            return true
        }

        guard let targetDisplayID else {
            // No display target — still lift if anything is off-screen.
            return list.contains { !$0.isOnScreen }
        }

        // Any normal window living on another display should be pulled over.
        return list.contains { window in
            guard !window.isMinimized else { return false }
            if let displayID = window.displayID {
                return displayID != targetDisplayID
            }
            // Unknown display but visible — treat as needing a move attempt when
            // the pointer/Dock is on a known screen.
            return true
        }
    }

    // MARK: - Actions

    /// Activates the app, optionally unhiding it first.
    func activate(_ app: NSRunningApplication) {
        if app.isHidden {
            app.unhide()
        }
        _ = app.activate(options: [.activateAllWindows])
    }

    /// Raises a window (brings it frontmost within its application).
    func raise(_ window: ManagedWindow) throws {
        try performAction(kAXRaiseAction, on: window.element)
    }

    /// Marks the window as the main / focused window of its app.
    func focus(_ window: ManagedWindow) throws {
        try setBoolAttribute(kAXMainAttribute, value: true, on: window.element)
        try setBoolAttribute(kAXFocusedAttribute, value: true, on: window.element)
    }

    func setMinimized(_ window: ManagedWindow, _ minimized: Bool) throws {
        try setBoolAttribute(kAXMinimizedAttribute, value: minimized, on: window.element)
    }

    /// Moves the window onto `screen` via public Accessibility position/size.
    /// - Parameter cascadeIndex: Offsets stacked windows slightly (⇧ multi-lift).
    /// - Parameter forceReposition: Reposition even when already on `screen` (cascade).
    @discardableResult
    func move(
        _ window: ManagedWindow,
        to screen: NSScreen,
        cascadeIndex: Int = 0,
        forceReposition: Bool = false
    ) throws -> Bool {
        // Exit full screen first; otherwise position changes are ignored.
        if let isFullscreen = try? copyBoolAttribute("AXFullScreen", of: window.element),
           isFullscreen
        {
            try? setBoolAttribute("AXFullScreen", value: false, on: window.element)
            usleep(80_000)
        }

        // Live geometry: prefer CGWindow bounds, fall back to AX / snapshot.
        let liveBounds = SpaceMover.cgBounds(for: window.cgWindowID)
        let livePosition = liveBounds.map(\.origin)
            ?? (try? copyPointAttribute(kAXPositionAttribute, of: window.element))
            ?? window.position
        let liveSize = liveBounds.map(\.size)
            ?? (try? copySizeAttribute(kAXSizeAttribute, of: window.element))
            ?? window.size

        let sourceScreen: NSScreen? = {
            if let livePosition, let liveSize,
               let host = ScreenCoordinates.screen(hostingAXTopLeft: livePosition, size: liveSize)
            {
                return host
            }
            if let displayID = window.displayID {
                return ScreenCoordinates.screen(displayID: displayID)
            }
            return nil
        }()

        let targetID = ScreenCoordinates.displayID(of: screen)
        let alreadyOnTarget = sourceScreen.map {
            ScreenCoordinates.displayID(of: $0) == targetID
        } ?? false

        if alreadyOnTarget && !forceReposition && cascadeIndex == 0 {
            return false
        }

        var placement = ScreenCoordinates.relocatedAppKitFrame(
            currentAXTopLeft: livePosition,
            currentSize: liveSize,
            from: alreadyOnTarget ? screen : sourceScreen,
            to: screen
        )

        // Cascade so multiple windows do not fully cover each other.
        if cascadeIndex > 0 {
            let step: CGFloat = 28
            placement.origin.x += CGFloat(cascadeIndex) * step
            placement.origin.y -= CGFloat(cascadeIndex) * step
            let visible = screen.visibleFrame
            placement.origin.x = min(
                max(placement.origin.x, visible.minX),
                visible.maxX - placement.size.width
            )
            placement.origin.y = min(
                max(placement.origin.y, visible.minY),
                visible.maxY - placement.size.height
            )
        }

        let axOrigin = ScreenCoordinates.axTopLeft(
            fromAppKitBottomLeft: placement.origin,
            height: placement.size.height
        )

        try setPointAttribute(kAXPositionAttribute, value: axOrigin, on: window.element)

        if let current = liveSize,
           abs(current.width - placement.size.width) > 1
            || abs(current.height - placement.size.height) > 1
        {
            try? setSizeAttribute(kAXSizeAttribute, value: placement.size, on: window.element)
        } else {
            // Re-apply size so some apps commit the position change.
            if let liveSize {
                try? setSizeAttribute(kAXSizeAttribute, value: liveSize, on: window.element)
            }
        }

        return true
    }

    /// Full lift: activate → optional Space move → move to Dock screen → raise → focus.
    func lift(
        _ window: ManagedWindow,
        app: NSRunningApplication,
        target: LiftTarget,
        activateApp: Bool = true,
        focusWindow: Bool = true,
        cascadeIndex: Int = 0
    ) throws -> LiftResult {
        guard isAccessibilityTrusted else { throw WindowManagerError.notTrusted }

        if activateApp {
            activate(app)
        }

        var movedAcrossSpace = false
        var movedToScreen = false

        let needsSpaceMove =
            target.preferMoveToCurrentSpace
            && (window.isLikelyOnOtherSpace || (!window.isOnScreen && !window.isMinimized))

        // Private Space APIs often resolve via dlsym but silently no-op for foreign
        // windows on recent macOS. Always verify on-screen state afterward.
        if needsSpaceMove, window.cgWindowID != 0 {
            _ = SpaceMover.moveWindowToCurrentSpace(windowID: window.cgWindowID)
            usleep(40_000)
            if SpaceMover.isWindowOnScreen(windowID: window.cgWindowID, pid: app.processIdentifier) {
                movedAcrossSpace = true
            }
        }

        if window.isMinimized {
            try setMinimized(window, false)
            // Deminimizing can surface a window onto the current Space.
            if needsSpaceMove {
                movedAcrossSpace = true
            }
        } else if needsSpaceMove, target.useMinimizeFallback {
            let stillOffSpace =
                window.cgWindowID == 0
                || !SpaceMover.isWindowOnScreen(
                    windowID: window.cgWindowID,
                    pid: app.processIdentifier
                )
            // Run the public fallback whenever the private path did not actually
            // bring the window on-screen (including “API available but no-op”).
            if stillOffSpace {
                try setMinimized(window, true)
                usleep(50_000)
                try setMinimized(window, false)
                usleep(40_000)
                movedAcrossSpace = true
            }
        }

        // Multi-display: put the window on the screen where the Dock was clicked.
        // Do this *before* raise so the window appears on the correct display.
        // Re-probe live geometry after Space / unminimize work — the snapshot
        // taken at listing time is often stale for off-Space windows.
        if target.moveToDockScreen,
           let displayID = target.screenDisplayID,
           let screen = ScreenCoordinates.screen(displayID: displayID)
        {
            let liveDisplay: CGDirectDisplayID? = {
                if let live = SpaceMover.cgBounds(for: window.cgWindowID),
                   let host = ScreenCoordinates.screen(
                    hostingAXTopLeft: live.origin,
                    size: live.size
                   )
                {
                    return ScreenCoordinates.displayID(of: host)
                }
                return window.displayID
            }()
            let alreadyThere = liveDisplay == displayID
            if !alreadyThere {
                movedToScreen = (try? move(window, to: screen, cascadeIndex: cascadeIndex)) ?? false
                // Retry once after a short yield — some apps ignore the first set.
                if !movedToScreen {
                    usleep(40_000)
                    movedToScreen = (try? move(window, to: screen, cascadeIndex: cascadeIndex)) ?? false
                }
            } else if cascadeIndex > 0 {
                // Already on target; still cascade slightly when lifting many windows.
                _ = try? move(window, to: screen, cascadeIndex: cascadeIndex, forceReposition: true)
            }
        }

        try raise(window)
        if focusWindow {
            try? focus(window)
        }

        // If still not on the target display after raise, force another move.
        if target.moveToDockScreen,
           !movedToScreen,
           let displayID = target.screenDisplayID,
           let screen = ScreenCoordinates.screen(displayID: displayID)
        {
            let live = SpaceMover.cgBounds(for: window.cgWindowID)
            let stillElsewhere: Bool = {
                guard let live,
                      let host = ScreenCoordinates.screen(
                        hostingAXTopLeft: live.origin,
                        size: live.size
                      )
                else {
                    return window.displayID != displayID
                }
                return ScreenCoordinates.displayID(of: host) != displayID
            }()
            if stillElsewhere {
                movedToScreen = (try? move(window, to: screen, cascadeIndex: cascadeIndex)) ?? false
                try? raise(window)
            }
        }

        return LiftResult(
            window: window,
            movedToScreen: movedToScreen,
            movedAcrossSpace: movedAcrossSpace || needsSpaceMove
        )
    }

    /// Convenience: find the best window of `app` and lift it toward `target`.
    @discardableResult
    func liftMostRecentWindow(
        of app: NSRunningApplication,
        target: LiftTarget
    ) throws -> LiftResult {
        if target.liftAllWindows {
            let all = try liftAllWindows(of: app, target: target)
            guard let first = all.results.first else {
                activate(app)
                throw WindowManagerError.noWindows
            }
            return first
        }

        // When moving to the Dock's display, prefer a window that is *not*
        // already there (e.g. the document parked on an external monitor).
        let preferOffTarget = target.moveToDockScreen && target.screenDisplayID != nil
        guard let window = try mostRecentWindow(
            for: app,
            includeMinimized: target.includeMinimized,
            targetDisplayID: target.screenDisplayID,
            preferOffTargetDisplay: preferOffTarget
        ) else {
            activate(app)
            throw WindowManagerError.noWindows
        }
        return try lift(window, app: app, target: target)
    }

    /// Lift **every** suitable window of `app` onto the Dock screen (⇧-Dock).
    @discardableResult
    func liftAllWindows(
        of app: NSRunningApplication,
        target: LiftTarget
    ) throws -> LiftAllResult {
        // Prefer off-target first, then by z-order — cascade index follows this order.
        let list = try windows(
            for: app,
            includeMinimized: target.includeMinimized,
            targetDisplayID: target.screenDisplayID,
            preferOffTargetDisplay: target.moveToDockScreen && target.screenDisplayID != nil
        )
        guard !list.isEmpty else {
            activate(app)
            throw WindowManagerError.noWindows
        }

        activate(app)

        var results: [LiftResult] = []
        results.reserveCapacity(list.count)
        for (index, window) in list.enumerated() {
            let result = try lift(
                window,
                app: app,
                target: target,
                activateApp: false,
                focusWindow: index == 0,
                cascadeIndex: index
            )
            results.append(result)
            // Brief yield so WindowServer applies positions before the next window.
            if index + 1 < list.count {
                usleep(20_000)
            }
        }
        // Ensure the frontmost (first) window stays key.
        if let first = list.first {
            try? raise(first)
            try? focus(first)
        }
        return LiftAllResult(results: results)
    }

    // MARK: - Ranking

    /// Lower is better.
    /// When `preferOffTargetDisplay` is true, windows on *other* displays rank first
    /// so Dock clicks pull the external-display window onto the Dock screen.
    private func rank(
        _ window: ManagedWindow,
        targetDisplayID: CGDirectDisplayID?,
        preferOffTargetDisplay: Bool
    ) -> Int {
        var score = 0

        if preferOffTargetDisplay, let targetDisplayID {
            if let displayID = window.displayID {
                // Off-target windows win (lower score).
                score += (displayID == targetDisplayID) ? 20 : 0
            } else {
                score += 10
            }
        }

        if !window.isMinimized && window.isOnScreen {
            score += 0
        } else if !window.isMinimized && !window.isOnScreen {
            score += 2
        } else if window.isMinimized {
            score += 4
        } else {
            score += 6
        }

        return score
    }

    // MARK: - CGWindow matching fallback

    private func matchCGWindowID(
        pid: pid_t,
        title: String,
        element: AXUIElement,
        orderedIDs: [CGWindowID]
    ) -> CGWindowID? {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return orderedIDs.first
        }

        let axPosition = try? copyPointAttribute(kAXPositionAttribute, of: element)
        let axSize = try? copySizeAttribute(kAXSizeAttribute, of: element)

        var candidates: [(CGWindowID, Int)] = []
        for entry in info {
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner == pid else {
                continue
            }
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            guard let number = entry[kCGWindowNumber as String] as? CGWindowID else { continue }

            var score = 0
            let cgTitle = entry[kCGWindowName as String] as? String ?? ""
            if !title.isEmpty, cgTitle == title { score += 3 }

            if let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat],
               let axPosition,
               let axSize
            {
                let x = bounds["X"] ?? 0
                let w = bounds["Width"] ?? 0
                let h = bounds["Height"] ?? 0
                if abs(w - axSize.width) < 2, abs(h - axSize.height) < 2 {
                    score += 2
                }
                if abs(x - axPosition.x) < 4 {
                    score += 1
                }
            }

            if score > 0 {
                candidates.append((number, score))
            }
        }

        return candidates.max(by: { $0.1 < $1.1 })?.0 ?? orderedIDs.first
    }

    // MARK: - AX primitives

    private func copyAttribute(_ attribute: String, of element: AXUIElement) throws -> CFTypeRef {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success, let value else {
            throw WindowManagerError.attributeFailed(attribute, error)
        }
        return value
    }

    private func copyStringAttribute(_ attribute: String, of element: AXUIElement) throws -> String {
        let value = try copyAttribute(attribute, of: element)
        guard let string = value as? String else {
            throw WindowManagerError.attributeFailed(attribute, .failure)
        }
        return string
    }

    private func copyBoolAttribute(_ attribute: String, of element: AXUIElement) throws -> Bool {
        let value = try copyAttribute(attribute, of: element)
        guard let number = value as? NSNumber else {
            throw WindowManagerError.attributeFailed(attribute, .failure)
        }
        return number.boolValue
    }

    private func copyArrayAttribute(_ attribute: String, of element: AXUIElement) throws -> [AXUIElement] {
        let value = try copyAttribute(attribute, of: element)
        guard let array = value as? [AXUIElement] else {
            if CFGetTypeID(value) == CFArrayGetTypeID() {
                return []
            }
            throw WindowManagerError.attributeFailed(attribute, .failure)
        }
        return array
    }

    private func copyPointAttribute(_ attribute: String, of element: AXUIElement) throws -> CGPoint {
        let value = try copyAttribute(attribute, of: element)
        var point = CGPoint.zero
        if AXValueGetValue(value as! AXValue, .cgPoint, &point) {
            return point
        }
        throw WindowManagerError.attributeFailed(attribute, .failure)
    }

    private func copySizeAttribute(_ attribute: String, of element: AXUIElement) throws -> CGSize {
        let value = try copyAttribute(attribute, of: element)
        var size = CGSize.zero
        if AXValueGetValue(value as! AXValue, .cgSize, &size) {
            return size
        }
        throw WindowManagerError.attributeFailed(attribute, .failure)
    }

    private func setBoolAttribute(_ attribute: String, value: Bool, on element: AXUIElement) throws {
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, value as CFBoolean)
        guard error == .success else {
            throw WindowManagerError.attributeFailed(attribute, error)
        }
    }

    private func setPointAttribute(_ attribute: String, value: CGPoint, on element: AXUIElement) throws {
        var point = value
        guard let axValue = AXValueCreate(.cgPoint, &point) else {
            throw WindowManagerError.attributeFailed(attribute, .failure)
        }
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, axValue)
        guard error == .success else {
            throw WindowManagerError.attributeFailed(attribute, error)
        }
    }

    private func setSizeAttribute(_ attribute: String, value: CGSize, on element: AXUIElement) throws {
        var size = value
        guard let axValue = AXValueCreate(.cgSize, &size) else {
            throw WindowManagerError.attributeFailed(attribute, .failure)
        }
        let error = AXUIElementSetAttributeValue(element, attribute as CFString, axValue)
        guard error == .success else {
            throw WindowManagerError.attributeFailed(attribute, error)
        }
    }

    private func performAction(_ action: String, on element: AXUIElement) throws {
        let error = AXUIElementPerformAction(element, action as CFString)
        guard error == .success else {
            throw WindowManagerError.actionFailed(action, error)
        }
    }
}
