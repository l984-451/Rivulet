// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A presentation preference for this Apple TV, independent of the selected server/profile.
enum AppTheme: String, CaseIterable {
    case standard
    case cinematic

    static let storageKey = "appTheme"
    static var current: AppTheme { stored(in: .standard) }

    static func stored(in defaults: UserDefaults) -> AppTheme {
        defaults.string(forKey: storageKey).flatMap(Self.init(rawValue:)) ?? .standard
    }

    var title: String {
        switch self {
        case .standard: String(localized: "Standard")
        case .cinematic: String(localized: "Cinematic")
        }
    }

    func apply(to defaults: UserDefaults = .standard) {
        guard Self.stored(in: defaults) != self else { return }
        defaults.set(rawValue, forKey: Self.storageKey)
        NotificationCenter.default.post(name: .appThemeDidChange, object: nil)
    }
}

extension Notification.Name {
    static let appThemeDidChange = Notification.Name("appThemeDidChange")
}
