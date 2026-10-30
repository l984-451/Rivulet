// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  AudioTrack.swift
//  Rivulet
//
//  Per-audio-stream metadata for the audio picker.
//

import Foundation

struct AudioTrack: Hashable, Sendable, Identifiable {
    let id: String
    let index: Int                 // stream index in the container (AVPlayer track index)
    let codec: String              // "eac3", "dca", "truehd", "aac", "opus"
    let profile: String?           // Plex codec profile: "ma" (DTS-HD MA), "dolby truehd + dolby atmos", etc.
    let channels: Int?             // 1, 2, 6, 8
    let channelLayout: String?     // Plex layout, e.g. "5.1(side)", "stereo"
    let language: String?          // "en", "ja"
    let title: String?             // displayable (e.g. "English Commentary")
    let extendedTitle: String?     // long-form Plex `extendedDisplayTitle` etc.
    let bitrate: Int?
    let samplingRate: Int?
    let isDefault: Bool
    let isForced: Bool
    /// Backend-side "this is the user's current pick" flag (Plex `selected: true`,
    /// Jellyfin equivalent). Distinct from `isDefault` — `isDefault` is the
    /// file's authoring default, while `isSelected` reflects a per-user-per-item
    /// override that may have been set in any client.
    let isSelected: Bool
    var bitDepth: Int? = nil
    /// Explicit source metadata only; TrueHD by itself does not imply Atmos.
    var hasAtmos = false
}

extension AudioTrack {
    /// Codec family/variant independent of channels and object-audio signaling.
    var codecLabel: String {
        let p = profile?.lowercased() ?? ""
        let name: String
        switch codec.lowercased() {
        case "ac3":                     name = "AC3"
        case "eac3":                    name = "E-AC3"
        case "truehd":                  name = "TrueHD"
        case "dca", "dts":
            if p.contains("ma")     {   name = "DTS-HD MA" }
            else if p.contains("x") {   name = "DTS-X" }
            else                    {   name = "DTS" }
        case "flac":                    name = "FLAC"
        case "alac":                    name = "ALAC"
        case "pcm", "lpcm":             name = "PCM"
        case let c where c.hasPrefix("pcm_"): name = "PCM"
        case "aac":                     name = "AAC"
        case "opus":                    name = "Opus"
        case "mp3", "mp2":              name = "MP3"
        default:                        name = codec.uppercased()
        }
        return name
    }

    var isAtmos: Bool { hasAtmos || profile?.localizedCaseInsensitiveContains("atmos") == true }

    /// Variant-accurate codec, channel layout and explicit Atmos signaling.
    var qualityLabel: String {
        var name = codecLabel
        if let layout = channelLayoutLabel { name += " \(layout)" }
        if isAtmos { name += " Atmos" }
        return name
    }

    /// Normalized channel layout: drops placement suffix ("5.1(side)" → "5.1"),
    /// maps "stereo"/"mono" → "2.0"/"1.0", falls back to channel count.
    var channelLayoutLabel: String? {
        if let raw = channelLayout, !raw.isEmpty {
            let base = raw.lowercased()
                .split(separator: "(").first
                .map { String($0).trimmingCharacters(in: .whitespaces) } ?? raw.lowercased()
            switch base {
            case "mono":   return "1.0"
            case "stereo": return "2.0"
            default:       return base
            }
        }
        switch channels {
        case 1:          return "1.0"
        case 2:          return "2.0"
        case 6:          return "5.1"
        case 7:          return "6.1"
        case 8:          return "7.1"
        case let n? where n > 0: return "\(n).0"
        default:         return nil
        }
    }
}
