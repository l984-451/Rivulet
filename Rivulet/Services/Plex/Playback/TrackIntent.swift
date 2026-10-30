// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  Audio and subtitle track memory (UserDefaults, last write wins, per Plex Home
//  profile). Forced and regular subtitles are different intents: a regular
//  intent falls back to a forced track, a forced intent never takes a regular one.
//

import Foundation

// MARK: - Intent Model

/// What the user wants for subtitles, globally.
///
/// `.off` is only ever written by an explicit user pick. Resolution that
/// *falls back* to off (because the current title has no matching track)
/// must NOT overwrite the stored intent — it re-engages on the next title
/// that does have a match.
enum SubtitleIntent: Codable, Equatable {
    case off
    case track(language: String, forced: Bool, hearingImpaired: Bool, codec: String?)
    /// Full subtitles in `language` when the audio is in another language,
    /// forced ones when it isn't. The default when nothing is stored.
    case foreignAudio(language: String, hearingImpaired: Bool)
}

/// What the user wants for audio, globally.
struct AudioIntent: Codable, Equatable {
    let language: String
    let codec: String?
    let channels: Int?

    init(language: String, codec: String? = nil, channels: Int? = nil) {
        self.language = language
        self.codec = codec
        self.channels = channels
    }
}

// MARK: - Track Intent Construction

extension SubtitleIntent {
    /// Build an intent from a track the user explicitly picked.
    /// Tracks with no language code are still worth remembering by codec, so
    /// fall back to an empty-string language rather than refusing to store.
    init(from track: MediaTrack) {
        self = .track(
            language: track.languageCode ?? track.language ?? "",
            forced: track.isForced,
            hearingImpaired: track.isHearingImpaired,
            codec: track.codec
        )
    }

    /// The intent a player pick leaves behind. Under Foreign Audio, a pick
    /// that fits the mode (a forced track, or subtitles over foreign audio)
    /// keeps the mode and only updates the language, and Off covers the
    /// current title only (#432). A forced pick means "on in this language",
    /// never a switch to Forced Only (#425).
    static func afterPick(_ track: MediaTrack?, replacing current: SubtitleIntent,
                          audioLanguage: String?) -> SubtitleIntent {
        guard let track else {
            if case .foreignAudio = current { return current }
            return .off
        }
        let language = track.languageCode ?? track.language ?? ""
        if case .foreignAudio = current, TrackLanguage.isKnown(language),
           track.isForced || TrackLanguage.isForeign(audioLanguage, to: language) {
            return .foreignAudio(language: language, hearingImpaired: track.isHearingImpaired)
        }
        var forced = false
        if track.isForced, case .track(_, true, _, _) = current { forced = true }
        return .track(language: language, forced: forced,
                      hearingImpaired: track.isHearingImpaired, codec: track.codec)
    }

    /// The subtitle language this intent asks for, if any.
    var language: String? {
        switch self {
        case .off: return nil
        case .track(let language, _, _, _), .foreignAudio(let language, _):
            return TrackLanguage.isKnown(language) ? language : nil
        }
    }
}

extension AudioIntent {
    init(from track: MediaTrack) {
        self.init(
            language: track.languageCode ?? track.language ?? "",
            codec: track.codec,
            channels: track.channels
        )
    }
}

// MARK: - Language Normalization

enum TrackLanguage {
    /// Normalize a language code to a canonical comparison key.
    ///
    /// Sources are wildly inconsistent: Plex reports "eng", AetherEngine
    /// reports whatever the container says ("en", "eng", sometimes
    /// "English"). Map the common two-letter / three-letter / English-name
    /// spellings of the same language onto a single key so they compare equal.
    static func normalize(_ code: String?) -> String {
        guard let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return "" }

