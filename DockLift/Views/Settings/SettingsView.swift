//
//  SettingsView.swift
//  DockLift
//
//  Each tab has its own preferred size so the Settings window resizes
//  when switching panes (General taller, About compact, etc.).
//

import SwiftUI
import PermissionFlowStatusStore

enum SettingsPane: String, CaseIterable, Identifiable, Hashable {
    case general
    case permissions
    case advanced
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return String(localized: "General")
        case .permissions: return String(localized: "Permissions")
        case .advanced: return String(localized: "Advanced")
        case .about: return String(localized: "About")
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .permissions: return "hand.raised"
        case .advanced: return "slider.horizontal.3"
        case .about: return "info.circle"
        }
    }

    /// Ideal content size for this pane (excluding the tab bar chrome).
    var preferredSize: CGSize {
        switch self {
        case .general:
            return CGSize(width: 420, height: 560)
        case .permissions:
            return CGSize(width: 420, height: 440)
        case .advanced:
            return CGSize(width: 420, height: 540)
        case .about:
            return CGSize(width: 420, height: 360)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var permission: PermissionFlowStatusStore
    @State private var pane: SettingsPane = .general

    private var isGranted: Bool {
        permission.state(for: .accessibility) == .granted
    }
    var body: some View {
        TabView(selection: $pane) {
            paneContainer(for: .general) {
                GeneralSettingsView()
            }

            paneContainer(for: .permissions) {
                PermissionsSettingsView()
            }

            paneContainer(for: .advanced) {
                AdvancedSettingsView()
            }

            paneContainer(for: .about) {
                AboutSettingsView()
            }
        }
        // Drive the Settings window size from the active tab.
        .frame(
            width: pane.preferredSize.width,
            height: pane.preferredSize.height
        )
        .animation(.snappy(duration: 0.22), value: pane)
        .onAppear {
            permission.refresh(.accessibility)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            permission.refresh(.accessibility)
            if isGranted == false {
                pane = .permissions
            }
        }
    }

    @ViewBuilder
    private func paneContainer<Content: View>(
        for pane: SettingsPane,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .environmentObject(viewModel)
            .frame(
                width: pane.preferredSize.width,
                height: pane.preferredSize.height,
                alignment: .topLeading
            )
            .tabItem {
                Label(pane.title, systemImage: pane.systemImage)
            }
            .tag(pane)
    }
}
