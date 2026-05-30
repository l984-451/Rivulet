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
    let profile: String?           // Plex codec profile: "ma" (DTS-HD MA),
                                   // "dolby truehd + dolby atmos", etc.
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
}

extension AudioTrack {
    /// Variant-accurate codec + channel layout for the quality badge, e.g.
    /// "E-AC3 5.1", "DTS-HD MA 7.1", "TrueHD 7.1 Atmos", "AC3 2.0", "FLAC 1.0".
    /// The codec name distinguishes lossless families (TrueHD / DTS-HD MA /
    /// DTS-X / FLAC / ALAC / PCM) from lossy ones (AC3 / E-AC3 / DTS / AAC /
    /// ...) so a knowledgeable reader can infer losslessness from the label.
    /// Atmos is taken from Plex's `profile` ("dolby ... + dolby atmos"), not
    /// the channel layout, because Atmos height is object metadata, not
    /// discrete channels. The layout is the track's own, never assumed.
    var qualityLabel: String {
        let p = (profile ?? "").lowercased()
        var name: String
        switch codec.lowercased() {
        case "truehd":            name = "TrueHD"
        case "eac3", "ec-3":      name = "E-AC3"
        case "ac3", "ac-3":       name = "AC3"
        case "dca", "dts":
            if p.contains("ma")                            { name = "DTS-HD MA" }
            else if p.contains("dts:x") || p.contains("dtsx") { name = "DTS-X" }
            else if p.contains("hra")                      { name = "DTS-HD HRA" }
            else                                           { name = "DTS" }
        case "flac":              name = "FLAC"
        case "alac":              name = "ALAC"
        case "pcm", "lpcm":       name = "PCM"
        case let c where c.hasPrefix("pcm_"): name = "PCM"
        case "aac":               name = "AAC"
        case "opus":              name = "Opus"
        case "mp3", "mp2":        name = "MP3"
        case "vorbis":            name = "Vorbis"
        case "wmapro", "wmav2", "wma": name = "WMA"
        default:                  name = codec.uppercased()
        }
        if let layout = channelLayoutLabel { name += " \(layout)" }
        if p.contains("atmos") { name += " Atmos" }
        return name
    }

    /// Normalized channel layout: drops the surround-placement suffix
    /// ("5.1(side)" -> "5.1"), maps "stereo"/"mono" to "2.0"/"1.0", and falls
    /// back to a count-derived layout when Plex supplies no layout string
    /// (e.g. PCM). nil when neither layout nor channel count is known.
    private var channelLayoutLabel: String? {
        if let raw = channelLayout, !raw.isEmpty {
            let base = raw.lowercased()
                .split(separator: "(").first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? raw.lowercased()
            switch base {
            case "mono":   return "1.0"
            case "stereo": return "2.0"
            default:       return base   // "5.1", "7.1", "3.0", "4.0", ...
            }
        }
        switch channels {
        case 1:  return "1.0"
        case 2:  return "2.0"
        case 6:  return "5.1"
        case 7:  return "6.1"
        case 8:  return "7.1"
        case let n? where n > 0: return "\(n).0"
        default: return nil
        }
    }
}
