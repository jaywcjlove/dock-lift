//
//  PermissionGateView.swift
//  DockLift
//

import PermissionFlow
import PermissionFlowStatusStore
import SwiftUI

struct PermissionGateView: View {
    @EnvironmentObject private var permissionStatusStore: PermissionFlowStatusStore
    @Environment(\.dismissWindow) private var dismissWindow
    
    private var isGranted: Bool {
        permissionStatusStore.state(for: .accessibility) == .granted
    }
    
    var body: some View {
        var _ = print("isGranted:", isGranted)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Accessibility Required")
                        .font(.title2.weight(.semibold))
                    Text("DockLift needs Accessibility before you can open Settings or lift windows.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("Grant Accessibility, then drag DockLift into the list if prompted. After authorization, Settings will open automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            PermissionFlowButton(
                pane: .accessibility,
                suggestedAppURLs: [Bundle.main.bundleURL]
            )
            .controlSize(.large)

            HStack {
                Spacer()
                if isGranted == true {
                    Button("Enter DockLift") {
                        dismissWindow(id: OpenSettingsAction.permissionGateWindowID)
                        OpenSettingsAction.requestSettings(force: true)
                    }
                    .keyboardShortcut(.home)
                } else {
                    Button("Later") {
                        dismissWindow(id: OpenSettingsAction.permissionGateWindowID)
                        NSApp.setActivationPolicy(.accessory)
                    }
                    .keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(24)
        .frame(width: 440)
        .onAppear {
            permissionStatusStore.refresh(.accessibility)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            permissionStatusStore.refresh(.accessibility)
        }
    }
}
