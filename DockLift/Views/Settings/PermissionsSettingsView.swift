//
//  PermissionsSettingsView.swift
//  DockLift
//

import PermissionFlow
import PermissionFlowStatusStore
import SwiftUI

struct PermissionsSettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var permissionStatusStore: PermissionFlowStatusStore

    var body: some View {
        Form {
            Section {
                Text("DockLift needs Accessibility access to read window lists and raise windows belonging to other apps.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Text("Accessibility")
                    Spacer()
                    PermissionFlowButton(
                        pane: .accessibility,
                        suggestedAppURLs: [Bundle.main.bundleURL]
                    )
                }
            } header: {
                Text("System Permissions")
            }

            Section {
                LabeledContent("Space private API") {
                    Text(viewModel.privateSpaceAPIAvailable ? "Available" : "Unavailable")
                        .foregroundStyle(
                            viewModel.privateSpaceAPIAvailable ? Color.secondary : Color.orange
                        )
                }
                Text(
                    """
                    Moving a window onto the active Mission Control Space has no public API. \
                    DockLift optionally loads undocumented SkyLight symbols at runtime and falls \
                    back to Accessibility-only behaviour when they are missing.
                    """
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Capabilities")
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            permissionStatusStore.refresh(.accessibility)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            permissionStatusStore.refresh(.accessibility)
        }
    }
}
