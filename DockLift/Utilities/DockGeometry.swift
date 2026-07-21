//
//  DockGeometry.swift
//  DockLift
//
//  Estimates Dock hit-testing regions from screen layout and Dock preferences.
//

import AppKit
import Foundation

enum DockOrientation: String {
    case bottom
    case left
    case right
}

/// Geometry helpers used to decide whether a pointer event likely hit the Dock.
enum DockGeometry {
    /// Thickness (points) of the strip treated as Dock territory, including
    /// magnification slack and taller Dock chrome on recent macOS releases.
    private static let dockThickness: CGFloat = 120

    static var orientation: DockOrientation {
        let raw = UserDefaults(suiteName: "com.apple.dock")?
            .string(forKey: "orientation")?
            .lowercased()
        switch raw {
        case "left": return .left
        case "right": return .right
        default: return .bottom
        }
    }

    static var isAutoHideEnabled: Bool {
        UserDefaults(suiteName: "com.apple.dock")?
            .bool(forKey: "autohide") ?? false
    }

    /// Returns `true` when `point` (AppKit bottom-left origin, global) lies in the Dock strip.
    static func contains(_ point: CGPoint) -> Bool {
        screenHostingDock(at: point) != nil
    }

    /// The display whose Dock strip contains `point`, if any.
    ///
    /// On multi-monitor setups the Dock lives on one screen at a time; using the
    /// click location is the reliable way to know *which* Dock was used.
    /// Falls back to checking every screen’s dock band so clicks near shared
    /// edges (or slightly off the primary hit-test screen) still count.
    static func screenHostingDock(at point: CGPoint) -> NSScreen? {
        if let screen = screen(for: point), dockBand(on: screen).contains(point) {
            return screen
        }
        for screen in NSScreen.screens where dockBand(on: screen).contains(point) {
            return screen
        }
        return nil
    }

    /// Screen currently showing the Dock (best effort from pointer / main).
    static func activeDockScreen(pointer: CGPoint = NSEvent.mouseLocation) -> NSScreen? {
        if let dockScreen = screenHostingDock(at: pointer) {
            return dockScreen
        }
        // Fallback: screen under pointer, then main.
        return screen(for: pointer) ?? NSScreen.main
    }

    /// Dock hit-test rectangle on a specific display.
    static func dockBand(on screen: NSScreen) -> CGRect {
        let frame = screen.frame
        let visible = screen.visibleFrame
        let thickness = dockThickness

        switch orientation {
        case .bottom:
            let dockTop = max(visible.minY, frame.minY + 1)
            return CGRect(
                x: frame.minX,
                y: frame.minY,
                width: frame.width,
                height: max(thickness, dockTop - frame.minY + 12)
            )
        case .left:
            let dockRight = min(visible.minX, frame.minX + thickness)
            return CGRect(
                x: frame.minX,
                y: frame.minY,
                width: max(thickness, dockRight - frame.minX + 12),
                height: frame.height
            )
        case .right:
            let dockLeft = max(visible.maxX, frame.maxX - thickness)
            return CGRect(
                x: dockLeft - 12,
                y: frame.minY,
                width: frame.maxX - (dockLeft - 12),
                height: frame.height
            )
        }
    }

    static func screen(for point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }
}
