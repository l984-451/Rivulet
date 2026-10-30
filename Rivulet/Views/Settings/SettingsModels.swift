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
    case plex, plexServerDetail, jellyfin, iptv, libraries, cache
    case silo, siloProfiles, siloProfilePIN, siloSubtitleLanguagePicker
    case homeRows
    case liveTVSourceDetail, liveTVFavorites
    case addLiveTVSource, addXtream, addDispatcharr, addTvheadend, addThreadfin, addPlaylistURL
    case appIconPicker, homeHeroPicker, detailRatingPicker, autoplayCountdownPicker, skipIntervalPicker, skipBackIntervalPicker
    case heightSpeakersPicker, subtitleModePicker, autoplayLimitPicker
    case homeQualityPicker, awayQualityPicker
    case audioLanguagePicker, subtitleLanguagePicker
    case contentFilter, contentFilterStrength, contentFilterWords

    var isSiloFlow: Bool {
        switch self {
        case .silo, .siloProfiles, .siloProfilePIN, .siloSubtitleLanguagePicker: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .root: return "Settings"
        case .appearance: return "Appearance"
        case .playback: return "Playback"
        case .music: return "Music"
        case .liveTV: return "Live TV"
        case .servers: return "Servers"
        case .about: return "About"
        case .plex: return "Plex"
        case .plexServerDetail: return "Server"
        case .jellyfin: return "Jellyfin Server"
        case .silo: return "Silo Server"
        case .siloProfiles: return "Silo Profiles"
        case .siloProfilePIN: return "Profile PIN"
        case .siloSubtitleLanguagePicker: return "Subtitle Language"
        case .iptv: return "Live TV Sources"
        case .liveTVSourceDetail: return "Source Details"
        case .liveTVFavorites: return "Favorites"
        case .addLiveTVSource: return "Add a Source"
        case .addXtream: return "Xtream Codes"
        case .addDispatcharr: return "Dispatcharr"
        case .addTvheadend: return "Tvheadend"
        case .addThreadfin: return "Threadfin"
        case .addPlaylistURL: return "Playlist URL"
        case .libraries: return "Sidebar"
        case .homeRows: return "Home Rows"
        case .cache: return "Cache & Storage"
        case .appIconPicker: return "App Icon"
        case .homeHeroPicker: return "Hero"
        case .detailRatingPicker: return "Rating"
        case .autoplayCountdownPicker: return "Autoplay Countdown"
        case .skipIntervalPicker: return "Skip Forward Length"
        case .skipBackIntervalPicker: return "Skip Back Length"
        case .heightSpeakersPicker: return "Height Speakers"
        case .subtitleModePicker: return "Subtitles"
        case .autoplayLimitPicker: return "Autoplay Limit"
        case .homeQualityPicker: return "Home Streaming"
        case .awayQualityPicker: return "Away Streaming"
        case .audioLanguagePicker: return "Audio Language"
        case .subtitleLanguagePicker: return "Subtitle Language"
        case .contentFilter: return "Content Filtering"
        case .contentFilterStrength: return "Profanity"
        case .contentFilterWords: return "Custom Words"
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

    var description: String { self == .off ? "Off" : "\(rawValue) Episodes" }

    /// Whether Up Next may count down after `count` episodes in a row.
    func allowsAutoplay(afterEpisodesInARow count: Int) -> Bool { self == .off || count < rawValue }
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
    /// Backs Skip Back Length; unset means "same as forward".
    static let backStorageKey = "skipBackSeconds"
    static let defaultValue: SkipInterval = .thirtySeconds

    var description: String { "\(rawValue) seconds" }
}
