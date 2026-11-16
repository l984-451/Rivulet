// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicAudioProcessor.swift
//  Rivulet
//
//  The crossfade and loudness leveling settings.
//

import Foundation

// MARK: - Crossfade Duration Setting

/// User-configurable crossfade duration, persisted via AppStorage
enum CrossfadeDuration: Int, CaseIterable, CustomStringConvertible, Sendable {
    case off = 0
    case short = 2
    case medium = 5
    case long = 8
    case veryLong = 12

    var description: String {
        switch self {
        case .off: return String(localized: "Off")
        case .short: return "2s"
        case .medium: return "5s"
        case .long: return "8s"
        case .veryLong: return "12s"
        }
    }

    var seconds: TimeInterval {
        TimeInterval(rawValue)
    }
}

// MARK: - Audio Processor

/// Static helpers for the music settings.
enum MusicAudioProcessor {

    /// Settings > Music > Loudness Leveling, off by default.
    static let loudnessLevelingKey = "musicLoudnessLeveling"

    static var levelsLoudness: Bool {
        SettingsStore.bool(loudnessLevelingKey, default: false)
    }

    /// AppStorage key for crossfade duration setting
    static let crossfadeKey = "music_crossfade_duration"

    /// Returns the current crossfade duration from UserDefaults
    static var crossfadeDuration: CrossfadeDuration {
        let rawValue = UserDefaults.standard.integer(forKey: crossfadeKey)
        return CrossfadeDuration(rawValue: rawValue) ?? .off
    }
}
