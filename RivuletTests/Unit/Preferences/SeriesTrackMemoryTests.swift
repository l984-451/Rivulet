// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class SeriesTrackMemoryTests: XCTestCase {
    private var suiteName: String!
    private var testDefaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SeriesTrackMemoryTests.\(UUID().uuidString)"
        testDefaults = UserDefaults(suiteName: suiteName)!
        SeriesTrackMemory.defaults = testDefaults
        TrackIntentStore.defaults = testDefaults
    }

    override func tearDown() {
        testDefaults.removePersistentDomain(forName: suiteName)
        SeriesTrackMemory.defaults = .standard
        TrackIntentStore.defaults = .standard
        super.tearDown()
    }

    private func audio(_ id: Int, lang: String, isDefault: Bool = false) -> MediaTrack {
        MediaTrack(id: id, name: "Audio", languageCode: lang, codec: "ac3", isDefault: isDefault, channels: 6)
    }

    private func sub(_ id: Int, lang: String, forced: Bool = false) -> MediaTrack {
        MediaTrack(id: id, name: "Subtitle \(id)", languageCode: lang, codec: "srt", isForced: forced)
    }

    private func streams(_ json: String) -> [PlexStream] {
        try! JSONDecoder().decode([PlexStream].self, from: Data(json.utf8))
    }

    // MARK: - Key

    func test_key_prefersTheShowGuid_elseTheShowOnItsServer() {
        XCTAssertEqual(SeriesTrackMemory.key(showGUID: "plex://show/5d9c", showID: "42", server: "https://a"),
                       "plex://show/5d9c")
        XCTAssertEqual(SeriesTrackMemory.key(showGUID: nil, showID: "42", server: "https://a"), "https://a/42")
        XCTAssertEqual(SeriesTrackMemory.key(showGUID: "", showID: "42", server: "https://a"), "https://a/42")
        XCTAssertNil(SeriesTrackMemory.key(showGUID: nil, showID: nil, server: "https://a"))
    }

    // MARK: - Storage

    func test_remember_keepsAudioAndSubtitlesPerSeries() {
        SeriesTrackMemory.remember(audio: AudioIntent(language: "jpn"), for: "show/a")
        SeriesTrackMemory.remember(subtitle: .track(language: "spa", forced: false, hearingImpaired: false, codec: nil),
                                   for: "show/a")
        SeriesTrackMemory.remember(audio: AudioIntent(language: "eng"), for: "show/b")

        XCTAssertEqual(SeriesTrackMemory.entry(for: "show/a")?.audio?.language, "jpn")
        XCTAssertEqual(SeriesTrackMemory.entry(for: "show/a")?.subtitle?.language, "spa")
        XCTAssertEqual(SeriesTrackMemory.entry(for: "show/b")?.audio?.language, "eng")
        XCTAssertNil(SeriesTrackMemory.entry(for: "show/b")?.subtitle)
        XCTAssertNil(SeriesTrackMemory.entry(for: "show/c"))
    }

    func test_remember_subtitlesOff() {
        SeriesTrackMemory.remember(subtitle: .off, for: "show/a")
        XCTAssertEqual(SeriesTrackMemory.entry(for: "show/a")?.subtitle, .off)
    }

    func test_remember_isPerProfile() {
        testDefaults.set(1, forKey: PlexProfileSession.savedUserIDKey)
        SeriesTrackMemory.remember(audio: AudioIntent(language: "jpn"), for: "show/a")
        testDefaults.set(2, forKey: PlexProfileSession.savedUserIDKey)
        XCTAssertNil(SeriesTrackMemory.entry(for: "show/a"))
    }

    func test_remember_dropsTheLeastRecentlyPickedSeriesPastTheLimit() {
        let start = Date(timeIntervalSince1970: 0)
        for index in 0...SeriesTrackMemory.limit {
            SeriesTrackMemory.remember(audio: AudioIntent(language: "eng"), for: "show/\(index)",
                                       now: start.addingTimeInterval(TimeInterval(index)))
        }
        XCTAssertNil(SeriesTrackMemory.entry(for: "show/0"))
        XCTAssertNotNil(SeriesTrackMemory.entry(for: "show/1"))
        XCTAssertNotNil(SeriesTrackMemory.entry(for: "show/\(SeriesTrackMemory.limit)"))
    }

    // MARK: - Starting picks

    func test_startingPicks_resolveTheSeriesLanguagesOnTheEpisodesTracks() {
        let entry = SeriesTrackMemory.Entry(
            audio: AudioIntent(language: "jpn"),
            subtitle: .track(language: "spa", forced: false, hearingImpaired: false, codec: nil),
            updated: Date())
        let picks = SeriesTrackMemory.startingPicks(
            entry,
            audio: [audio(1, lang: "spa", isDefault: true), audio(2, lang: "jpn")],
            subtitles: [sub(10, lang: "eng"), sub(11, lang: "spa")])
        XCTAssertEqual(picks, TrackPicks(audio: 2, subtitle: .track(11)))
    }

    func test_startingPicks_subtitlesOff() {
        let entry = SeriesTrackMemory.Entry(subtitle: .off, updated: Date())
        let picks = SeriesTrackMemory.startingPicks(entry, audio: [audio(1, lang: "eng")],
                                                    subtitles: [sub(10, lang: "eng")])
        XCTAssertEqual(picks, TrackPicks(audio: nil, subtitle: .off))
    }

    /// An episode without the series' subtitle language leaves the choice to the usual order.
    func test_startingPicks_noMatchingSubtitle_decidesNothing() {
        let entry = SeriesTrackMemory.Entry(
            subtitle: .track(language: "spa", forced: false, hearingImpaired: false, codec: nil), updated: Date())
        let picks = SeriesTrackMemory.startingPicks(entry, audio: [audio(1, lang: "eng")],
                                                    subtitles: [sub(10, lang: "fra")])
        XCTAssertNil(picks.subtitle)
        XCTAssertNil(picks.audio)
    }

    /// `resolveAudio` falls back to English; an episode without the series' audio language decides nothing.
    func test_startingPicks_noMatchingAudio_decidesNothing() {
        let entry = SeriesTrackMemory.Entry(audio: AudioIntent(language: "jpn"), updated: Date())
        let picks = SeriesTrackMemory.startingPicks(
            entry, audio: [audio(1, lang: "spa", isDefault: true), audio(2, lang: "eng")], subtitles: [])
        XCTAssertNil(picks.audio)
        // An unlabeled pick names no language to carry.
        let unlabeled = SeriesTrackMemory.Entry(audio: AudioIntent(language: ""), updated: Date())
        XCTAssertNil(SeriesTrackMemory.startingPicks(unlabeled, audio: [audio(1, lang: "eng")], subtitles: []).audio)
    }

    /// A Foreign Audio pick follows each episode's audio: full subtitles over foreign audio, forced ones otherwise.
    func test_startingPicks_foreignAudio_judgesThePlayingAudio() {
        let entry = SeriesTrackMemory.Entry(subtitle: .foreignAudio(language: "eng", hearingImpaired: false),
                                            updated: Date())
        let subtitles = [sub(10, lang: "eng"), sub(11, lang: "eng", forced: true)]
        let overJapanese = SeriesTrackMemory.startingPicks(entry, audio: [audio(1, lang: "jpn")], subtitles: subtitles,
                                                           fallbackAudio: audio(1, lang: "jpn"))
        XCTAssertEqual(overJapanese.subtitle, .track(10))
        let overEnglish = SeriesTrackMemory.startingPicks(entry, audio: [audio(1, lang: "eng")], subtitles: subtitles,
                                                          fallbackAudio: audio(1, lang: "eng"))
        XCTAssertEqual(overEnglish.subtitle, .track(11))
    }

    /// Off under Foreign Audio covers the current title only (#432): the series keeps the mode.
    func test_offUnderForeignAudio_isRememberedAsTheMode() {
        let current = SubtitleIntent.foreignAudio(language: "eng", hearingImpaired: false)
        SeriesTrackMemory.remember(subtitle: .afterPick(nil, replacing: current, audioLanguage: "jpn"), for: "show/a")
        XCTAssertEqual(SeriesTrackMemory.entry(for: "show/a")?.subtitle, current)
    }

    func test_forgetSubtitle_keepsTheAudio_andDropsAnEmptyEntry() {
        SeriesTrackMemory.remember(audio: AudioIntent(language: "jpn"), for: "show/a")
        SeriesTrackMemory.remember(subtitle: .off, for: "show/a")
        SeriesTrackMemory.remember(subtitle: .off, for: "show/b")
        SeriesTrackMemory.forgetSubtitle(for: "show/a")
        SeriesTrackMemory.forgetSubtitle(for: "show/b")
        XCTAssertEqual(SeriesTrackMemory.entry(for: "show/a")?.audio?.language, "jpn")
        XCTAssertNil(SeriesTrackMemory.entry(for: "show/a")?.subtitle)
        XCTAssertNil(SeriesTrackMemory.entry(for: "show/b"))
    }

    // MARK: - Starting selection (transcodes, iOS and Mac)

    /// The series' picks outrank Plex's per-item selection and the saved intents.
    func test_startingPlexSelection_seriesPicksWin() {
        TrackIntentStore.audioIntent = AudioIntent(language: "eng")
        TrackIntentStore.subtitleIntent = .off
        SeriesTrackMemory.remember(audio: AudioIntent(language: "jpn"), for: "show/a")
        SeriesTrackMemory.remember(subtitle: .track(language: "eng", forced: false, hearingImpaired: false, codec: nil),
                                   for: "show/a")
        let tracks = streams(#"""
            [{"id":1,"streamType":2,"index":1,"languageCode":"jpn","codec":"aac","default":true},
             {"id":2,"streamType":2,"index":2,"languageCode":"eng","codec":"eac3","selected":true},
             {"id":3,"streamType":3,"index":3,"languageCode":"eng","codec":"srt"}]
            """#)
        XCTAssertEqual(TrackIntentResolver.startingPlexSelection(streams: tracks, series: "show/a"),
                       TrackPicks(audio: 1, subtitle: .track(3)))
        XCTAssertEqual(TrackIntentResolver.startingPlexSelection(streams: tracks),
                       TrackPicks(audio: 2, subtitle: .off))
    }

    func test_key_forARequest_isTheShowForEpisodesOnly() throws {
        let episode = try JSONDecoder().decode(PlexMetadata.self, from: Data(#"""
            {"ratingKey":"7","type":"episode","grandparentGuid":"plex://show/5d9c","grandparentRatingKey":"3"}
            """#.utf8))
        var movie = episode
        movie.type = "movie"
        func request(_ item: PlexMetadata) -> PlexPlaybackRequest {
            PlexPlaybackRequest(item: item, url: URL(string: "https://a/v")!, headers: [:], markers: [], serverURL: "https://a",
                                token: "", quality: .original, plan: .original, sourceKbps: nil, mediaIndex: 0,
                                transcodeSessionID: nil, measuredKbps: nil, measuredAt: nil, startTime: nil)
        }
        XCTAssertEqual(SeriesTrackMemory.key(for: request(episode)), "plex://show/5d9c")
        XCTAssertNil(SeriesTrackMemory.key(for: request(movie)))
    }
}