        switch raw {
        case "en", "eng", "english": return "eng"
        case "es", "spa", "esp", "spanish", "castilian": return "spa"
        case "fr", "fra", "fre", "french": return "fra"
        case "de", "deu", "ger", "german": return "deu"
        case "it", "ita", "italian": return "ita"
        case "pt", "por", "portuguese": return "por"
        case "ja", "jpn", "japanese": return "jpn"
        case "ko", "kor", "korean": return "kor"
        case "zh", "zho", "chi", "chinese", "mandarin": return "zho"
        case "ru", "rus", "russian": return "rus"
        case "ar", "ara", "arabic": return "ara"
        case "hi", "hin", "hindi": return "hin"
        case "nl", "nld", "dut", "dutch": return "nld"
        case "sv", "swe", "swedish": return "swe"
        case "no", "nor", "norwegian": return "nor"
        case "da", "dan", "danish": return "dan"
        case "fi", "fin", "finnish": return "fin"
        case "pl", "pol", "polish": return "pol"
        case "tr", "tur", "turkish": return "tur"
        case "he", "heb", "hebrew": return "heb"
        case "th", "tha", "thai": return "tha"
        case "vi", "vie", "vietnamese": return "vie"
        case "cs", "ces", "cze", "czech": return "ces"
        case "el", "ell", "gre", "greek": return "ell"
        case "hu", "hun", "hungarian": return "hun"
        case "uk", "ukr", "ukrainian": return "ukr"
        default: return raw
        }
    }

    static let english = "eng"

    /// Audio intent sentinel: the file's main (default) track, whatever its language.
    static let original = "original"

    /// Languages offered in Settings, as normalized keys.
    static let choices = [
        "ara", "zho", "ces", "dan", "nld", "eng", "fin", "fra", "deu", "ell",
        "heb", "hin", "hun", "ita", "jpn", "kor", "nor", "pol", "por", "rus",
        "spa", "swe", "tha", "tur", "ukr", "vie"
    ]

    /// The device's language, the subtitle default.
    static var device: String {
        let code = normalize(Locale.current.language.languageCode?.identifier)
        return code.isEmpty ? english : code
    }

    static func displayName(_ code: String) -> String {
        let alpha2 = Locale.LanguageCode(code).identifier(.alpha2) ?? code
        return Locale.current.localizedString(forLanguageCode: alpha2)?.capitalized ?? code
    }

    /// False for missing, undetermined and "no linguistic content" tags.
    static func isKnown(_ code: String?) -> Bool {
        !["", "und", "mis", "mul", "zxx"].contains(normalize(code))
    }

    /// Both languages known and different.
    static func isForeign(_ audio: String?, to subtitle: String?) -> Bool {
        isKnown(audio) && isKnown(subtitle) && !matches(audio, subtitle)
    }

    static func matches(_ a: String?, _ b: String?) -> Bool {
        let na = normalize(a)
        let nb = normalize(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        return na == nb
    }
}

// MARK: - Codec Normalization / Ranking

enum TrackCodec {
    /// Canonical lowercase codec key for *matching* (not display).
    /// Mirrors `MediaTrack.normalizedSubtitleCodec`'s style, extended to audio.
    static func normalize(_ codec: String?) -> String {
        guard let raw = codec?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return "" }

