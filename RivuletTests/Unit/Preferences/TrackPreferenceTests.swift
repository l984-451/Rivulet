// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  TrackPreferenceTests.swift
//  RivuletTests
//
//  Unit tests for the global track-memory model (TrackIntent.swift):
//  SubtitleIntent / AudioIntent resolution, commentary exclusion, and the
//  one-time migration off the legacy preference keys.
//

import XCTest
@testable import Rivulet

final class TrackPreferenceTests: XCTestCase {

    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TrackIntentTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        TrackIntentStore.defaults = testDefaults
        TrackIntentStore.resetAll()
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        TrackIntentStore.defaults = .standard
        super.tearDown()
    }

    // MARK: - Helpers

    private func sub(
        _ id: Int,
        lang: String?,
        forced: Bool = false,
        hi: Bool = false,
        codec: String? = "srt",
        name: String? = nil
    ) -> MediaTrack {
        MediaTrack(
            id: id,
            name: name ?? "Subtitle \(id)",
            languageCode: lang,
            codec: codec,
            isForced: forced,
            isHearingImpaired: hi
        )
    }

    private func audio(
        _ id: Int,
        lang: String?,
        codec: String? = "ac3",
        channels: Int? = 2,
        isDefault: Bool = false,
        name: String = "Audio",
        extended: String? = nil
    ) -> MediaTrack {
        MediaTrack(
            id: id,
            name: name,
            languageCode: lang,
            codec: codec,
            isDefault: isDefault,
            extendedDisplayTitle: extended,
            channels: channels
        )
    }

    // MARK: - Subtitle resolution table

    /// Stored ENG forced + title has ENG forced → ENG forced.
    func testSubtitleForcedIntentMatchesForcedTrack() {
        let tracks = [
            sub(1, lang: "eng", forced: false),
            sub(2, lang: "eng", forced: true)
        ]
        let intent = SubtitleIntent.track(language: "eng", forced: true, hearingImpaired: false, codec: "srt")

        let result = TrackIntentResolver.resolveSubtitle(intent: intent, in: tracks)

        XCTAssertEqual(result?.id, 2)
        XCTAssertTrue(result?.isForced ?? false)
    }

    /// Stored ENG forced + title has ENG regular only → Off.
    /// AND the stored intent must survive untouched.
    func testSubtitleForcedIntentWithNoForcedTrackResolvesOffAndKeepsIntent() {
        TrackIntentStore.subtitleIntent = .track(
            language: "eng", forced: true, hearingImpaired: false, codec: "srt"
        )

        let tracks = [
            sub(1, lang: "eng", forced: false),
            sub(2, lang: "spa", forced: false)
        ]

        let intent = TrackIntentStore.subtitleIntent!
        let result = TrackIntentResolver.resolveSubtitle(intent: intent, in: tracks)

        // Applied: Off. Never promoted to the full English caption track.
        XCTAssertNil(result)

        // Stored intent is NOT overwritten — it re-engages on the next title
        // that ships a forced English track.
        XCTAssertEqual(
            TrackIntentStore.subtitleIntent,
            .track(language: "eng", forced: true, hearingImpaired: false, codec: "srt")
        )
    }

    /// Stored ENG regular + title has ENG regular → ENG regular.
    func testSubtitleRegularIntentMatchesRegularTrack() {
        let tracks = [
            sub(1, lang: "eng", forced: true),
            sub(2, lang: "eng", forced: false)
        ]
        let intent = SubtitleIntent.track(language: "eng", forced: false, hearingImpaired: false, codec: "srt")

        let result = TrackIntentResolver.resolveSubtitle(intent: intent, in: tracks)

        XCTAssertEqual(result?.id, 2)
        XCTAssertFalse(result?.isForced ?? true)
    }

    /// Stored ENG regular + title has ENG forced only → the forced track (#425), intent kept.
    func testSubtitleRegularIntentWithOnlyForcedTrackFallsBackToForced() {
        TrackIntentStore.subtitleIntent = .track(
            language: "eng", forced: false, hearingImpaired: false, codec: "srt"
        )

        let tracks = [sub(1, lang: "eng", forced: true), sub(2, lang: "fra", forced: false)]

        let result = TrackIntentResolver.resolveSubtitle(
            intent: TrackIntentStore.subtitleIntent!, in: tracks
        )

        XCTAssertEqual(result?.id, 1)
        XCTAssertEqual(
            TrackIntentStore.subtitleIntent,
            .track(language: "eng", forced: false, hearingImpaired: false, codec: "srt")
        )
    }

    /// Off + anything → Off.
    func testSubtitleOffIntentAlwaysResolvesOff() {
        let tracks = [
            sub(1, lang: "eng", forced: false),
            sub(2, lang: "eng", forced: true)
        ]

        XCTAssertNil(TrackIntentResolver.resolveSubtitle(intent: .off, in: tracks))
    }

    /// Language mismatch → Off, not "first available".
    func testSubtitleIntentWithNoLanguageMatchResolvesOff() {
        let tracks = [
            sub(1, lang: "fra"),
            sub(2, lang: "deu")
        ]
        let intent = SubtitleIntent.track(language: "eng", forced: false, hearingImpaired: false, codec: "srt")

        XCTAssertNil(TrackIntentResolver.resolveSubtitle(intent: intent, in: tracks))
    }

    // MARK: - Subtitle match ladder

    func testSubtitleExactMatchLanguageForcedHICodec() {
        let tracks = [
            sub(1, lang: "eng", forced: true, hi: false, codec: "srt"),
            sub(2, lang: "eng", forced: true, hi: true, codec: "srt"),
            sub(3, lang: "eng", forced: true, hi: true, codec: "pgs")
        ]
        let intent = SubtitleIntent.track(language: "eng", forced: true, hearingImpaired: true, codec: "pgs")

        XCTAssertEqual(TrackIntentResolver.resolveSubtitle(intent: intent, in: tracks)?.id, 3)
    }

    func testSubtitleFallsBackToLanguageForcedHIWhenCodecAbsent() {
        let tracks = [
            sub(1, lang: "eng", forced: true, hi: false, codec: "srt"),
            sub(2, lang: "eng", forced: true, hi: true, codec: "srt")
        ]
        // Wants ASS, which doesn't exist. Falls to language + forced + HI.
        let intent = SubtitleIntent.track(language: "eng", forced: true, hearingImpaired: true, codec: "ass")

        XCTAssertEqual(TrackIntentResolver.resolveSubtitle(intent: intent, in: tracks)?.id, 2)
    }

    func testSubtitleFallsBackToLanguageForcedOnly() {
        let tracks = [
            sub(1, lang: "eng", forced: true, hi: false, codec: "srt")
        ]
        // Wants HI + ASS; neither exists. Language + forced still matches.
        let intent = SubtitleIntent.track(language: "eng", forced: true, hearingImpaired: true, codec: "ass")

        XCTAssertEqual(TrackIntentResolver.resolveSubtitle(intent: intent, in: tracks)?.id, 1)
    }

    /// Language codes are inconsistent across sources ("en" vs "eng").
    func testSubtitleLanguageNormalization() {
        let tracks = [sub(1, lang: "en", forced: true)]
        let intent = SubtitleIntent.track(language: "eng", forced: true, hearingImpaired: false, codec: nil)

        XCTAssertEqual(TrackIntentResolver.resolveSubtitle(intent: intent, in: tracks)?.id, 1)
    }

    /// Plex says "subrip", FFmpeg says "srt" — same codec.
    func testSubtitleCodecNormalization() {
        let tracks = [sub(1, lang: "eng", forced: false, hi: false, codec: "subrip")]
        let intent = SubtitleIntent.track(language: "eng", forced: false, hearingImpaired: false, codec: "srt")

        XCTAssertEqual(TrackIntentResolver.resolveSubtitle(intent: intent, in: tracks)?.id, 1)
    }

    /// The original bug: SubtitleIntent(from:) must carry the forced bit.
    func testSubtitleIntentFromTrackCarriesForcedBit() {
        let track = sub(7, lang: "eng", forced: true, hi: false, codec: "srt")

        XCTAssertEqual(
            SubtitleIntent(from: track),
            .track(language: "eng", forced: true, hearingImpaired: false, codec: "srt")
        )
    }

    // MARK: - Plex per-item selected stream vs stored intent

    /// The build-66 regression: an item whose Plex metadata carries a
    /// `selected: true` regular English stream must NOT override a stored
    /// ENG-forced intent. Forced and regular subs are different products;
    /// the forced boundary holds against the per-item tier too.
    func testPlexSelectedRegularStreamCannotOverrideForcedIntent() {
        let selected = sub(1, lang: "eng", forced: false)
        let intent = SubtitleIntent.track(
            language: "eng", forced: true, hearingImpaired: false, codec: "srt"
        )

        XCTAssertFalse(
            TrackIntentResolver.plexSelectedSubtitleMayOverride(selected, intent: intent)
        )
    }

    /// A regular selected stream may override a regular stored intent —
    /// the per-item pick is more specific than the global memory.
    func testPlexSelectedRegularStreamMayOverrideRegularIntent() {
        let selected = sub(1, lang: "spa", forced: false)
        let intent = SubtitleIntent.track(
            language: "eng", forced: false, hearingImpaired: false, codec: "srt"
        )

        XCTAssertTrue(
            TrackIntentResolver.plexSelectedSubtitleMayOverride(selected, intent: intent)
        )
    }

    /// Explicit global Off still yields to a deliberate per-item pick
    /// (the pre-play picker's server-side persistence contract).
    func testPlexSelectedStreamMayOverrideExplicitOff() {
        let selected = sub(1, lang: "eng", forced: false)

        XCTAssertTrue(
            TrackIntentResolver.plexSelectedSubtitleMayOverride(selected, intent: .off)
        )
    }

    /// No stored intent at all: the per-item selection stands.
    func testPlexSelectedStreamMayOverrideNilIntent() {
        let selected = sub(1, lang: "eng", forced: false)

        XCTAssertTrue(
            TrackIntentResolver.plexSelectedSubtitleMayOverride(selected, intent: nil)
        )
    }

    // MARK: - Audio resolution

    func testAudioReturnsNilForEmptyTracks() {
        XCTAssertNil(TrackIntentResolver.resolveAudio(
            intent: AudioIntent(language: "eng"), in: []
        ))
    }

    /// Tier 1: exact language + codec + channels wins over a "better" track.
    func testAudioExactMatchWins() {
        let tracks = [
            audio(1, lang: "eng", codec: "truehd", channels: 8),
            audio(2, lang: "eng", codec: "ac3", channels: 2)
        ]
        let intent = AudioIntent(language: "eng", codec: "ac3", channels: 2)

        XCTAssertEqual(TrackIntentResolver.resolveAudio(intent: intent, in: tracks)?.id, 2)
    }

    /// Tier 2: same language, best quality (channels desc, then codec tier).
    func testAudioSameLanguageBestQuality() {
        let tracks = [
            audio(1, lang: "spa", codec: "aac", channels: 2),
            audio(2, lang: "spa", codec: "ac3", channels: 6),
            audio(3, lang: "spa", codec: "truehd", channels: 8),
            audio(4, lang: "eng", codec: "truehd", channels: 8)
        ]
        // Exact (dts/6) doesn't exist → same-language best quality.
        let intent = AudioIntent(language: "spa", codec: "dts", channels: 6)

        XCTAssertEqual(TrackIntentResolver.resolveAudio(intent: intent, in: tracks)?.id, 3)
    }

    /// Codec tier breaks channel ties: TrueHD 5.1 beats AAC 5.1.
    func testAudioCodecTierBreaksChannelTie() {
        let tracks = [
            audio(1, lang: "eng", codec: "aac", channels: 6),
            audio(2, lang: "eng", codec: "truehd", channels: 6),
            audio(3, lang: "eng", codec: "ac3", channels: 6)
        ]
        let intent = AudioIntent(language: "eng", codec: nil, channels: nil)

        XCTAssertEqual(TrackIntentResolver.resolveAudio(intent: intent, in: tracks)?.id, 2)
    }

    /// Tier 3: preferred language absent → best English.
    func testAudioFallsBackToEnglish() {
        let tracks = [
            audio(1, lang: "eng", codec: "ac3", channels: 2),
            audio(2, lang: "eng", codec: "truehd", channels: 8),
            audio(3, lang: "fra", codec: "truehd", channels: 8)
        ]
        let intent = AudioIntent(language: "jpn")

        XCTAssertEqual(TrackIntentResolver.resolveAudio(intent: intent, in: tracks)?.id, 2)
    }

    func testAudioEnglishFallbackAcceptsVariousLanguageCodes() {
        let intent = AudioIntent(language: "jpn")

        XCTAssertEqual(
            TrackIntentResolver.resolveAudio(
                intent: intent, in: [audio(1, lang: "en", channels: 6)]
            )?.id, 1
        )
        XCTAssertEqual(
            TrackIntentResolver.resolveAudio(
                intent: intent, in: [audio(1, lang: "English", channels: 6)]
            )?.id, 1
        )
    }

    /// Tier 4: no preferred language, no English → file default.
    func testAudioFallsBackToFileDefault() {
        let tracks = [
            audio(1, lang: "fra", channels: 6),
            audio(2, lang: "deu", channels: 6, isDefault: true)
        ]
        let intent = AudioIntent(language: "jpn")

        let result = TrackIntentResolver.resolveAudio(intent: intent, in: tracks)
        XCTAssertEqual(result?.id, 2)
        XCTAssertTrue(result?.isDefault ?? false)
    }

    /// Tier 4b: no default either → first track.
    func testAudioFallsBackToFirstTrack() {
        let tracks = [
            audio(1, lang: "fra", channels: 6),
            audio(2, lang: "deu", channels: 6)
        ]
        let intent = AudioIntent(language: "jpn")

        XCTAssertEqual(TrackIntentResolver.resolveAudio(intent: intent, in: tracks)?.id, 1)
    }

    func testAudioIntentFromTrackCapturesCodecAndChannels() {
        let track = audio(9, lang: "jpn", codec: "eac3", channels: 6)

        XCTAssertEqual(
            AudioIntent(from: track),
            AudioIntent(language: "jpn", codec: "eac3", channels: 6)
        )
    }

    // MARK: - Commentary exclusion

    /// The real latent bug: max-by-channels would pick a 5.1 commentary track
    /// over the 5.1 main mix.
    func testCommentaryNeverAutoSelectedOverMainMix() {
        let tracks = [
            audio(1, lang: "eng", codec: "ac3", channels: 6, name: "English"),
            audio(2, lang: "eng", codec: "ac3", channels: 6,
                  name: "Commentary", extended: "English (AC3 5.1) - Director's Commentary")
        ]
        // No stored intent shape matches exactly → auto tiers.
        let intent = AudioIntent(language: "eng")

        let result = TrackIntentResolver.resolveAudio(intent: intent, in: tracks)

        XCTAssertEqual(result?.id, 1)
    }

    /// Even a *higher quality* commentary track is not auto-selected.
    func testHigherQualityCommentaryStillNotAutoSelected() {
        let tracks = [
            audio(1, lang: "eng", codec: "ac3", channels: 6, name: "Main"),
            audio(2, lang: "eng", codec: "truehd", channels: 8,
                  name: "Commentary", extended: "English TrueHD 7.1 Audio Commentary")
        ]

        XCTAssertEqual(
            TrackIntentResolver.resolveAudio(intent: AudioIntent(language: "eng"), in: tracks)?.id,
            1
        )
    }

    func testAudioDescriptionNotAutoSelected() {
        let tracks = [
            audio(1, lang: "eng", codec: "ac3", channels: 2,
                  name: "AD", extended: "English - Audio Description"),
            audio(2, lang: "eng", codec: "ac3", channels: 2, name: "English")
        ]

        XCTAssertEqual(
            TrackIntentResolver.resolveAudio(intent: AudioIntent(language: "eng"), in: tracks)?.id,
            2
        )
    }

    func testCommentaryExcludedFromEnglishFallbackTier() {
        let tracks = [
            audio(1, lang: "eng", codec: "truehd", channels: 8,
                  name: "Commentary", extended: "Director's Commentary"),
            audio(2, lang: "eng", codec: "ac3", channels: 2, name: "English")
        ]

        XCTAssertEqual(
            TrackIntentResolver.resolveAudio(intent: AudioIntent(language: "jpn"), in: tracks)?.id,
            2
        )
    }

    func testCommentaryExcludedFromFileDefaultTier() {
        let tracks = [
            audio(1, lang: "fra", codec: "ac3", channels: 6, isDefault: true,
                  name: "Commentary", extended: "French Commentary"),
            audio(2, lang: "deu", codec: "ac3", channels: 6, name: "German")
        ]

        XCTAssertEqual(
            TrackIntentResolver.resolveAudio(intent: AudioIntent(language: "jpn"), in: tracks)?.id,
            2
        )
    }

    /// An explicitly-picked commentary track IS restored — tier 1 exact match.
    func testExplicitlyPickedCommentaryIsRestored() {
        let tracks = [
            audio(1, lang: "eng", codec: "ac3", channels: 6, name: "English"),
            audio(2, lang: "eng", codec: "eac3", channels: 2,
                  name: "Commentary", extended: "English (EAC3 Stereo) - Director's Commentary")
        ]
        let intent = AudioIntent(from: tracks[1])

        XCTAssertEqual(TrackIntentResolver.resolveAudio(intent: intent, in: tracks)?.id, 2)
    }

    /// If literally every track looks like commentary, still return something.
    func testAllCommentaryTracksStillReturnsATrack() {
        let tracks = [
            audio(1, lang: "eng", channels: 2, name: "Commentary A"),
            audio(2, lang: "eng", channels: 2, isDefault: true, name: "Commentary B")
        ]

        XCTAssertEqual(
            TrackIntentResolver.resolveAudio(intent: AudioIntent(language: "spa"), in: tracks)?.id,
            2
        )
    }

    func testCommentaryDetectionKeywords() {
        for title in [
            "Director's Commentary",
            "Audio Commentary",
            "English - Audio Description",
            "Descriptive Audio",
            "Described Video",
            "Narration Track"
        ] {
            let track = audio(1, lang: "eng", extended: title)
            XCTAssertTrue(
                TrackCommentary.isCommentaryOrDescription(track),
                "Expected '\(title)' to be detected as commentary/description"
            )
        }

        XCTAssertFalse(
            TrackCommentary.isCommentaryOrDescription(
                audio(1, lang: "eng", extended: "English (TrueHD 7.1)")
            )
        )
    }

    // MARK: - Persistence

    func testNoStoredIntentByDefault() {
        XCTAssertNil(TrackIntentStore.subtitleIntent)
        XCTAssertFalse(TrackIntentStore.hasSubtitleIntent)
        XCTAssertNil(TrackIntentStore.audioIntent)
        XCTAssertEqual(TrackIntentStore.effectiveAudioIntent, AudioIntent(language: "eng"))
    }

    func testSubtitleIntentRoundTrips() {
        let intent = SubtitleIntent.track(language: "spa", forced: true, hearingImpaired: true, codec: "pgs")
        TrackIntentStore.subtitleIntent = intent

        XCTAssertEqual(TrackIntentStore.subtitleIntent, intent)
        XCTAssertTrue(TrackIntentStore.hasSubtitleIntent)
    }

    func testExplicitOffIsDistinctFromNoIntent() {
        TrackIntentStore.subtitleIntent = .off

        XCTAssertEqual(TrackIntentStore.subtitleIntent, .off)
        XCTAssertTrue(TrackIntentStore.hasSubtitleIntent)
    }

    func testAudioIntentRoundTrips() {
        let intent = AudioIntent(language: "jpn", codec: "flac", channels: 2)
        TrackIntentStore.audioIntent = intent

        XCTAssertEqual(TrackIntentStore.audioIntent, intent)
    }

    // MARK: - Per profile

    private func selectProfile(_ id: Int?) {
        if let id {
            testDefaults.set(id, forKey: PlexProfileSession.savedUserIDKey)
        } else {
            testDefaults.removeObject(forKey: PlexProfileSession.savedUserIDKey)
        }
    }

    /// Each Plex Home profile keeps its own choice (#432).
    func testProfilesKeepSeparateIntents() {
        selectProfile(1)
        TrackIntentStore.subtitleIntent = .off
        selectProfile(2)
        let always = SubtitleIntent.track(language: "eng", forced: false, hearingImpaired: false, codec: nil)
        TrackIntentStore.subtitleIntent = always

        XCTAssertEqual(TrackIntentStore.subtitleIntent, always)
        selectProfile(1)
        XCTAssertEqual(TrackIntentStore.subtitleIntent, .off)
    }

    /// A profile that has saved nothing reads the device-wide value, which its picks never change.
    func testProfileInheritsDeviceIntentUntilItPicks() {
        let foreign = SubtitleIntent.foreignAudio(language: "eng", hearingImpaired: false)
        TrackIntentStore.subtitleIntent = foreign
        selectProfile(1)
        XCTAssertEqual(TrackIntentStore.subtitleIntent, foreign)

        TrackIntentStore.subtitleIntent = .off
        selectProfile(nil)
        XCTAssertEqual(TrackIntentStore.subtitleIntent, foreign)
    }

    /// A profile's "follow the account" audio (nil) does not fall back to the device's language.
    func testProfileNilAudioDoesNotInheritDevice() {
        TrackIntentStore.audioIntent = AudioIntent(language: "jpn")
        selectProfile(1)
        TrackIntentStore.audioIntent = nil

        XCTAssertNil(TrackIntentStore.audioIntent)
        selectProfile(nil)
        XCTAssertEqual(TrackIntentStore.audioIntent, AudioIntent(language: "jpn"))
    }

    // MARK: - Migration

    func testMigratesLegacyAudioLanguageKey() {
        testDefaults.set("spa", forKey: "audioPreferenceLanguage")

        XCTAssertEqual(TrackIntentStore.audioIntent, AudioIntent(language: "spa"))
        // Legacy key removed.
        XCTAssertNil(testDefaults.string(forKey: "audioPreferenceLanguage"))
    }

    func testMigratesLegacyAudioJSONBlob() {
        let blob = ["languageCode": "fra"]
        testDefaults.set(try! JSONEncoder().encode(blob), forKey: "audioPreference")

        XCTAssertEqual(TrackIntentStore.audioIntent, AudioIntent(language: "fra"))
        XCTAssertNil(testDefaults.data(forKey: "audioPreference"))
    }

    func testMigratesLegacySubtitleIndividualKeys() {
        testDefaults.set(true, forKey: "subtitlePreferenceEnabled")
        testDefaults.set("spa", forKey: "subtitlePreferenceLanguage")
        testDefaults.set("srt", forKey: "subtitlePreferenceCodec")
        testDefaults.set(false, forKey: "subtitlePreferenceHearingImpaired")

        // Old data has no forced bit — migrates as forced: false.
        XCTAssertEqual(
            TrackIntentStore.subtitleIntent,
            .track(language: "spa", forced: false, hearingImpaired: false, codec: "srt")
        )
        XCTAssertNil(testDefaults.object(forKey: "subtitlePreferenceEnabled"))
        XCTAssertNil(testDefaults.string(forKey: "subtitlePreferenceLanguage"))
    }

    func testMigratesLegacySubtitleDisabledAsOff() {
        testDefaults.set(false, forKey: "subtitlePreferenceEnabled")
        testDefaults.set("eng", forKey: "subtitlePreferenceLanguage")

        XCTAssertEqual(TrackIntentStore.subtitleIntent, .off)
    }

    func testMigratesLegacySubtitleJSONBlob() {
        struct LegacyBlob: Encodable {
            let enabled: Bool
            let languageCode: String?
            let codec: String?
            let preferHearingImpaired: Bool
        }
        let blob = LegacyBlob(enabled: true, languageCode: "deu", codec: "ass", preferHearingImpaired: true)
        testDefaults.set(try! JSONEncoder().encode(blob), forKey: "subtitlePreference")

        XCTAssertEqual(
            TrackIntentStore.subtitleIntent,
            .track(language: "deu", forced: false, hearingImpaired: true, codec: "ass")
        )
        XCTAssertNil(testDefaults.data(forKey: "subtitlePreference"))
    }

    func testMigrationRunsOnlyOnce() {
        testDefaults.set("spa", forKey: "audioPreferenceLanguage")
        XCTAssertEqual(TrackIntentStore.audioIntent, AudioIntent(language: "spa"))

        // User then picks Japanese in the player.
        TrackIntentStore.audioIntent = AudioIntent(language: "jpn", codec: "flac", channels: 2)

        // A resurrected legacy key must not clobber the new intent.
        testDefaults.set("fra", forKey: "audioPreferenceLanguage")

        XCTAssertEqual(
            TrackIntentStore.audioIntent,
            AudioIntent(language: "jpn", codec: "flac", channels: 2)
        )
    }

    func testMigrationWithNoLegacyDataLeavesNoIntent() {
        TrackIntentStore.migrateLegacyIfNeeded()

        XCTAssertNil(TrackIntentStore.subtitleIntent)
        XCTAssertNil(TrackIntentStore.audioIntent)
    }

    // MARK: - Foreign Audio

    private var englishFilmSubs: [MediaTrack] {
        [sub(1, lang: "eng"), sub(2, lang: "eng", forced: true), sub(3, lang: "spa")]
    }

    func testForeignAudioShowsFullSubtitlesOverForeignAudio() {
        let intent = SubtitleIntent.foreignAudio(language: "eng", hearingImpaired: false)
        XCTAssertEqual(TrackIntentResolver.resolveSubtitle(intent: intent, in: englishFilmSubs, audioLanguage: "jpn")?.id, 1)
    }

    func testForeignAudioShowsOnlyForcedOverNativeAudio() {
        let intent = SubtitleIntent.foreignAudio(language: "eng", hearingImpaired: false)
        XCTAssertEqual(TrackIntentResolver.resolveSubtitle(intent: intent, in: englishFilmSubs, audioLanguage: "en")?.id, 2)
        XCTAssertNil(TrackIntentResolver.resolveSubtitle(intent: intent, in: [sub(1, lang: "eng")], audioLanguage: "eng"))
    }

    func testForeignAudioTreatsUntaggedAudioAsNative() {
        let intent = SubtitleIntent.foreignAudio(language: "eng", hearingImpaired: false)
        XCTAssertNil(TrackIntentResolver.resolveSubtitle(intent: intent, in: [sub(1, lang: "eng")], audioLanguage: "und"))
        XCTAssertNil(TrackIntentResolver.resolveSubtitle(intent: intent, in: [sub(1, lang: "eng")], audioLanguage: nil))
    }

    func testNothingStoredMeansForeignAudio() {
        guard case .foreignAudio = TrackIntentStore.effectiveSubtitleIntent else {
            return XCTFail("default should be Foreign Audio")
        }
    }

    func testPickKeepsForeignAudioWhenItFitsTheMode() {
        let current = SubtitleIntent.foreignAudio(language: "eng", hearingImpaired: false)
        XCTAssertEqual(SubtitleIntent.afterPick(sub(1, lang: "eng", hi: true), replacing: current, audioLanguage: "jpn"),
                       .foreignAudio(language: "eng", hearingImpaired: true))
        XCTAssertEqual(SubtitleIntent.afterPick(sub(2, lang: "eng", forced: true), replacing: current, audioLanguage: "eng"),
                       .foreignAudio(language: "eng", hearingImpaired: false))
    }

    func testPickOfFullSubtitlesOverNativeAudioMeansAlways() {
        let current = SubtitleIntent.foreignAudio(language: "eng", hearingImpaired: false)
        XCTAssertEqual(SubtitleIntent.afterPick(sub(1, lang: "eng"), replacing: current, audioLanguage: "eng"),
                       .track(language: "eng", forced: false, hearingImpaired: false, codec: "srt"))
    }

    /// Off under Foreign Audio covers the title, not the mode (#432).
    func testOffPickKeepsForeignAudio() {
        let current = SubtitleIntent.foreignAudio(language: "eng", hearingImpaired: false)
        XCTAssertEqual(SubtitleIntent.afterPick(nil, replacing: current, audioLanguage: "jpn"), current)
        let always = SubtitleIntent.track(language: "eng", forced: false, hearingImpaired: false, codec: nil)
        XCTAssertEqual(SubtitleIntent.afterPick(nil, replacing: always, audioLanguage: "jpn"), .off)
    }

    /// A forced pick turns subtitles on in its language; it never switches Always to Forced Only (#425).
    func testForcedPickNeverStoresForcedUnlessAlreadyForcedOnly() {
        let forcedTrack = sub(1, lang: "eng", forced: true)
        let always = SubtitleIntent.track(language: "eng", forced: false, hearingImpaired: false, codec: nil)
        XCTAssertEqual(SubtitleIntent.afterPick(forcedTrack, replacing: always, audioLanguage: "jpn"),
                       .track(language: "eng", forced: false, hearingImpaired: false, codec: "srt"))
        XCTAssertEqual(SubtitleIntent.afterPick(forcedTrack, replacing: .off, audioLanguage: "eng"),
                       .track(language: "eng", forced: false, hearingImpaired: false, codec: "srt"))
        let forcedOnly = SubtitleIntent.track(language: "eng", forced: true, hearingImpaired: false, codec: nil)
        XCTAssertEqual(SubtitleIntent.afterPick(forcedTrack, replacing: forcedOnly, audioLanguage: "eng"),
                       .track(language: "eng", forced: true, hearingImpaired: false, codec: "srt"))
    }

    func testOldStoredIntentsStillDecode() throws {
        let data = try JSONEncoder().encode(SubtitleIntent.track(language: "eng", forced: true, hearingImpaired: false, codec: nil))
        XCTAssertEqual(try JSONDecoder().decode(SubtitleIntent.self, from: data),
                       .track(language: "eng", forced: true, hearingImpaired: false, codec: nil))
    }

    // MARK: - Original audio

    func testOriginalPicksTheMainTrackAtBestQuality() {
        let tracks = [
            audio(1, lang: "eng", codec: "eac3", channels: 6),
            audio(2, lang: "jpn", codec: "aac", channels: 2, isDefault: true),
            audio(3, lang: "jpn", codec: "truehd", channels: 6),
            audio(4, lang: "jpn", channels: 6, name: "Commentary")
        ]
        XCTAssertEqual(TrackIntentResolver.resolveAudio(intent: AudioIntent(language: TrackLanguage.original), in: tracks)?.id, 3)
    }

    func testOriginalWithNoDefaultTakesTheFirstTrack() {
        let tracks = [audio(1, lang: "fra"), audio(2, lang: "eng")]
        XCTAssertEqual(TrackIntentResolver.resolveAudio(intent: AudioIntent(language: TrackLanguage.original), in: tracks)?.id, 1)
    }

    // MARK: - Starting selection

    private func streams(_ json: String) -> [PlexStream] {
        try! JSONDecoder().decode([PlexStream].self, from: Data(json.utf8))
    }

    /// Plex's per-item audio pick wins over the intent; the stored intent then picks subtitles.
    func testStartingSelectionHonorsPerItemAudioPick() {
        TrackIntentStore.audioIntent = AudioIntent(language: "eng")
        TrackIntentStore.subtitleIntent = .track(language: "eng", forced: false, hearingImpaired: false, codec: nil)
        let start = TrackIntentResolver.startingPlexSelection(streams: streams(#"""
            [{"id":1,"streamType":2,"index":1,"languageCode":"eng","codec":"eac3","default":true},
             {"id":2,"streamType":2,"index":2,"languageCode":"jpn","codec":"aac","selected":true},
             {"id":3,"streamType":3,"index":3,"languageCode":"eng","codec":"srt"}]
            """#))
        XCTAssertEqual(start.audio, 2)
        XCTAssertEqual(start.subtitle, 3)
    }

    /// A deliberate Plex subtitle pick overrides a stored Off; nothing selected resolves to off (0).
    func testStartingSelectionSubtitleOverrideAndOff() {
        TrackIntentStore.subtitleIntent = .off
        let picked = TrackIntentResolver.startingPlexSelection(streams: streams(#"""
            [{"id":1,"streamType":2,"index":1,"languageCode":"eng","default":true,"selected":true},
             {"id":3,"streamType":3,"index":3,"languageCode":"spa","selected":true}]
            """#))
        XCTAssertEqual(picked.subtitle, 3)
        let off = TrackIntentResolver.startingPlexSelection(streams: streams(#"""
            [{"id":1,"streamType":2,"index":1,"languageCode":"eng","default":true,"selected":true},
             {"id":3,"streamType":3,"index":3,"languageCode":"spa"}]
            """#))
        XCTAssertEqual(off.subtitle, 0)
    }
}
