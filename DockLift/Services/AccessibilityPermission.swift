//
//  AccessibilityPermission.swift
//  DockLift
//
//  Thin wrapper around Accessibility trust + PermissionFlow authorization UI.
//

import ApplicationServices
import AppKit
import Combine
import Foundation
import PermissionFlow
import PermissionFlowStatusStore

/// DockLift’s Accessibility permission façade powered by PermissionFlow.
@MainActor
final class AccessibilityPermission: ObservableObject {
    /// Shared status store injected into SwiftUI (tracks `.accessibility`).
    let statusStore: PermissionFlowStatusStore

    private let controller = PermissionFlow.makeController(
        configuration: .init(
            requiredAppURLs: [Bundle.main.bundleURL],
            promptForAccessibilityTrust: false
        )
    )

    @Published private(set) var isTrusted: Bool = AXIsProcessTrusted()

    init(statusStore: PermissionFlowStatusStore? = nil) {
        self.statusStore = statusStore
            ?? PermissionFlowStatusStore(panes: [.accessibility])
        refresh()
    }

    /// Re-read Accessibility trust without prompting.
    ///
    /// Only `AXIsProcessTrusted()` enables real window control and global event
    /// monitors. PermissionFlow’s status store is refreshed for UI, but must not
    /// report “trusted” on its own — that previously started monitors that never
    /// received events after the user granted access.
    func refresh() {
        statusStore.refresh(.accessibility)
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
    }

    /// Opens PermissionFlow guidance for Accessibility (System Settings + drag panel).
    func requestAccess(sourceFrameInScreen: CGRect? = nil) {
        let frame = sourceFrameInScreen ?? Self.defaultSourceFrame()
        controller.authorize(
            pane: .accessibility,
            suggestedAppURLs: [Bundle.main.bundleURL],
            sourceFrameInScreen: frame
        )
        // Status will update when the app becomes active again after the user grants.
        refresh()
    }

    private static func defaultSourceFrame() -> CGRect {
        let mouse = NSEvent.mouseLocation
        return CGRect(x: mouse.x - 16, y: mouse.y - 16, width: 32, height: 32)
    }
}