        switch raw {
        // Audio
        case "aac", "a_aac", "aac_latm": return "aac"
        case "ac3", "a_ac3", "ac-3": return "ac3"
        case "eac3", "a_eac3", "e-ac-3", "ec-3": return "eac3"
        case "truehd", "a_truehd", "mlp": return "truehd"
        case "dts", "dca": return "dts"
        case "dtshd", "dts-hd", "dts_hd": return "dtshd"
        case "dts-hd ma", "dtshd-ma", "dtshd_ma", "dts-hd_ma": return "dtshdma"
        case "flac", "a_flac": return "flac"
        case "opus", "a_opus": return "opus"
        case "mp3", "mp2": return "mp3"
        case "pcm", "lpcm": return "pcm"
        case "vorbis", "a_vorbis": return "vorbis"
        // Subtitles
        case "subrip", "srt": return "srt"
        case "ass", "ssa": return "ass"
        case "pgs", "hdmv_pgs_subtitle", "pgssub": return "pgs"
        case "dvdsub", "dvd_subtitle", "vobsub": return "dvdsub"
        case "mov_text", "tx3g": return "mov_text"
        case "webvtt", "vtt": return "webvtt"
        default: return raw
        }
    }

    static func matches(_ a: String?, _ b: String?) -> Bool {
        normalize(a) == normalize(b)
    }

    /// Audio codec quality tier, high → low.
    /// TrueHD / DTS-HD MA (lossless) → EAC3 / DTS → AC3 → AAC → everything else.
    static func audioTier(_ codec: String?) -> Int {
        switch normalize(codec) {
        case "truehd", "dtshdma", "dtshd", "flac", "pcm": return 4
        case "eac3", "dts": return 3
        case "ac3": return 2
        case "aac": return 1
        default: return 0
        }
    }
}

// MARK: - Commentary / Audio-Description Detection

enum TrackCommentary {
    /// Keywords that mark a track as commentary or audio description.
    private static let markers = [
        "commentary",
        "commentaire",
        "kommentar",
        "comentario",
        "commento",
        "director",
        "description",
        "descriptive",
        "described",
        "narration",
        "dvs",
        "visually impaired",
        "visual impaired"
    ]

    /// Whether a track is commentary or audio description, excluded from auto-select only.
    /// Plex has no flag for either, so the Plex side is a title-text match.
    static func isCommentaryOrDescription(_ track: MediaTrack) -> Bool {
        // AetherEngine reads the container's disposition bits and reports this
        // outright. Trust it when set; the title match below is the fallback for
        // files that don't flag the disposition (and for the Plex/HLS route,
        // which has no such flag at all).
        if track.isCommentary || track.isAudioDescription { return true }

        let haystacks = [track.extendedDisplayTitle, track.name, track.language]
            .compactMap { $0?.lowercased() }
        for text in haystacks {
            for marker in markers where text.contains(marker) {
                return true
            }
        }
        return false
    }
}

// MARK: - Resolution (pure reads — never writes intent)

enum TrackIntentResolver {

    // MARK: Subtitles

    /// Resolve the stored subtitle intent against the tracks of the current title.
    ///
    /// Returns `nil` for off. A nil from no matching track must not rewrite the stored intent.
    ///
    /// Ladder for `.track(language:forced:hearingImpaired:codec:)`:
    ///   1. language + forced + hearingImpaired + codec
    ///   2. language + forced + hearingImpaired
    ///   3. language + forced
    ///   4. regular intent only: a forced track in the language (#425, files that
    ///      flag full subtitles forced). A forced intent never takes a full track.
    ///   5. off
    ///
    /// `.foreignAudio` asks for full subtitles when `audioLanguage` is known
    /// and differs, falling back to forced; otherwise forced only.
    static func resolveSubtitle(intent: SubtitleIntent, in tracks: [MediaTrack],
                                audioLanguage: String? = nil) -> MediaTrack? {
        switch intent {
        case .off:
            return nil

        case let .foreignAudio(language, hearingImpaired):
            if TrackLanguage.isForeign(audioLanguage, to: language),
               let full = resolveSubtitle(intent: .track(language: language, forced: false,
                                                         hearingImpaired: hearingImpaired, codec: nil), in: tracks) {
                return full
            }
            return resolveSubtitle(intent: .track(language: language, forced: true,
                                                  hearingImpaired: hearingImpaired, codec: nil), in: tracks)

        case let .track(language, forced, hearingImpaired, codec):
            // Every tier requires language AND the forced bit to agree.
            let base = tracks.filter {
                TrackLanguage.matches($0.languageCode ?? $0.language, language)
                    && $0.isForced == forced
            }
            guard !base.isEmpty else {
                guard !forced else { return nil }
                return resolveSubtitle(intent: .track(language: language, forced: true,
                                                      hearingImpaired: hearingImpaired, codec: codec), in: tracks)
            }

            // 1. + hearingImpaired + codec
            if let codec, !codec.isEmpty {
                if let exact = base.first(where: {
                    $0.isHearingImpaired == hearingImpaired
                        && TrackCodec.matches($0.codec, codec)
                }) {
                    return exact
                }
            }

            // 2. + hearingImpaired
            if let hiMatch = base.first(where: { $0.isHearingImpaired == hearingImpaired }) {
                return hiMatch
            }

            // 3. language + forced only
            return base.first
        }
    }

