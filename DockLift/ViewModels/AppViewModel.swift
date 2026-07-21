//
//  AppViewModel.swift
//  DockLift
//
//  Settings + Dock monitor. Does not own Accessibility status.
//

import AppKit
import Combine
import Foundation
import PermissionFlow
import ServiceManagement
import SwiftUI

@MainActor
final class AppViewModel: ObservableObject {
    let monitor: DockActivationMonitor

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: AppSettings.Key.isEnabled)
            refreshMonitor()
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

    @Published private(set) var privateSpaceAPIAvailable: Bool = SpaceMover.isPrivateSpaceAPIAvailable

    private var cancellables = Set<AnyCancellable>()

    init(monitor: DockActivationMonitor? = nil) {
        AppSettings.registerDefaults()
        self.monitor = monitor ?? DockActivationMonitor()

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

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.refreshMonitor()
            }
            .store(in: &cancellables)

        privateSpaceAPIAvailable = SpaceMover.isPrivateSpaceAPIAvailable
        reconcileLaunchAtLoginStatus()
        refreshMonitor()
    }

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

    /// Start/stop Dock monitoring from current enable flag + live Accessibility status.
    func refreshMonitor() {
        privateSpaceAPIAvailable = SpaceMover.isPrivateSpaceAPIAvailable
        let granted = AccessibilityPermissionStatusProvider().authorizationState() == .granted
        let shouldRun = isEnabled && granted
        if shouldRun {
            if monitor.isRunning {
                monitor.start()
            } else {
                monitor.restart()
            }
        } else {
            monitor.stop()
        }
        objectWillChange.send()
    }

    func openSettingsOrPermissionGate(accessibilityGranted: Bool) {
        if accessibilityGranted {
            OpenSettingsAction.requestSettings(force: true)
        } else {
            OpenSettingsAction.requestPermissionGate()
        }
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            let enabled = SMAppService.mainApp.status == .enabled
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

    func addIgnoredBundleID(_ bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !ignoredBundleIdentifiers.contains(trimmed) else { return }
        ignoredBundleIdentifiers.append(trimmed)
    }

    func removeIgnoredBundleID(_ bundleID: String) {
        ignoredBundleIdentifiers.removeAll { $0 == bundleID }
    }
}
