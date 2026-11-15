// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// What the player does when the credits start. Replaces the credits skip mode and the
/// "Up Next Panel" toggle (#565).
enum CreditsBehavior: String, CaseIterable {
    case upNext, skipButton, nothing

    static let storageKey = "atTheCredits"
    static let legacyKeys = ["showPostVideoUpNext", "showSkipCredits", "autoSkipCredits"]

    var label: String {
        switch self {
        case .upNext: return String(localized: "Up Next")
        case .skipButton: return String(localized: "Skip Button")
        case .nothing: return String(localized: "Off")
        }
    }

    /// The Up Next card opens when the credits start (episodes).
    var showsUpNextAtCredits: Bool { self == .upNext }
    /// The manual Skip Credits pill shows during the credits.
    var showsSkipPill: Bool { self != .nothing }
    /// Up Next opens at the end of the file instead (episodes).
    var opensUpNextAtEnd: Bool { self != .upNext }

    /// Reads the choice; the first read migrates the old keys and removes them.
    static func current(defaults: UserDefaults = .standard) -> CreditsBehavior {
        if let raw = defaults.string(forKey: storageKey), let value = CreditsBehavior(rawValue: raw) {
            return value
        }
        let value = migrated(upNextPanel: defaults.object(forKey: "showPostVideoUpNext") as? Bool,
                             showSkipCredits: defaults.object(forKey: "showSkipCredits") as? Bool)
        set(value, defaults: defaults)
        for key in legacyKeys { defaults.removeObject(forKey: key) }
        return value
    }

    static func set(_ value: CreditsBehavior, defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: storageKey)
    }

    /// Panel on (or unset) is Up Next. Panel off keeps the pill unless credits skip was Off.
    static func migrated(upNextPanel: Bool?, showSkipCredits: Bool?) -> CreditsBehavior {
        if upNextPanel ?? true { return .upNext }
        return showSkipCredits == false ? .nothing : .skipButton
    }
}