    /// Whether Plex's per-item `selected: true` subtitle stream may override
    /// the stored global intent.
    ///
    /// It normally wins, even over a global Off, but a regular stream never overrides a
    /// forced intent: Plex also sets `selected` from its own auto-select.
    static func plexSelectedSubtitleMayOverride(
        _ track: MediaTrack,
        intent: SubtitleIntent?
    ) -> Bool {
        guard case .track(_, let forced, _, _)? = intent else { return true }
        return track.isForced == forced
    }

    // MARK: Audio

    /// Resolve the stored audio intent against the tracks of the current title.
    ///
    /// Ladder (`TrackLanguage.original` takes the file's main track instead):
    ///   1. Exact: language + codec + channels (commentary allowed — the user
    ///      explicitly asked for this track shape).
    ///   2. Same language, best quality (commentary excluded).
    ///   3. English, best quality (commentary excluded).
    ///   4. File default, else first track (commentary excluded where possible).
    static func resolveAudio(intent: AudioIntent?, in tracks: [MediaTrack]) -> MediaTrack? {
        guard !tracks.isEmpty else { return nil }

        // Auto-selection tiers never pick commentary / audio description.
        let selectable = tracks.filter { !TrackCommentary.isCommentaryOrDescription($0) }

        // Original: the file's main track, at the best quality in its language.
        if intent?.language == TrackLanguage.original {
            guard let main = selectable.first(where: { $0.isDefault }) ?? selectable.first else {
                return tracks.first(where: { $0.isDefault }) ?? tracks.first
            }
            let sameLanguage = selectable.filter {
                TrackLanguage.matches($0.languageCode ?? $0.language, main.languageCode ?? main.language)
            }
            return bestByQuality(sameLanguage) ?? main
        }

        // 1. Exact match — honors an explicitly-picked commentary track.
        if let intent {
            if let exact = tracks.first(where: {
                TrackLanguage.matches($0.languageCode ?? $0.language, intent.language)
                    && TrackCodec.matches($0.codec, intent.codec)
                    && $0.channels == intent.channels
            }) {
                return exact
            }
        }

        // 2. Same language, best quality.
        if let intent, !TrackLanguage.normalize(intent.language).isEmpty {
            let sameLanguage = selectable.filter {
                TrackLanguage.matches($0.languageCode ?? $0.language, intent.language)
            }
            if let best = bestByQuality(sameLanguage) {
                return best
            }
        }

        // 3. English, best quality.
        let english = selectable.filter {
            TrackLanguage.normalize($0.languageCode ?? $0.language) == TrackLanguage.english
        }
        if let best = bestByQuality(english) {
            return best
        }

        // 4. File default, else first track.
        if let def = selectable.first(where: { $0.isDefault }) {
            return def
        }
        if let first = selectable.first {
            return first
        }
        // Every track is commentary-flagged (or a false positive). Take what's there.
        return tracks.first(where: { $0.isDefault }) ?? tracks.first
    }

