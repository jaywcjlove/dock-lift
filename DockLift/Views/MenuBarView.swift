//
//  MenuBarView.swift
//  DockLift
//

import PermissionFlow
import PermissionFlowStatusStore
import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject private var viewModel: AppViewModel
    @EnvironmentObject private var permissionStatusStore: PermissionFlowStatusStore
    @ObservedObject private var updater = SparkleUpdater.shared

    private var isGranted: Bool {
        permissionStatusStore.state(for: .accessibility) == .granted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text("Enable DockLift")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Toggle(isOn: $viewModel.isEnabled) {
                    EmptyView()
                }
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(!isGranted)
                .accessibilityLabel(Text("Enable DockLift"))
            }
            .padding(.leading, 12)
            .padding(.trailing, 8)
            .padding(.vertical, 6)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                PermissionFlowButton(
                    pane: .accessibility,
                    suggestedAppURLs: [Bundle.main.bundleURL]
                )
                .buttonStyle(.plain)
                .padding(.horizontal, 8)

                Text(viewModel.monitor.isRunning ? "Status: Monitoring" : "Status: Paused")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)

                if !viewModel.monitor.lastEventDescription.isEmpty {
                    Text(viewModel.monitor.lastEventDescription)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)

            Divider()

            VStack(spacing: 0) {
                menuRowButton("Settings…", systemImage: "gearshape") {
                    viewModel.openSettingsOrPermissionGate(accessibilityGranted: isGranted)
                }
                .keyboardShortcut(",", modifiers: .command)

                menuRowButton("Check for Updates…", systemImage: "arrow.triangle.2.circlepath") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheckForUpdates)
            }

            Divider()

            menuRowButton("Quit DockLift", systemImage: "power") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
        .frame(width: 280)
        .padding(.vertical, 4)
        .padding(.horizontal, 4)
    }

    private func menuRowButton(
        _ title: LocalizedStringKey,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(MenuBarRowButtonStyle())
    }
}

// MARK: - Menu-like hover highlight

private struct MenuBarRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuBarRowButton(configuration: configuration)
    }
}

private struct MenuBarRowButton: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.body)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .foregroundStyle(rowForeground)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { hovering in
                guard isEnabled else {
                    isHovering = false
                    return
                }
                isHovering = hovering
            }
            .animation(.easeInOut(duration: 0.08), value: isHovering)
            .animation(.easeInOut(duration: 0.08), value: configuration.isPressed)
    }

    private var rowBackground: Color {
        guard isEnabled else { return .clear }
        if configuration.isPressed {
            return Color.accentColor.opacity(0.85)
        }
        if isHovering {
            return Color.accentColor
        }
        return .clear
    }

    private var rowForeground: Color {
        if isEnabled, isHovering || configuration.isPressed {
            return .white
        }
        return .primary
    }
}
