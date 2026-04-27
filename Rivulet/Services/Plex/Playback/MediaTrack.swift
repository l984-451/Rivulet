//
//  MediaTrack.swift
//  Rivulet
//
//  Unified track model for audio and subtitle streams
//

import Foundation

/// Represents an audio or subtitle track from any player engine
struct MediaTrack: Identifiable, Equatable, Sendable {
    let id: Int
    let name: String
    let language: String?
    let languageCode: String?
    let codec: String?
    let isDefault: Bool
    let isForced: Bool
    let isHearingImpaired: Bool

    /// Plex's long-form descriptive title when present (e.g.,
    /// "English (AC3 5.1) - Director's Commentary"). Preferred over `name`
    /// in user-facing pickers so commentary / audio-description / SDH
    /// tracks are distinguishable from the main mix.
    let extendedDisplayTitle: String?

    // Audio-specific
    let channels: Int?

    // Subtitle-specific
    let subtitleKey: String?  // Plex URL path for external subtitles (e.g., "/library/streams/12345")

    init(
        id: Int,
        name: String,
        language: String? = nil,
        languageCode: String? = nil,
        codec: String? = nil,
        isDefault: Bool = false,
        isForced: Bool = false,
        isHearingImpaired: Bool = false,
        extendedDisplayTitle: String? = nil,
        channels: Int? = nil,
        subtitleKey: String? = nil
    ) {
        self.id = id
        self.name = name
        self.language = language
        self.languageCode = languageCode
        self.codec = codec
        self.isDefault = isDefault
        self.isForced = isForced
        self.isHearingImpaired = isHearingImpaired
        self.extendedDisplayTitle = extendedDisplayTitle
        self.channels = channels
        self.subtitleKey = subtitleKey
    }

    /// Creates a MediaTrack from a PlexStream
    init(from stream: PlexStream) {
        self.id = stream.id
        self.name = stream.displayTitle ?? stream.title ?? stream.language ?? "Track \(stream.id)"
        self.language = stream.language
        self.languageCode = stream.languageCode
        self.codec = stream.codec
        self.isDefault = stream.default ?? false
        self.isForced = stream.forced ?? false
        self.isHearingImpaired = stream.hearingImpaired ?? false
        self.extendedDisplayTitle = stream.extendedDisplayTitle
        self.channels = stream.channels
        self.subtitleKey = stream.key
    }

    /// Display name with additional info. Prefers Plex's long-form
    /// `extendedDisplayTitle` when present so commentary / SDH / etc.
    /// are distinguishable; otherwise falls back to the synthesized
    /// `name`. Forced / SDH suffixes are appended in either case.
    var displayName: String {
        var components: [String] = [extendedDisplayTitle ?? name]

        if isForced {
            components.append("(Forced)")
        }
        if isHearingImpaired {
            components.append("(SDH)")
        }

        return components.joined(separator: " ")
    }

    // MARK: - Audio Display Helpers

    /// Formatted codec name (e.g., "AAC", "TrueHD", "DTS-HD MA")
    var formattedCodec: String {
        guard let codec = codec?.lowercased() else { return "Audio" }

        switch codec {
        case "aac": return "AAC"
        case "ac3", "a_ac3": return "AC3"
        case "eac3", "a_eac3": return "EAC3"
        case "truehd", "a_truehd": return "TrueHD"
        case "dts": return "DTS"
        case "dca": return "DTS"
        case "dtshd", "dts-hd": return "DTS-HD"
        case "dts-hd ma", "dtshd-ma": return "DTS-HD MA"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "mp3", "mp2": return "MP3"
        case "pcm", "lpcm": return "LPCM"
        case "vorbis": return "Vorbis"
        // Subtitles
        case "subrip", "srt": return "SRT"
        case "ass", "ssa": return "ASS"
        case "pgs", "hdmv_pgs_subtitle", "pgssub": return "PGS"
        case "dvdsub", "dvd_subtitle": return "VOBSUB"
        case "mov_text": return "TX3G"
        case "webvtt", "vtt": return "WebVTT"
        case "cc_dec": return "CC"
        default: return codec.uppercased()
        }
    }

    /// Normalize subtitle codec names to a canonical lowercase identifier so
    /// Plex and FFmpeg names compare equal (e.g. "subrip" ↔ "srt",
    /// "hdmv_pgs_subtitle" ↔ "pgs"). Used for matching, not display.
    static func normalizedSubtitleCodec(_ codec: String?) -> String {
        guard let codec = codec?.lowercased() else { return "unknown" }
        switch codec {
        case "subrip", "srt": return "srt"
        case "ass", "ssa": return "ass"
        case "pgs", "hdmv_pgs_subtitle", "pgssub": return "pgs"
        case "dvdsub", "dvd_subtitle": return "dvdsub"
        case "mov_text", "tx3g": return "mov_text"
        case "webvtt", "vtt": return "webvtt"
        default: return codec
        }
    }

    /// Inferred channel count from either explicit channels or parsed from name
    private var inferredChannels: Int? {
        // Use explicit channels if available
        if let channels = channels, channels > 0 {
            return channels
        }

        // Try to parse from track name ("2ch", "6ch", etc. are common)
        let nameLower = name.lowercased()

        // Check for explicit channel count patterns
        if let match = nameLower.range(of: #"(\d+)\s*ch"#, options: .regularExpression) {
            let numStr = nameLower[match].filter { $0.isNumber }
            if let num = Int(numStr) {
                return num
            }
        }

        // Check for common layout names
        if nameLower.contains("7.1") { return 8 }
        if nameLower.contains("5.1") { return 6 }
        if nameLower.contains("stereo") { return 2 }
        if nameLower.contains("mono") { return 1 }

        return nil
    }

    /// Channel layout description (e.g., "Stereo", "5.1", "7.1")
    var channelLayout: String {
        guard let channels = inferredChannels else { return "" }

        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 3: return "2.1"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels)ch"
        }
    }

    /// Full audio format string (e.g., "AAC · Stereo", "TrueHD · 7.1")
    var audioFormatString: String {
        var parts: [String] = [formattedCodec]
        if !channelLayout.isEmpty {
            parts.append(channelLayout)
        }
        return parts.joined(separator: " · ")
    }

    /// Language as uppercase display string (e.g., "ENGLISH", "SPANISH")
    var languageDisplay: String {
        // Get the language code to convert
        let code = languageCode ?? language

        guard let code = code, !code.isEmpty else {
            return "UNKNOWN"
        }

        // Convert language code to full name using Locale
        if let fullName = Locale.current.localizedString(forLanguageCode: code) {
            return fullName.uppercased()
        }

        // Fallback: common language codes
        switch code.lowercased() {
        case "eng", "en": return "ENGLISH"
        case "spa", "es": return "SPANISH"
        case "fra", "fr": return "FRENCH"
        case "deu", "de", "ger": return "GERMAN"
        case "ita", "it": return "ITALIAN"
        case "por", "pt": return "PORTUGUESE"
        case "jpn", "ja": return "JAPANESE"
        case "kor", "ko": return "KOREAN"
        case "zho", "zh", "chi": return "CHINESE"
        case "rus", "ru": return "RUSSIAN"
        case "ara", "ar": return "ARABIC"
        case "hin", "hi": return "HINDI"
        case "und": return "UNKNOWN"
        default: return code.uppercased()
        }
    }
}