    /// Rank by channel count desc, then codec tier desc, then original order.
    private static func bestByQuality(_ candidates: [MediaTrack]) -> MediaTrack? {
        guard !candidates.isEmpty else { return nil }
        return candidates.enumerated().max { lhs, rhs in
            let lc = lhs.element.channels ?? 0
            let rc = rhs.element.channels ?? 0
            if lc != rc { return lc < rc }
            let lt = TrackCodec.audioTier(lhs.element.codec)
            let rt = TrackCodec.audioTier(rhs.element.codec)
            if lt != rt { return lt < rt }
            // Stable: earlier index wins ties.
            return lhs.offset > rhs.offset
        }?.element
    }
}

// MARK: - Persistence

/// Last-write-wins track memory, per Plex Home profile. A profile that has
/// saved nothing reads the device-wide value (no profile, or from before #432).
enum TrackIntentStore {

    // Current keys
    private static let subtitleKey = "trackIntent.subtitle"
    private static let audioKey = "trackIntent.audio"
    private static let migratedKey = "trackIntent.migratedFromLegacy"

    // Legacy keys (the old SubtitlePreferenceManager / AudioPreferenceManager)
    private static let legacyAudioLanguageKey = "audioPreferenceLanguage"
    private static let legacyAudioJSONKey = "audioPreference"
    private static let legacyAudioMigratedKey = "audioPreferenceMigrated"

    private static let legacySubEnabledKey = "subtitlePreferenceEnabled"
    private static let legacySubLanguageKey = "subtitlePreferenceLanguage"
    private static let legacySubCodecKey = "subtitlePreferenceCodec"
    private static let legacySubHIKey = "subtitlePreferenceHearingImpaired"
    private static let legacySubJSONKey = "subtitlePreference"
    private static let legacySubMigratedKey = "subtitlePreferenceMigrated"

    // Defaults injectable for tests.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    // MARK: Profile scoping

    /// Keyed off `selectedPlexUserId`, as `HomeRowSettings` is.
    private static func profileKey(_ base: String) -> String {
        guard let userId = defaults.object(forKey: PlexProfileSession.savedUserIDKey) as? Int else { return base }
        return "\(base)_user_\(userId)"
    }

    /// The profile's value, else the device-wide one. Empty data is a profile's
    /// saved "nothing", so it never falls through.
    private static func storedData(_ base: String) -> Data? {
        migrateLegacyIfNeeded()
        return defaults.data(forKey: profileKey(base)) ?? defaults.data(forKey: base)
    }

    private static func store(_ value: (some Encodable)?, _ base: String) {
        migrateLegacyIfNeeded()
        let key = profileKey(base)
        if let value {
            if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
        } else if key == base {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(Data(), forKey: key)
        }
    }

    // MARK: Subtitle

    /// The stored subtitle intent, or `nil` if the user has never picked one.
    /// `.off` means the user explicitly turned subtitles off.
    static var subtitleIntent: SubtitleIntent? {
        get { storedData(subtitleKey).flatMap { try? JSONDecoder().decode(SubtitleIntent.self, from: $0) } }
        set { store(newValue, subtitleKey) }
    }

    /// Whether the user has ever explicitly expressed a subtitle intent.
    static var hasSubtitleIntent: Bool {
        storedData(subtitleKey)?.isEmpty == false
    }

    /// What playback resolves against: Foreign Audio in the device's
    /// language when nothing is stored.
    static var effectiveSubtitleIntent: SubtitleIntent {
        subtitleIntent ?? .foreignAudio(language: TrackLanguage.device, hearingImpaired: false)
    }

    // MARK: Audio

    static var audioIntent: AudioIntent? {
        get { storedData(audioKey).flatMap { try? JSONDecoder().decode(AudioIntent.self, from: $0) } }
        set { store(newValue, audioKey) }
    }

    /// The audio intent to resolve against, defaulting to English when the
    /// user has never picked anything (matching the old
    /// `AudioPreference.defaultEnglish` behavior).
    static var effectiveAudioIntent: AudioIntent {
        audioIntent ?? AudioIntent(language: TrackLanguage.english)
    }

