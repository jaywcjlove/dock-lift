//
//  DockLiftApp.swift
//  DockLift
//
//  Menu bar utility. Permission status is owned solely by
//  PermissionFlowStatusStore (App @StateObject → environmentObject).
//

import PermissionFlow
import PermissionFlowStatusStore
import SwiftUI

@main
struct DockLiftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = PermissionFlowStatusStore(panes: [.accessibility])
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        Window("DockLift Bootstrap", id: OpenSettingsAction.bootstrapWindowID) {
            SettingsBootstrapView()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 1, height: 1)
        .windowStyle(.hiddenTitleBar)
        .commandsRemoved()

        Window(String(localized: "Accessibility Required"), id: OpenSettingsAction.permissionGateWindowID) {
            PermissionGateView()
                .environmentObject(store)
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 460, height: 280)

        MenuBarExtra {
            MenuBarView()
                .environmentObject(viewModel)
                .environmentObject(store)
        } label: {
            Label(
                "DockLift",
                systemImage: store.state(for: .accessibility) == .granted
                    ? "dock.rectangle"
                    : "exclamationmark.triangle.fill"
            )
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(viewModel)
                .environmentObject(store)
                .onDisappear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        let settingsOpen = OpenSettingsAction.findSettingsWindow()?.isVisible == true
                        let gateOpen = NSApp.windows.contains {
                            $0.isVisible
                                && $0.identifier?.rawValue.contains(OpenSettingsAction.permissionGateWindowID) == true
                        }
                        if !settingsOpen && !gateOpen {
                            NSApp.setActivationPolicy(.accessory)
                        }
                    }
                }
        }
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton()
            }
        }
    }
}
