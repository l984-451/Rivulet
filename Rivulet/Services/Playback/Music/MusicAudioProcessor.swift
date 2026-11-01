// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicAudioProcessor.swift
//  Rivulet
//
//  Audio processing helpers: ReplayGain and the crossfade setting.
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

/// Static helpers for the crossfade setting and gain adjustment.
enum MusicAudioProcessor {

    /// AppStorage key for crossfade duration setting
    static let crossfadeKey = "music_crossfade_duration"

    /// Returns the current crossfade duration from UserDefaults
    static var crossfadeDuration: CrossfadeDuration {
        let rawValue = UserDefaults.standard.integer(forKey: crossfadeKey)
        return CrossfadeDuration(rawValue: rawValue) ?? .off
    }

    // MARK: - ReplayGain

    /// Adjusts volume based on codec characteristics embedded in the track.
    /// Returns a normalized volume value between 0.0 and 1.0.
    ///
    /// For now, uses a conservative loudness normalization based on codec
    /// characteristics — lossless content tends to have wider dynamic range
    /// and may need slight volume reduction. Returns 1.0 if no adjustment needed.
    static func adjustedVolume(for track: MusicTrack) -> Float {
        let codec = (track.audioCodec ?? "").lowercased()
        let isLossless = ["flac", "alac", "wav", "pcm", "aiff"].contains(codec)

        if isLossless {
            // Slight volume reduction for lossless to prevent clipping
            // when content has high dynamic range
            return 0.95
        }

        return 1.0
    }
}