    // MARK: Migration

    /// One-time migration off the legacy preference keys.
    ///
    /// Legacy subtitle data has NO forced bit — the old Settings picker could
    /// only express a language — so it migrates as `forced: false`. A user who
    /// set "Spanish" in Settings keeps Spanish.
    static func migrateLegacyIfNeeded() {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)

        migrateLegacyAudio()
        migrateLegacySubtitle()
        removeLegacyKeys()
    }

    private static func migrateLegacyAudio() {
        // The old manager itself migrated a JSON blob (`audioPreference`) into
        // `audioPreferenceLanguage`. That migration may or may not have run, so
        // read both: individual key first, then the blob.
        var language = defaults.string(forKey: legacyAudioLanguageKey)

        if language == nil,
           let data = defaults.data(forKey: legacyAudioJSONKey),
           let blob = try? JSONDecoder().decode(LegacyAudioBlob.self, from: data) {
            language = blob.languageCode
        }

        guard let language, !language.isEmpty else { return }
        // Language only — the old model stored no codec or channel count.
        if let data = try? JSONEncoder().encode(AudioIntent(language: language)) {
            defaults.set(data, forKey: audioKey)
        }
    }

    private static func migrateLegacySubtitle() {
        var enabled: Bool?
        var language: String?
        var codec: String?
        var hearingImpaired = false

        if defaults.object(forKey: legacySubEnabledKey) != nil
            || defaults.object(forKey: legacySubLanguageKey) != nil
            || defaults.object(forKey: legacySubCodecKey) != nil
            || defaults.object(forKey: legacySubHIKey) != nil {
            enabled = defaults.bool(forKey: legacySubEnabledKey)
            language = defaults.string(forKey: legacySubLanguageKey)
            codec = defaults.string(forKey: legacySubCodecKey)
            hearingImpaired = defaults.bool(forKey: legacySubHIKey)
        } else if let data = defaults.data(forKey: legacySubJSONKey),
                  let blob = try? JSONDecoder().decode(LegacySubtitleBlob.self, from: data) {
            enabled = blob.enabled
            language = blob.languageCode
            codec = blob.codec
            hearingImpaired = blob.preferHearingImpaired
        }

        guard let enabled else { return }

        let intent: SubtitleIntent
        if enabled, let language, !language.isEmpty {
            // Legacy data carries no forced bit; the old picker could only
            // express a language, so it was always a regular track.
            intent = .track(
                language: language,
                forced: false,
                hearingImpaired: hearingImpaired,
                codec: codec
            )
        } else {
            intent = .off
        }

        if let data = try? JSONEncoder().encode(intent) {
            defaults.set(data, forKey: subtitleKey)
        }
    }

    private static func removeLegacyKeys() {
        for key in [
            legacyAudioLanguageKey, legacyAudioJSONKey, legacyAudioMigratedKey,
            legacySubEnabledKey, legacySubLanguageKey, legacySubCodecKey,
            legacySubHIKey, legacySubJSONKey, legacySubMigratedKey
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    /// Test seam: wipe all current + legacy keys.
    static func resetAll() {
        for key in [
            subtitleKey, audioKey, migratedKey,
            legacyAudioLanguageKey, legacyAudioJSONKey, legacyAudioMigratedKey,
            legacySubEnabledKey, legacySubLanguageKey, legacySubCodecKey,
            legacySubHIKey, legacySubJSONKey, legacySubMigratedKey
        ] {
            defaults.removeObject(forKey: key)
        }
    }

    // Legacy JSON shapes, kept only so the one-time migration can decode them.
    private struct LegacyAudioBlob: Codable {
        var languageCode: String?
    }

    private struct LegacySubtitleBlob: Codable {
        var enabled: Bool
        var languageCode: String?
        var codec: String?
        var preferHearingImpaired: Bool
    }
}
