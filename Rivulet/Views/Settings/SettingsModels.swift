// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsModels.swift
//  Rivulet
//
//  Shared Settings value types used by the UIKit Settings surface
//  (`Views/Settings/UIKit/`) and descriptors. Extracted from the retired
//  SwiftUI `SettingsView.swift` so the types outlive that view.
//

import Foundation

// MARK: - Crossfade Option

enum CrossfadeOption: String, CaseIterable, Hashable, CustomStringConvertible {
    case off = "off"
    case threeSeconds = "3s"
    case fiveSeconds = "5s"
    case eightSeconds = "8s"
    case twelveSeconds = "12s"

    var description: String {
        switch self {
        case .off: return "Off"
        case .threeSeconds: return "3s"
        case .fiveSeconds: return "5s"
        case .eightSeconds: return "8s"
        case .twelveSeconds: return "12s"
        }
    }

    var seconds: Int {
        switch self {
        case .off: return 0
        case .threeSeconds: return 3
        case .fiveSeconds: return 5
        case .eightSeconds: return 8
        case .twelveSeconds: return 12
        }
    }
}

// MARK: - Settings Page

enum SettingsPage: Hashable, CaseIterable {
    case root
    case appearance, playback, music, liveTV, servers, about
    case plex, iptv, libraries, cache
    case homeRows
    case liveTVSourceDetail
    case addLiveTVSource, addOwnServer, addPlaylistURL
    case displaySizePicker, autoplayCountdownPicker, skipIntervalPicker
    case contentFilter, contentFilterStrength

    var title: String {
        switch self {
        case .root: return "Settings"
        case .appearance: return "Appearance"
        case .playback: return "Playback"
        case .music: return "Music"
        case .liveTV: return "Live TV"
        case .servers: return "Servers"
        case .about: return "About"
        case .plex: return "Plex Server"
        case .iptv: return "Live TV Sources"
        case .liveTVSourceDetail: return "Source Details"
        case .addLiveTVSource: return "Add a Source"
        case .addOwnServer: return "My Own Server"
        case .addPlaylistURL: return "Playlist URL"
        case .libraries: return "Sidebar Libraries"
        case .homeRows: return "Home Rows"
        case .cache: return "Cache & Storage"
        case .displaySizePicker: return "Display Size"
        case .autoplayCountdownPicker: return "Autoplay Countdown"
        case .skipIntervalPicker: return "Skip Length"
        case .contentFilter: return "Content Filtering"
        case .contentFilterStrength: return "Profanity Strength"
        }
    }
}

// MARK: - Autoplay Countdown

enum AutoplayCountdown: Int, CaseIterable, CustomStringConvertible {
    case off = 0
    case fiveSeconds = 5
    case tenSeconds = 10
    case twentySeconds = 20

    var description: String {
        switch self {
        case .off: return "Off"
        case .fiveSeconds: return "5 seconds"
        case .tenSeconds: return "10 seconds"
        case .twentySeconds: return "20 seconds"
        }
    }
}

// MARK: - Skip Length

/// Single Left/Right tap-skip length (seconds). Drives `InputConfig.tapSeekSeconds`.
/// Values are limited to magnitudes SF Symbols ships numbered goforward/gobackward
/// glyphs for, so the on-screen seek indicator always shows the number.
enum SkipInterval: Int, CaseIterable, CustomStringConvertible {
    case fiveSeconds = 5
    case tenSeconds = 10
    case fifteenSeconds = 15
    case thirtySeconds = 30

    /// UserDefaults key backing the Skip Length setting.
    static let storageKey = "skipSeconds"
    static let defaultValue: SkipInterval = .thirtySeconds

    var description: String { "\(rawValue) seconds" }
}

// Note: DisplaySize enum is in Services/UIScale.swift for global access.
