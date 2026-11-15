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

/// Episodes that may start on their own after the one you picked, before Up Next waits for the remote.
enum AutoplayLimit: Int, CaseIterable, CustomStringConvertible {
    case off = 0
    case one = 1
    case three = 3
    case five = 5
    case ten = 10
    case fifteen = 15
    case twenty = 20

    /// The old key counted every episode in a row (2...5); it carries over as the nearest "more" count.
    static let storageKey: String = {
        let defaults = UserDefaults.standard, old = "autoplayLimit", new = "autoplayMoreEpisodes"
        if defaults.object(forKey: new) == nil, defaults.object(forKey: old) != nil {
            let total = defaults.integer(forKey: old)
            defaults.set(total == 0 ? 0 : (allCases.first { $0.rawValue >= total - 1 } ?? .five).rawValue, forKey: new)
            defaults.removeObject(forKey: old)
        }
        return new
    }()

    static var current: AutoplayLimit {
        AutoplayLimit(rawValue: UserDefaults.standard.integer(forKey: storageKey)) ?? .off
    }

    var description: String {
        switch self {
        case .off: String(localized: "Off")
        case .one: String(localized: "1 More Episode")
        default: String(localized: "\(rawValue) More Episodes")
        }
    }

    /// Whether Up Next may count down after `count` episodes in a row (the first is the one you picked).
    func allowsAutoplay(afterEpisodesInARow count: Int) -> Bool { self == .off || count <= rawValue }
}
