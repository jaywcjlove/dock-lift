//
//  SpaceMover.swift
//  DockLift
//
//  Moves windows onto the active Space.
//
//  ────────────────────────────────────────────────────────────────────────────
//  PRIVATE API NOTICE
//  ────────────────────────────────────────────────────────────────────────────
//  Apple does not expose a public API to assign windows to Mission Control
//  Spaces. DockLift therefore uses a *best-effort* stack:
//
//  1. Public Accessibility actions (raise / unminimize / focus).
//  2. Undocumented SkyLight helpers (`CGSMoveWindowsToManagedSpace`,
//     `CGSAddWindowsToSpaces`, …) loaded dynamically via `dlsym`.
//  3. Optional public minimize → deminimize fallback (often restores a window
//     onto the *current* Space).
//
//  Symbols are resolved at runtime so the app still launches if they vanish.
//  Behaviour may change or stop working on future macOS releases. No private
//  entitlement is claimed; on recent systems the CGS path may silently no-op
//  for windows the process does not “own”.
//  ────────────────────────────────────────────────────────────────────────────
//

import ApplicationServices
import CoreFoundation
import CoreGraphics
import Foundation

// MARK: - Dynamic SkyLight entry points

private typealias CGSConnectionID = UInt32
private typealias CGSSpaceID = UInt64

private typealias CGSMainConnectionIDProc = @convention(c) () -> CGSConnectionID
private typealias CGSGetActiveSpaceProc = @convention(c) (CGSConnectionID) -> CGSSpaceID
private typealias CGSMoveWindowsToManagedSpaceProc = @convention(c) (
    CGSConnectionID, CFArray, CGSSpaceID
) -> Void
private typealias CGSAddWindowsToSpacesProc = @convention(c) (
    CGSConnectionID, CFArray, CFArray
) -> Void
private typealias CGSRemoveWindowsFromSpacesProc = @convention(c) (
    CGSConnectionID, CFArray, CFArray
) -> Void
private typealias AXUIElementGetWindowProc = @convention(c) (
    AXUIElement, UnsafeMutablePointer<CGWindowID>
) -> AXError

