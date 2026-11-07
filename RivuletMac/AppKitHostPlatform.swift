// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit

extension HostPlatform {
    private static let iconKey = "macAppIcon"

    /// AppKit's answers for the shared stores; call first thing at launch.
    static func installAppKit() {
        willEnterForeground = NSApplication.willBecomeActiveNotification
        appearanceChangeNotifications = [
            NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            NSApplication.willResignActiveNotification, NSApplication.didBecomeActiveNotification
        ]
        isForeground = { NSApp?.isActive ?? true }
        allowsVideoPreviews = { !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
        alternateIconName = { UserDefaults.standard.string(forKey: iconKey) }
        setAlternateIconName = { name in
            UserDefaults.standard.set(name, forKey: iconKey)
            applySavedIcon()
        }
        // NSApp does not exist yet during App.init; restore the saved Dock icon once it does.
        DispatchQueue.main.async { applySavedIcon() }
    }

    /// Dock icon for the saved choice; nil restores the bundle's own.
    static func applySavedIcon() {
        let name = UserDefaults.standard.string(forKey: iconKey)
        NSApp?.applicationIconImage = name.flatMap { NSImage(named: $0) }
    }
}
