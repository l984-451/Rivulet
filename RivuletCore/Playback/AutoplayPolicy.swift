// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

// MARK: - Autoplay Countdown

enum AutoplayCountdown: Int, CaseIterable, CustomStringConvertible {
    case off = 0
    case fiveSeconds = 5
    case tenSeconds = 10
    case twentySeconds = 20

    static let storageKey = "autoplayCountdown"

    /// The Countdown setting: 5 seconds when unset.
    static var current: AutoplayCountdown {
        guard UserDefaults.standard.object(forKey: storageKey) != nil else { return .fiveSeconds }
        return AutoplayCountdown(rawValue: UserDefaults.standard.integer(forKey: storageKey)) ?? .fiveSeconds
    }

    var description: String {
        switch self {
        case .off: return String(localized: "Off")
        case .fiveSeconds: return String(localized: "5 seconds")
        case .tenSeconds: return String(localized: "10 seconds")
        case .twentySeconds: return String(localized: "20 seconds")
        }
    }
}

// MARK: - Autoplay Limit

/// Episodes that may play in a row before Up Next waits for the remote.
enum AutoplayLimit: Int, CaseIterable, CustomStringConvertible {
    case off = 0
    case two = 2
    case three = 3
    case four = 4
    case five = 5

    static let storageKey = "autoplayLimit"

    static var current: AutoplayLimit {
        AutoplayLimit(rawValue: UserDefaults.standard.integer(forKey: storageKey)) ?? .off
    }

    var description: String { self == .off ? String(localized: "Off") : String(localized: "\(rawValue) Episodes") }

    /// Whether Up Next may count down after `count` episodes in a row.
    func allowsAutoplay(afterEpisodesInARow count: Int) -> Bool { self == .off || count < rawValue }
}