/// Best-effort Space reassignment helpers (public + optional private).
enum SpaceMover {
    private static let skyLight = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
        RTLD_LAZY
    )
    private static let hiServices = dlopen(
        "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices",
        RTLD_LAZY
    )

    private static let mainConnectionID: CGSMainConnectionIDProc? = symbol(
        "CGSMainConnectionID",
        in: skyLight
    )
    private static let getActiveSpace: CGSGetActiveSpaceProc? = symbol(
        "CGSGetActiveSpace",
        in: skyLight
    )
    private static let moveWindowsToManagedSpace: CGSMoveWindowsToManagedSpaceProc? = symbol(
        "CGSMoveWindowsToManagedSpace",
        in: skyLight
    )
    private static let addWindowsToSpaces: CGSAddWindowsToSpacesProc? = symbol(
        "CGSAddWindowsToSpaces",
        in: skyLight
    )
    private static let removeWindowsFromSpaces: CGSRemoveWindowsFromSpacesProc? = symbol(
        "CGSRemoveWindowsFromSpaces",
        in: skyLight
    )
    private static let axGetWindow: AXUIElementGetWindowProc? = {
        if let p: AXUIElementGetWindowProc = symbol("_AXUIElementGetWindow", in: hiServices) {
            return p
        }
        // Fallback: symbol sometimes lives in the umbrella ApplicationServices image.
        return symbol("_AXUIElementGetWindow", in: nil)
    }()

    /// Whether private Space-move symbols resolved successfully.
    static var isPrivateSpaceAPIAvailable: Bool {
        mainConnectionID != nil
            && getActiveSpace != nil
            && (moveWindowsToManagedSpace != nil || addWindowsToSpaces != nil)
    }

    // MARK: Window id

    /// Resolves a Quartz window id from an Accessibility element (private helper).
    static func cgWindowID(for element: AXUIElement) -> CGWindowID? {
        guard let axGetWindow else { return nil }
        var windowID: CGWindowID = 0
        let error = axGetWindow(element, &windowID)
        guard error == .success, windowID != 0 else { return nil }
        return windowID
    }

    // MARK: Active Space

    static func activeSpaceID() -> UInt64? {
        guard let mainConnectionID, let getActiveSpace else { return nil }
        let cid = mainConnectionID()
        let space = getActiveSpace(cid)
        return space == 0 ? nil : space
    }

    // MARK: Move

    /// Attempts to place `windowID` on the active Space via private SkyLight APIs.
    ///
    /// - Returns: `true` only when a private call was **issued**. On modern macOS the
    ///   call may silently no-op for windows this process does not own — callers must
    ///   verify with ``isWindowOnScreen(windowID:pid:)`` and fall back publicly.
    @discardableResult
    static func moveWindowToCurrentSpace(windowID: CGWindowID) -> Bool {
        guard windowID != 0,
              let mainConnectionID,
              let getActiveSpace
        else {
            return false
        }

        let cid = mainConnectionID()
        let space = getActiveSpace(cid)
        guard space != 0 else { return false }

        let windows = [NSNumber(value: windowID)] as CFArray
        var issued = false

        // Prefer the managed-space move; also try add-to-spaces (some OS builds
        // implement only one of the two entry points usefully).
        if let moveWindowsToManagedSpace {
            moveWindowsToManagedSpace(cid, windows, space)
            issued = true
        }

        if let addWindowsToSpaces {
            let spaces = [NSNumber(value: space)] as CFArray
            addWindowsToSpaces(cid, windows, spaces)
            issued = true
        }

        return issued
    }

    /// Whether `windowID` is currently listed as on-screen (any connected display /
    /// current Spaces). Optionally scoped to `pid`.
    static func isWindowOnScreen(windowID: CGWindowID, pid: pid_t? = nil) -> Bool {
        guard windowID != 0 else { return false }
        return onScreenWindowIDs(for: pid).contains(windowID)
    }

    // MARK: On-screen probe (public)

    /// Window ids currently visible on any connected display (current Spaces).
    static func onScreenWindowIDs(for pid: pid_t? = nil) -> Set<CGWindowID> {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var result = Set<CGWindowID>()
        for entry in info {
            if let pid, let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner != pid {
                continue
            }
            if let number = entry[kCGWindowNumber as String] as? CGWindowID {
                result.insert(number)
            }
        }
        return result
    }

    /// Front-to-back ordered window numbers for a process (public CGWindowList).
    static func orderedWindowIDs(for pid: pid_t) -> [CGWindowID] {
        guard let info = CGWindowListCopyWindowInfo(
            [.optionAll, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        var result: [CGWindowID] = []
        for entry in info {
            guard let owner = entry[kCGWindowOwnerPID as String] as? pid_t, owner == pid else {
                continue
            }
            // Skip non-normal layers (menus, tooltips, shields…).
            let layer = entry[kCGWindowLayer as String] as? Int ?? 0
            guard layer == 0 else { continue }
            if let number = entry[kCGWindowNumber as String] as? CGWindowID {
                result.append(number)
            }
        }
        return result
    }

    /// Quartz (top-left) bounds for a window id, if listed by CGWindowList.
    static func cgBounds(for windowID: CGWindowID) -> CGRect? {
        guard windowID != 0,
              let info = CGWindowListCopyWindowInfo(
                [.optionIncludingWindow],
                windowID
              ) as? [[String: Any]],
              let entry = info.first,
              let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat]
        else {
            return nil
        }
        let x = bounds["X"] ?? 0
        let y = bounds["Y"] ?? 0
        let w = bounds["Width"] ?? 0
        let h = bounds["Height"] ?? 0
        guard w > 1, h > 1 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: dlsym helper

    private static func symbol<T>(_ name: String, in handle: UnsafeMutableRawPointer?) -> T? {
        let pointer: UnsafeMutableRawPointer?
        if let handle {
            pointer = dlsym(handle, name)
        } else {
            pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) // RTLD_DEFAULT
        }
        guard let pointer else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}
