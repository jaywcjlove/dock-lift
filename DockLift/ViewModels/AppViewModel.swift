//
//  AppViewModel.swift
//  DockLift
//
//  Central MVVM façade for menu bar UI, settings, and monitoring lifecycle.
//

import AppKit
import ApplicationServices
import Combine
import Foundation
import PermissionFlow
import PermissionFlowStatusStore
import ServiceManagement
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    // MARK: - Dependencies

    let accessibility: AccessibilityPermission
    let monitor: DockActivationMonitor
    private let windowManager: WindowManager

    // MARK: - Published settings (mirrored to UserDefaults)

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: AppSettings.Key.isEnabled)
            syncMonitoring()
        }
    }

    @Published var onlyWhenDockClick: Bool {
        didSet { UserDefaults.standard.set(onlyWhenDockClick, forKey: AppSettings.Key.onlyWhenDockClick) }
    }

    @Published var includeMinimizedWindows: Bool {
        didSet {
            UserDefaults.standard.set(
                includeMinimizedWindows,
                forKey: AppSettings.Key.includeMinimizedWindows
            )
        }
    }

    @Published var preferMoveToCurrentSpace: Bool {
        didSet {
            UserDefaults.standard.set(
                preferMoveToCurrentSpace,
                forKey: AppSettings.Key.preferMoveToCurrentSpace
            )
        }
    }

    @Published var moveToDockScreen: Bool {
        didSet {
            UserDefaults.standard.set(
                moveToDockScreen,
                forKey: AppSettings.Key.moveToDockScreen
            )
        }
    }

    @Published var useMinimizeFallback: Bool {
        didSet {
            UserDefaults.standard.set(
                useMinimizeFallback,
                forKey: AppSettings.Key.useMinimizeFallback
            )
        }
    }

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: AppSettings.Key.launchAtLogin)
            updateLaunchAtLogin()
        }
    }

    @Published var showStatusItemTitle: Bool {
        didSet {
            UserDefaults.standard.set(showStatusItemTitle, forKey: AppSettings.Key.showStatusItemTitle)
        }
    }

    @Published var ignoredBundleIdentifiers: [String] {
        didSet {
            UserDefaults.standard.set(
                ignoredBundleIdentifiers,
                forKey: AppSettings.Key.ignoredBundleIdentifiers
            )
        }
    }

    // MARK: - Status

    @Published private(set) var privateSpaceAPIAvailable: Bool = SpaceMover.isPrivateSpaceAPIAvailable

    /// Convenience: Accessibility granted via real AX trust (required for window
    /// control and global event monitors). PermissionFlow UI state alone is not enough.
    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted() || accessibility.isTrusted
    }

    var statusSymbolName: String {
        if !hasAccessibilityPermission { return "exclamationmark.triangle.fill" }
        return isEnabled ? "dock.rectangle" : "dock.rectangle"
    }

    var statusAccessibilityLabel: String {
        if !hasAccessibilityPermission {
            return String(localized: "DockLift — Accessibility required")
        }
        return isEnabled
            ? String(localized: "DockLift — On")
            : String(localized: "DockLift — Off")
    }

    private var cancellables = Set<AnyCancellable>()

    // MARK: - Init

    init(
        accessibility: AccessibilityPermission? = nil,
        monitor: DockActivationMonitor? = nil,
        windowManager: WindowManager? = nil
    ) {
        AppSettings.registerDefaults()

        self.accessibility = accessibility ?? AccessibilityPermission()
        self.monitor = monitor ?? DockActivationMonitor()
        self.windowManager = windowManager ?? .shared

        let defaults = UserDefaults.standard
        self.isEnabled = defaults.object(forKey: AppSettings.Key.isEnabled) as? Bool ?? true
        self.onlyWhenDockClick = defaults.object(forKey: AppSettings.Key.onlyWhenDockClick) as? Bool ?? true
        self.includeMinimizedWindows =
            defaults.object(forKey: AppSettings.Key.includeMinimizedWindows) as? Bool ?? true
        self.preferMoveToCurrentSpace =
            defaults.object(forKey: AppSettings.Key.preferMoveToCurrentSpace) as? Bool ?? true
        self.moveToDockScreen =
            defaults.object(forKey: AppSettings.Key.moveToDockScreen) as? Bool ?? true
        self.useMinimizeFallback =
            defaults.object(forKey: AppSettings.Key.useMinimizeFallback) as? Bool ?? true
        self.launchAtLogin = defaults.bool(forKey: AppSettings.Key.launchAtLogin)
        self.showStatusItemTitle = defaults.bool(forKey: AppSettings.Key.showStatusItemTitle)
        self.ignoredBundleIdentifiers =
            defaults.stringArray(forKey: AppSettings.Key.ignoredBundleIdentifiers)
            ?? (AppSettings.defaults[AppSettings.Key.ignoredBundleIdentifiers] as? [String] ?? [])

        self.monitor.policyProvider = { [weak self] in
            guard let self else {
                return LiftPolicy(
                    isEnabled: false,
                    onlyWhenDockClick: true,
                    includeMinimizedWindows: true,
                    preferMoveToCurrentSpace: true,
                    moveToDockScreen: true,
                    useMinimizeFallback: true,
                    ignoredBundleIdentifiers: []
                )
            }
            return self.currentPolicy()
        }

        // Re-sync when Accessibility trust flips.
        self.accessibility.$isTrusted
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                self?.syncMonitoring()
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.syncMonitoring()
            }
            .store(in: &cancellables)

        syncMonitoring()
        reconcileLaunchAtLoginStatus()
    }

    // MARK: - Policy

    func currentPolicy() -> LiftPolicy {
        LiftPolicy(
            isEnabled: isEnabled,
            onlyWhenDockClick: onlyWhenDockClick,
            includeMinimizedWindows: includeMinimizedWindows,
            preferMoveToCurrentSpace: preferMoveToCurrentSpace,
            moveToDockScreen: moveToDockScreen,
            useMinimizeFallback: useMinimizeFallback,
            ignoredBundleIdentifiers: Set(ignoredBundleIdentifiers)
        )
    }

    // MARK: - Monitoring

    func syncMonitoring() {
        let wasTrusted = accessibility.isTrusted
        accessibility.refresh()
        privateSpaceAPIAvailable = SpaceMover.isPrivateSpaceAPIAvailable
        objectWillChange.send()

        let trusted = AXIsProcessTrusted()
        if isEnabled && trusted {
            // After Accessibility is newly granted, global monitors must be
            // re-registered — ones installed while untrusted often stay nil/dead.
            if !wasTrusted && trusted {
                monitor.restart()
            } else {
                monitor.start()
            }
        } else {
            monitor.stop()
        }
    }

    func toggleEnabled() {
        isEnabled.toggle()
    }

    /// Opens PermissionFlow Accessibility authorization UI.
    func requestAccessibility() {
        accessibility.requestAccess()
        syncMonitoring()
    }

    /// Settings if authorized; otherwise the permission gate.
    func openSettingsOrPermissionGate() {
        syncMonitoring()
        if hasAccessibilityPermission {
            OpenSettingsAction.requestSettings(force: true)
        } else {
            OpenSettingsAction.requestPermissionGate()
        }
    }

    // MARK: - Launch at login

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let status = SMAppService.mainApp.status
            let enabled = (status == .enabled)
            if launchAtLogin != enabled {
                launchAtLogin = enabled
            }
        }
    }

    private func reconcileLaunchAtLoginStatus() {
        let enabled = SMAppService.mainApp.status == .enabled
        if launchAtLogin != enabled {
            launchAtLogin = enabled
        }
    }

    // MARK: - Ignore list helpers

    func addIgnoredBundleID(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ignoredBundleIdentifiers.contains(trimmed) else { return }
        ignoredBundleIdentifiers.append(trimmed)
    }

    func removeIgnoredBundleID(_ bundleID: String) {
        ignoredBundleIdentifiers.removeAll { $0 == bundleID }
    }
}
