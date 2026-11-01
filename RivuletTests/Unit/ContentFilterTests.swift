// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContentFilterTests.swift
//  RivuletTests
//
//  Pure tests for the local content filter: the MCF/EDL parsers, list
//  source URLs, subtitle-file selection and scanning, the language matcher,
//  and the manager's tick logic (mute windows, scene skips, re-arming on
//  rewind, pausing). No network, no disk: lists are injected via
//  `applyList` and `applyTranscript`; settings go through UserDefaults and
//  are cleaned up in tearDown.
//

import os
import XCTest
@testable import Rivulet

// MARK: - Parsers

final class ContentFilterParserTests: XCTestCase {

    // MARK: EDL

    func testEDLBasicSkipAndMute() throws {
        let edl = """
        # comment line
        10.0 20.0 0
        30 40 1 profanity
        50 60 2
        """
        let list = try ContentFilterParser.parse(content: edl, url: nil)
        XCTAssertEqual(list.regions.count, 2)

        let skip = list.regions[0]
        XCTAssertEqual(skip.start, 10.0)
        XCTAssertEqual(skip.end, 20.0)
        XCTAssertEqual(skip.action, .skip)
        XCTAssertEqual(skip.category, .other)

        let mute = list.regions[1]
        XCTAssertEqual(mute.action, .mute)
        XCTAssertEqual(mute.category, .profanity)
    }

    func testEDLIgnoresInvalidLines() throws {
        let edl = """
        20 10 0
        not a line
        5 6 0
        """
        let list = try ContentFilterParser.parse(content: edl, url: nil)
        XCTAssertEqual(list.regions.count, 1)
        XCTAssertEqual(list.regions[0].start, 5)
    }

    func testEDLCommercialActionSkips() throws {
        let list = try ContentFilterParser.parse(content: "1 2 3", url: nil)
        XCTAssertEqual(list.regions.first?.action, .skip)
    }

    // MARK: MCF

    func testMCFCueBecomesRegion() throws {
        let mcf = """
        WEBVTT

        00:01:10.000 --> 00:01:12.500
        profanity=high
        """
        let list = try ContentFilterParser.parse(content: mcf, url: nil)
        XCTAssertEqual(list.regions.count, 1)
        let region = try XCTUnwrap(list.regions.first)
        XCTAssertEqual(region.start, 70.0, accuracy: 0.01)
        XCTAssertEqual(region.end, 72.5, accuracy: 0.01)
        XCTAssertEqual(region.category, .profanity)
        XCTAssertEqual(region.severity, .strong)
        XCTAssertEqual(region.action, .mute)   // language default
    }

    func testMCFSceneCategoryDefaultsToSkip() throws {
        let mcf = """
        WEBVTT

        00:00:05.000 --> 00:00:09.000
        violence=medium
        """
        let list = try ContentFilterParser.parse(content: mcf, url: nil)
        XCTAssertEqual(list.regions.first?.category, .violence)
        XCTAssertEqual(list.regions.first?.action, .skip)
    }

    func testMCFAudioChannelForcesMute() throws {
        let mcf = """
        WEBVTT

        00:00:05.000 --> 00:00:09.000
        violence=high channel=audio
        """
        let list = try ContentFilterParser.parse(content: mcf, url: nil)
        XCTAssertEqual(list.regions.first?.action, .mute)
    }

    func testMCFMultiplePairsInOneCue() throws {
        let mcf = """
        WEBVTT

        00:00:05.000 --> 00:00:09.000
        violence=high nudity=low
        """
        let list = try ContentFilterParser.parse(content: mcf, url: nil)
        XCTAssertEqual(list.regions.count, 2)
        XCTAssertEqual(Set(list.regions.map(\.category)), [.violence, .sexNudity])
    }

    func testUnrecognizedContentThrows() {
        XCTAssertThrowsError(try ContentFilterParser.parse(content: "hello world", url: nil))
        XCTAssertThrowsError(try ContentFilterParser.parse(content: "   ", url: nil))
    }

    func testFormatDetectionByExtension() throws {
        // A .edl extension wins even though the content alone is ambiguous.
        let url = URL(string: "https://example.com/123.edl")!
        let list = try ContentFilterParser.parse(content: "1 2 0", url: url)
        XCTAssertEqual(list.regions.count, 1)
    }

    func testRegionsSortedByStart() throws {
        let edl = """
        50 60 0
        5 6 0
        """
        let list = try ContentFilterParser.parse(content: edl, url: nil)
        XCTAssertEqual(list.regions.map(\.start), [5, 50])
    }

    func testEDLClockTimes() throws {
        let list = try ContentFilterParser.parse(content: "00:01:10.500 00:01:12 1", url: nil)
        let region = try XCTUnwrap(list.regions.first)
        XCTAssertEqual(region.start, 70.5, accuracy: 0.001)
        XCTAssertEqual(region.end, 72, accuracy: 0.001)
        XCTAssertEqual(region.action, .mute)
    }

    func testEDLEntriesAreStrong() throws {
        // No severity in the format: every entry must survive "Strong only".
        let list = try ContentFilterParser.parse(content: "1 2 1 profanity", url: nil)
        XCTAssertEqual(list.regions.first?.severity, .strong)
    }

    func testWebPageAtAnEDLURLIsNotAnEmptyList() {
        // A captive portal's login page must not read as "no filters here".
        let url = URL(string: "https://example.com/title.edl")!
        XCTAssertThrowsError(try ContentFilterParser.parse(content: "<html>Sign in</html>", url: url))
    }

    func testEDLOwnCategoryNamesRoundTrip() throws {
        let list = try ContentFilterParser.parse(content: "1 2 1 sexualLanguage", url: nil)
        XCTAssertEqual(list.regions.first?.category, .sexualLanguage)
    }

    // MARK: MCF as specified (moviecontentfilter.com/specification)

    /// Adapted from the spec's example, with a real-time START/END.
    private let specExample = """
    WEBVTT MovieContentFilter 1.1.0

    NOTE
    TITLE Ozymandias
    YEAR 2013
    TYPE episode

    NOTE
    START 00:00:04.020
    END 00:44:00.100

    00:00:06.075 --> 00:00:10.500
    violence=high

    00:06:14.000 --> 00:06:17.581
    gambling=medium # Some comment
    drugs=high=video

    00:30:59.118 --> 00:31:03.240
    sex=low=both # Another comment

    00:32:31.020 --> 00:32:49.800
    fear=low
    language=high=audio
    """

    func testMCFSpecExample() throws {
        let list = try ContentFilterParser.parse(content: specExample, url: nil, mediaDuration: 2700)
        XCTAssertEqual(list.regions.count, 6)

        let drugs = try XCTUnwrap(list.regions.first { $0.start == 374 && $0.severity == .strong })
        XCTAssertEqual(drugs.category, .substances)
        XCTAssertEqual(drugs.action, .skip)

        let language = try XCTUnwrap(list.regions.first { $0.category == .profanity })
        XCTAssertEqual(language.severity, .strong)
        XCTAssertEqual(language.action, .mute)   // channel=audio

        XCTAssertTrue(list.regions.contains { $0.category == .frightening })   // fear
        XCTAssertTrue(list.regions.contains { $0.category == .sexNudity && $0.severity == .mild })
    }

    func testMCFSubcategoriesFollowTheirTopic() throws {
        let mcf = """
        WEBVTT MovieContentFilter 1.1.0

        00:00:01.000 --> 00:00:02.000
        sexualDialogue=medium
        nameCalling=low=audio
        sexism=high
        toplessness=medium
        stabbing=high
        claustrophobia=low
        cigarettes=low
        """
        let categories = try ContentFilterParser.parse(content: mcf, url: nil).regions.map(\.category)
        XCTAssertEqual(Set(categories),
                       [.sexualLanguage, .profanity, .slur, .sexNudity, .violence, .frightening, .substances])
        // "sexualDialogue" is language, not a scene: it mutes by default.
        let dialogue = try ContentFilterParser.parse(content: mcf, url: nil).regions
            .first { $0.category == .sexualLanguage }
        XCTAssertEqual(dialogue?.action, .mute)
    }

    func testMCFIgnoresNonContentTopics() throws {
        let mcf = """
        WEBVTT MovieContentFilter 1.1.0

        00:00:01.000 --> 00:00:02.000
        productPlacement=high
        tedious=high
        kissing=medium
        commercial=high
        madeUpCategory=high
        """
        XCTAssertTrue(try ContentFilterParser.parse(content: mcf, url: nil).isEmpty)
    }

    func testMCFCommentCannotInjectASpan() throws {
        let mcf = """
        WEBVTT

        00:00:01.000 --> 00:00:02.000
        fear=low # https://example.com/?violence=high
        """
        let list = try ContentFilterParser.parse(content: mcf, url: nil)
        XCTAssertEqual(list.regions.map(\.category), [.frightening])
    }

    func testMCFNormalizedDownloadIsRejected() {
        // moviecontentfilter.com's .mcf download rescales the title onto
        // 0–99:59:59.999; applied as-is its times would be wildly wrong.
        let mcf = """
        WEBVTT MovieContentFilter 1.1.0

        NOTE
        START 00:00:00.000
        END 99:59:59.999

        50:00:00.000 --> 50:00:30.000
        violence=high=both
        """
        XCTAssertThrowsError(try ContentFilterParser.parse(content: mcf, url: nil, mediaDuration: 7200)) { error in
            guard case ContentFilterParseError.unsynchronized = error else {
                return XCTFail("expected .unsynchronized, got \(error)")
            }
        }
        // Runtime unknown: the normalized scale alone gives it away.
        XCTAssertThrowsError(try ContentFilterParser.parse(content: mcf, url: nil))
    }

    func testMCFRealTimeListFitsItsRelease() throws {
        XCTAssertNoThrow(try ContentFilterParser.parse(content: specExample, url: nil, mediaDuration: 2700))
        // The same list against a much shorter cut is for another release.
        XCTAssertThrowsError(try ContentFilterParser.parse(content: specExample, url: nil, mediaDuration: 1200))
    }
}

// MARK: - List sources

final class ContentFilterSourcesTests: XCTestCase {

    private let item = ContentFilterItem(
        ratingKey: "184065",
        imdbID: "tt0133093",
        tmdbID: "603",
        tvdbID: nil,
        fileName: "The Matrix (1999)",
        duration: 8160,
        transcript: nil)

    func testTemplateWithIDPlaceholder() {
        let urls = ContentFilterSources.listURLs(
            template: "https://example.com/filters/{id}.mcf", item: item)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/filters/184065.mcf"])
    }

    func testTemplatePlaceholdersAreEncoded() {
        let urls = ContentFilterSources.listURLs(
            template: "https://example.com/{imdb}/{file}.edl?tmdb={tmdb}", item: item)
        XCTAssertEqual(urls.map(\.absoluteString),
                       ["https://example.com/tt0133093/The%20Matrix%20%281999%29.edl?tmdb=603"])
    }

    func testMissingPlaceholderValueYieldsNoURL() {
        // No tvdb id: fetching ".../.edl" would ask for the wrong file.
        XCTAssertTrue(ContentFilterSources.listURLs(
            template: "https://example.com/{tvdb}.edl", item: item).isEmpty)
    }

    func testDirectFileTemplateUsedVerbatim() {
        let urls = ContentFilterSources.listURLs(
            template: "https://example.com/one.edl", item: item)
        XCTAssertEqual(urls.map(\.absoluteString), ["https://example.com/one.edl"])
    }

    func testFolderTriesFileNameThenIMDbThenRatingKey() {
        let urls = ContentFilterSources.listURLs(template: "https://example.com/filters/", item: item)
        XCTAssertEqual(urls.map(\.absoluteString), [
            "https://example.com/filters/The%20Matrix%20%281999%29.mcf",
            "https://example.com/filters/The%20Matrix%20%281999%29.edl",
            "https://example.com/filters/tt0133093.mcf",
            "https://example.com/filters/tt0133093.edl",
            "https://example.com/filters/184065.mcf",
            "https://example.com/filters/184065.edl"
        ])
    }

    func testFolderWithOnlyARatingKey() {
        let urls = ContentFilterSources.listURLs(
            template: "https://example.com/filters", item: ContentFilterItem(ratingKey: "42"))
        XCTAssertEqual(urls.map(\.absoluteString),
                       ["https://example.com/filters/42.mcf",
                        "https://example.com/filters/42.edl"])
    }

    func testEmptyTemplateYieldsNothing() {
        XCTAssertTrue(ContentFilterSources.listURLs(template: "  ", item: item).isEmpty)
    }

    func testCacheKeyFollowsTheSource() {
        let a = ContentFilterSources.listURLs(template: "https://a.example/{id}.edl", item: item)
        let b = ContentFilterSources.listURLs(template: "https://b.example/{id}.edl", item: item)
        XCTAssertEqual(ContentFilterSources.cacheKey(for: a), ContentFilterSources.cacheKey(for: a))
        XCTAssertNotEqual(ContentFilterSources.cacheKey(for: a), ContentFilterSources.cacheKey(for: b))
    }

    func testBaseName() {
        XCTAssertEqual(ContentFilterItem.baseName(ofPath: "/media/Movies/The Matrix (1999)/The Matrix (1999).mkv"),
                       "The Matrix (1999)")
        XCTAssertEqual(ContentFilterItem.baseName(ofPath: #"D:\TV\Show - S01E02.mp4"#), "Show - S01E02")
        XCTAssertEqual(ContentFilterItem.baseName(ofPath: "noext"), "noext")
    }

    // Fetch outcomes, over file URLs so no network is involved: a file that
    // can't be read stands in for an unreachable server.

    private func tempFile(_ name: String, _ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testFetchKeepsSearchingPastAFailure() async throws {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).mcf")
        let edl = try tempFile("title.edl", "10 20 0\n")
        let outcome = await ContentFilterSources.fetchList(from: [missing, edl], mediaDuration: nil)
        guard case .found(let list) = outcome else { return XCTFail("expected .found, got \(outcome)") }
        XCTAssertEqual(list.regions.count, 1)
    }

    func testFetchTreatsANonListPageAsInconclusive() async throws {
        // A captive portal answers every URL with its login page. That says
        // nothing about the list, so the cached copy must survive.
        let page = try tempFile("title.mcf", "<html><body>Sign in to continue</body></html>")
        let outcome = await ContentFilterSources.fetchList(from: [page], mediaDuration: nil)
        guard case .unreachable = outcome else { return XCTFail("expected .unreachable, got \(outcome)") }
    }

    func testFetchReportsAbsentOnlyWhenEveryAnswerIsEmpty() async throws {
        // Timed to another release: the source answered, with nothing usable.
        let other = try tempFile("title.mcf", """
        WEBVTT MovieContentFilter 1.1.0

        NOTE
        START 00:00:00.000
        END 99:59:59.999

        50:00:00.000 --> 50:00:30.000
        violence=high=both
        """)
        let outcome = await ContentFilterSources.fetchList(from: [other], mediaDuration: 7200)
        guard case .absent = outcome else { return XCTFail("expected .absent, got \(outcome)") }
    }

    func testDecodeTextHandlesBOMAndLegacyEncodings() {
        let bom = Data([0xEF, 0xBB, 0xBF]) + Data("WEBVTT".utf8)
        XCTAssertEqual(ContentFilterSources.decodeText(bom), "WEBVTT")
        // "café" in Windows-1252: not valid UTF-8.
        XCTAssertEqual(ContentFilterSources.decodeText(Data([0x63, 0x61, 0x66, 0xE9])), "café")
        XCTAssertNil(ContentFilterSources.decodeText(Data()))
    }
}

// MARK: - Subtitle file

final class ContentFilterTranscriptTests: XCTestCase {

    private func streams(_ json: String) throws -> [PlexStream] {
        try JSONDecoder().decode([PlexStream].self, from: Data(json.utf8))
    }

    func testPrefersEnglishFullTextSidecar() throws {
        let list = try streams("""
        [
          {"id": 1, "streamType": 2, "codec": "aac", "languageCode": "eng"},
          {"id": 2, "streamType": 3, "codec": "srt", "languageCode": "eng"},
          {"id": 3, "streamType": 3, "codec": "srt", "languageCode": "eng", "key": "/library/streams/3", "forced": true},
          {"id": 4, "streamType": 3, "codec": "pgs", "languageCode": "eng", "key": "/library/streams/4"},
          {"id": 5, "streamType": 3, "codec": "srt", "languageCode": "fre", "key": "/library/streams/5"},
          {"id": 6, "streamType": 3, "codec": "srt", "languageCode": "eng", "key": "/library/streams/6", "hearingImpaired": true},
          {"id": 7, "streamType": 3, "codec": "ass", "languageCode": "eng", "key": "/library/streams/7"}
        ]
        """)
        // 2 is embedded (no key), 3 forced, 4 a bitmap, 5 French; 7 beats SDH 6.
        XCTAssertEqual(ContentFilterSources.transcriptStream(in: list)?.id, 7)
    }

    func testUnlabeledSidecarIsALastResort() throws {
        let list = try streams("""
        [
          {"id": 1, "streamType": 3, "codec": "srt", "key": "/library/streams/1"},
          {"id": 2, "streamType": 3, "codec": "srt", "language": "English", "key": "/library/streams/2", "hearingImpaired": true}
        ]
        """)
        XCTAssertEqual(ContentFilterSources.transcriptStream(in: list)?.id, 2)
        XCTAssertEqual(ContentFilterSources.transcriptStream(in: [list[0]])?.id, 1)
    }

    func testLanguageWindowsFromSRT() throws {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,000
        Good morning.

        2
        00:00:04,000 --> 00:00:06,500
        <i>What the fuck?</i>

        3
        00:00:07,000 --> 00:00:08,000
        Oh my God.
        """
        let windows = try XCTUnwrap(ContentFilterSources.languageWindows(content: srt, format: "srt"))
        // A body with no cues (an error page served with 200) is unreadable, not "no hits".
        XCTAssertNil(ContentFilterSources.languageWindows(content: "<html>503</html>", format: "srt"))
        // Every cue is kept, so the user's own words can match any of them.
        XCTAssertEqual(windows.map(\.start), [1, 4, 7])
        XCTAssertEqual(windows[1].end, 6.5, accuracy: 0.001)
        XCTAssertTrue(ProfanityDictionary.hits(in: windows[1].text).categories.contains(.profanity))
        XCTAssertTrue(ProfanityDictionary.hits(in: windows[2].text).categories.contains(.blasphemy))
    }

    // The reported title's subtitle streams: two embedded bitmap tracks.
    func testImageOnlyTitleHasNoSubtitleFile() throws {
        let list = try streams("""
        [{"id":1,"streamType":2,"codec":"aac","languageCode":"eng","selected":true},
         {"id":2,"streamType":3,"codec":"pgs","languageCode":"eng","languageTag":"en","language":"English"},
         {"id":3,"streamType":3,"codec":"pgs","languageCode":"eng","languageTag":"en","language":"English"}]
        """)
        XCTAssertNil(ContentFilterSources.transcriptStream(in: list))
        let tracks = list.filter(\.isSubtitle).map { MediaTrack(from: $0) }
        // No file to fetch, so the first image track is read on the device, unseen.
        XCTAssertEqual(ContentFilterSources.silentTrack(in: tracks, shownTrackId: nil, hasLanguageSource: false)?.id, 2)
        XCTAssertNil(ContentFilterSources.languageNotice(hasLanguageSource: false, shown: nil, tracks: tracks))
    }

    func testLanguageNotice() {
        for codec in ["pgs", "hdmv_pgs_subtitle", "vobsub", "dvd_subtitle", "dvbsub"] {
            XCTAssertFalse(ContentFilterSources.isTextSubtitle(codec: codec), codec)
        }
        for codec in ["srt", "subrip", "ass", "mov_text", "webvtt", nil] {
            XCTAssertTrue(ContentFilterSources.isTextSubtitle(codec: codec), codec ?? "nil")
        }
        // Only a track in the dictionary's language (or unlabeled) can be matched, text or image.
        XCTAssertTrue(ContentFilterSources.isReadable(MediaTrack(id: 1, name: "", languageCode: "eng", codec: "srt")))
        XCTAssertTrue(ContentFilterSources.isReadable(MediaTrack(id: 1, name: "", codec: "srt")))
        XCTAssertFalse(ContentFilterSources.isReadable(MediaTrack(id: 1, name: "", languageCode: "spa", codec: "srt")))
        XCTAssertTrue(ContentFilterSources.isReadable(MediaTrack(id: 1, name: "", languageCode: "eng", codec: "pgs")))
        XCTAssertFalse(ContentFilterSources.isReadable(MediaTrack(id: 1, name: "", languageCode: "fra", codec: "pgs")))
    }

    func testSilentTrackAndNotice() {
        func track(_ id: Int, _ lang: String?, _ codec: String, forced: Bool = false, sdh: Bool = false) -> MediaTrack {
            MediaTrack(id: id, name: "", languageCode: lang, codec: codec, isForced: forced, isHearingImpaired: sdh)
        }
        func silent(_ tracks: [MediaTrack], shown: Int? = nil, source: Bool = false) -> Int? {
            ContentFilterSources.silentTrack(in: tracks, shownTrackId: shown, hasLanguageSource: source)?.id
        }
        func notice(_ tracks: [MediaTrack], shown: Int? = nil, source: Bool = false) -> String? {
            ContentFilterSources.languageNotice(
                hasLanguageSource: source, shown: tracks.first { $0.id == shown }, tracks: tracks)
        }
        let srt = [track(3, "eng", "srt")]
        // Embedded English text, subtitles off: read unseen, nothing to say.
        XCTAssertEqual(silent(srt), 3)
        XCTAssertNil(notice(srt))
        // A subtitle file or list already covers it.
        XCTAssertNil(silent(srt, source: true))
        XCTAssertNil(notice(srt, source: true))
        // The user's own track holds the engine's selection.
        XCTAssertNil(silent(srt, shown: 3))
        XCTAssertNil(notice(srt, shown: 3))
        let mixed = [track(1, "eng", "pgs"), track(2, "spa", "srt"), track(3, "eng", "srt")]
        XCTAssertEqual(silent(mixed), 3)
        XCTAssertNil(silent(mixed, shown: 2))
        XCTAssertEqual(notice(mixed, shown: 2), "Use English Subtitles")
        // An English image track on screen is read too.
        XCTAssertNil(notice(mixed, shown: 1))
        // A forced track on screen is no source while a full one sits unread.
        let forced = [track(1, "eng", "srt", forced: true), track(2, "eng", "srt")]
        XCTAssertEqual(notice(forced, shown: 1), "Use English Subtitles")
        XCTAssertNil(notice([track(1, "eng", "srt", forced: true)], shown: 1))
        // Image-only English: read unseen, like text.
        XCTAssertEqual(silent([track(1, "spa", "pgs"), track(2, "eng", "pgs")]), 2)
        XCTAssertNil(notice([track(2, "eng", "pgs")]))
        XCTAssertEqual(silent([track(1, nil, "dvd_subtitle"), track(2, "eng", "pgs", sdh: true)]), 2)
        // Text before image, but a full image track before forced-only text.
        XCTAssertEqual(silent([track(1, "eng", "pgs"), track(2, nil, "srt")]), 2)
        XCTAssertEqual(silent([track(1, "eng", "srt", forced: true), track(2, "eng", "pgs")]), 2)
        // Nothing readable: another language of either kind, or the hls route's empty list.
        for tracks in [[track(1, "spa", "pgs")], [track(2, "spa", "srt")], []] {
            XCTAssertNil(silent(tracks))
            XCTAssertEqual(notice(tracks), "No Readable Subtitles")
        }
        // Full before forced, English before unlabeled, plain before SDH.
        XCTAssertEqual(silent([track(1, "eng", "srt", forced: true), track(2, nil, "ass"), track(3, "eng", "srt", sdh: true), track(4, "eng", "srt")]), 4)
        XCTAssertEqual(silent([track(1, "eng", "srt", forced: true), track(2, nil, "ass")]), 2)
        XCTAssertEqual(silent([track(1, "eng", "srt", forced: true)]), 1)
    }

    // MARK: Image subtitles

    /// White text with a dark outline on clear, like a PGS cue.
    private func cueImage(_ text: String) -> CGImage {
        let lines = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: 48), .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black, .strokeWidth: -4])
        let size = lines.size()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: size.width + 8, height: size.height + 8), format: format)
            .image { _ in lines.draw(at: CGPoint(x: 4, y: 4)) }.cgImage!
    }

    func testRecognisesCueImages() throws {
        let first = SubtitleImageReader.recognize(cueImage("What the fuck is that?"))
        try XCTSkipIf(first.isEmpty, "Vision text recognition is unavailable in this test host")
        XCTAssertEqual(first, "What the fuck is that?")
        // Two rows come back top row first.
        let rows = SubtitleImageReader.recognize(cueImage("- Sit the hell down.\n- What is this shit?"))
            .components(separatedBy: "\n")
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.first?.contains("hell") ?? false, rows.first ?? "")
        XCTAssertTrue(rows.last?.contains("shit") ?? false, rows.last ?? "")
        // A blank cue reads as no text.
        XCTAssertEqual(SubtitleImageReader.recognize(cueImage(" ")), "")
    }

    @MainActor
    func testImageReaderKeepsOnlyWantedCues() async {
        let (a, b, c) = (cueImage("a"), cueImage("b"), cueImage("c"))
        let gate = DispatchSemaphore(value: 0)
        let reader = SubtitleImageReader { image in
            gate.wait()
            return image === a ? "A" : image === b ? "B" : "C"
        }
        var reads = 0
        reader.onRead = { reads += 1 }
        func settle() async { try? await Task.sleep(for: .milliseconds(100)) }

        reader.read([a, b])
        XCTAssertNil(reader.text(for: a))
        // The cue ends while it is being read: its late result is dropped.
        reader.read([b, c])
        gate.signal()
        await settle()
        XCTAssertNil(reader.text(for: a))
        XCTAssertEqual(reads, 0)
        gate.signal()
        gate.signal()
        await settle()
        XCTAssertEqual(reader.text(for: b), "B")
        XCTAssertEqual(reader.text(for: c), "C")
        XCTAssertEqual(reads, 2)
        // Asking again reads nothing twice; a cue no longer wanted is forgotten.
        reader.read([c])
        await settle()
        XCTAssertEqual(reads, 2)
        XCTAssertNil(reader.text(for: b))
        XCTAssertEqual(reader.text(for: c), "C")
    }

    @MainActor
    func testImageReaderStopsReadingWhenEmptied() async {
        let (a, b) = (cueImage("a"), cueImage("b"))
        let gate = DispatchSemaphore(value: 0)
        let count = OSAllocatedUnfairLock(initialState: 0)
        let reader = SubtitleImageReader { _ in
            count.withLock { $0 += 1 }
            gate.wait()
            return "x"
        }
        var reads = 0
        reader.onRead = { reads += 1 }

        reader.read([a, b])
        // Playback stops mid-read: the read in flight is dropped and the rest never start.
        reader.read([])
        gate.signal()
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(count.withLock { $0 }, 1)
        XCTAssertEqual(reads, 0)
        XCTAssertNil(reader.text(for: a))
        gate.signal()
    }

    func testLanguageWindowsSniffUnknownFormat() throws {
        let ass = """
        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        Dialogue: 0,0:00:02.00,0:00:04.00,Default,,0,0,0,,{\\i1}Shit{\\i0}, we're late
        """
        let windows = try XCTUnwrap(ContentFilterSources.languageWindows(content: ass, format: ""))
        XCTAssertEqual(windows.map(\.start), [2])
        XCTAssertFalse(ProfanityDictionary.hits(in: windows[0].text).isEmpty)
    }
}

// MARK: - Language matcher

final class ProfanityDictionaryTests: XCTestCase {

    private let language: Set<FilterCategory> = [.profanity, .blasphemy, .slur, .sexualLanguage]

    private func muted(_ text: String,
                       categories: Set<FilterCategory>? = nil,
                       threshold: FilterSeverity = .mild) -> Bool {
        ProfanityDictionary.shouldMute(
            text: text,
            enabledCategories: categories ?? language,
            profanityThreshold: threshold)
    }

    func testPlainStrongWord() {
        XCTAssertTrue(muted("What the fuck is that"))
    }

    func testWholeWordBoundaries() {
        XCTAssertFalse(muted("The class was an assessment"))
        XCTAssertFalse(muted("Hello there"))
        XCTAssertFalse(muted("Shell station up ahead"))
    }

    func testTrailingPunctuationStillMatches() {
        // Regression: "!" is also a masking character; a trailing one must not
        // corrupt the token ("shit!" once collapsed to "shiti" and missed).
        XCTAssertTrue(muted("Shit!"))
        XCTAssertTrue(muted("Damn!"))
        XCTAssertTrue(muted("Oh, shit."))
    }

    func testMaskedSpellings() {
        XCTAssertTrue(muted("You little sh*t"))
        XCTAssertTrue(muted("sh!t happens"))
        XCTAssertTrue(muted("What the f***"))
        XCTAssertTrue(muted("f**k this"))
        XCTAssertTrue(muted("b@stard"))
    }

    func testStubGuardAgainstInnocentShortTokens() {
        // Stub expansion only applies to genuinely censored tokens; "B1" must
        // not expand into a hit.
        XCTAssertFalse(muted("Vitamin B1 tablets"))
        XCTAssertFalse(muted("Gate B1 is closed"))
    }

    func testProfanityThreshold() {
        XCTAssertTrue(muted("damn it", threshold: .mild))
        XCTAssertFalse(muted("damn it", threshold: .strong))
        XCTAssertTrue(muted("fuck", threshold: .strong))
        // Non-profanity language categories ignore the threshold.
        XCTAssertTrue(muted("jesus christ", threshold: .strong))
    }

    func testPhraseMatching() {
        XCTAssertTrue(muted("God damn it, hurry"))
        XCTAssertTrue(muted("God damn!"))          // trailing punctuation
        XCTAssertTrue(muted("For god’s sake"))     // curly apostrophe
        XCTAssertFalse(muted("Thank god you came")) // "god" alone never mutes
    }

    func testCategoryGating() {
        XCTAssertFalse(muted("What the fuck", categories: [.blasphemy]))
        XCTAssertFalse(muted("jesus christ", categories: [.profanity]))
        XCTAssertFalse(muted("anything at all", categories: []))
    }

    func testSubtitleSpellings() {
        // The forms subtitles actually use, which exact-word matching missed.
        XCTAssertTrue(muted("I'm fuckin' serious"))
        XCTAssertTrue(muted("Dammit, Jim"))
        XCTAssertTrue(muted("Stop bullshitting me"))
        XCTAssertTrue(muted("You jackass"))
        XCTAssertTrue(muted("Goddamned thing"))
        XCTAssertTrue(muted("What the f***in' hell", threshold: .strong))
    }

    func testFuckMatchesInsideWords() {
        XCTAssertTrue(muted("What a clusterfuck", threshold: .strong))
        XCTAssertTrue(muted("Unfuckingbelievable", threshold: .strong))
    }

    func testNoInfixFalsePositives() {
        // Only "fuck" matches inside a word; everything else is whole-word.
        XCTAssertFalse(muted("Welcome to Scunthorpe"))
        XCTAssertFalse(muted("A cocktail and a class assignment"))
        XCTAssertFalse(muted("Yoshitaka ordered shiitake"))
        XCTAssertFalse(muted("Read some Dickens"))
        XCTAssertFalse(muted("Thank god you came"))
    }

    func testSlursAreDetected() {
        XCTAssertTrue(muted("Get out of here, you faggot", categories: [.slur]))
        XCTAssertFalse(muted("Get out of here, you faggot", categories: [.profanity]))
    }

    func testBlasphemousExclamations() {
        XCTAssertTrue(muted("Oh my God!", categories: [.blasphemy]))
        XCTAssertTrue(muted("Oh, God.", categories: [.blasphemy]))
        XCTAssertTrue(muted("I swear to God", categories: [.blasphemy]))
        XCTAssertTrue(muted("Oh, Christ. I guess you'll do.", categories: [.blasphemy]))
        XCTAssertTrue(muted("Oh Jesus", categories: [.blasphemy]))
        XCTAssertFalse(muted("As a Christian, I am doing you a favor", categories: [.blasphemy]))
        XCTAssertFalse(muted("My goddess", categories: [.blasphemy]))
    }

    func testPossessivesMatchTheirWord() {
        XCTAssertTrue(muted("That bitch's car"))
        XCTAssertFalse(muted("It's the boss's car"))
    }

    func testMusicalKeysAreNotCensoredWords() {
        XCTAssertFalse(muted("It's in F# minor"))
        XCTAssertFalse(muted("Play it in B#"))
        XCTAssertTrue(muted("What the f##k"))
    }

    func testHitsReportStrongestProfanity() {
        let hits = ProfanityDictionary.hits(in: "Damn it, you stupid shit")
        XCTAssertEqual(hits.categories, [.profanity])
        XCTAssertEqual(hits.strongestProfanity, .strong)
        XCTAssertTrue(ProfanityDictionary.hits(in: "Lovely weather").isEmpty)
    }
}

// MARK: - Manager tick logic

@MainActor
final class ContentFilterManagerTests: XCTestCase {

    private var manager: ContentFilterManager!

    private var allKeys: [String] {
        [ContentFilterManager.Keys.enabled,
         ContentFilterManager.Keys.profanityStrength,
         ContentFilterManager.Keys.listSourceURL,
         ContentFilterManager.Keys.customWords]
        + FilterCategory.allCases.map(\.enabledDefaultsKey)
    }

    override func setUp() {
        super.setUp()
        allKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.set(true, forKey: ContentFilterManager.Keys.enabled)
        manager = ContentFilterManager()
    }

    override func tearDown() {
        allKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        manager = nil
        super.tearDown()
    }

    private func regions(_ list: [(Double, Double, FilterCategory, FilterAction)],
                         severity: FilterSeverity = .moderate) -> ContentFilterList {
        ContentFilterList(regions: list.enumerated().map { index, r in
            FilterRegion(id: index, start: r.0, end: r.1,
                         category: r.2, severity: severity, action: r.3)
        })
    }

    private func window(_ start: Double, _ end: Double, _ text: String) -> LanguageWindow {
        LanguageWindow(start: start, end: end, text: text)
    }

    func testOnlyLanguageCategoriesReadSubtitleText() {
        XCTAssertTrue(manager.readsSubtitleText)
        // Scene categories alone (plus `.other`) have nothing to match in text.
        FilterCategory.allCases.forEach {
            UserDefaults.standard.set(!$0.isTextDetectable, forKey: $0.enabledDefaultsKey)
        }
        manager.refreshSettings()
        XCTAssertFalse(manager.readsSubtitleText)
    }

    func testSkipTriggersOnceAndRearmsOnRewind() {
        manager.applyList(regions([(100, 110, .violence, .skip)]))

        XCTAssertNil(manager.timeDidUpdate(99))
        let target = manager.timeDidUpdate(100.5)
        XCTAssertNotNil(target)
        XCTAssertEqual(target ?? 0, 110.25, accuracy: 0.01)

        // Consumed: ticks inside the window while the seek is in flight
        // must not re-trigger.
        XCTAssertNil(manager.timeDidUpdate(100.7))

        // Rewinding to before the window re-arms it.
        XCTAssertNil(manager.timeDidUpdate(95))
        XCTAssertNotNil(manager.timeDidUpdate(101))
    }

    func testSkippingBackIntoASkippedSceneSkipsItAgain() {
        manager.applyList(regions([(100, 110, .violence, .skip)]))
        XCTAssertNotNil(manager.timeDidUpdate(100.5))
        XCTAssertNil(manager.timeDidUpdate(110.25))   // landed past it
        // A 10s skip-back lands inside the scene: it must not play.
        let target = manager.timeDidUpdate(100.25)
        XCTAssertEqual(target ?? 0, 110.25, accuracy: 0.01)
    }

    func testOverlappingSkipWindowsJumpToFurthestEnd() {
        manager.applyList(regions([
            (100, 110, .violence, .skip),
            (105, 130, .frightening, .skip)
        ]))
        let target = manager.timeDidUpdate(106)
        XCTAssertEqual(target ?? 0, 130.25, accuracy: 0.01)
    }

    func testScrubbingSuppressesSkipButKeepsMuteCurrent() {
        manager.applyList(regions([
            (10, 20, .violence, .skip),
            (30, 40, .other, .mute)
        ]))
        XCTAssertNil(manager.timeDidUpdate(15, allowSkip: false))
        XCTAssertNil(manager.timeDidUpdate(35, allowSkip: false))
        XCTAssertTrue(manager.isFilterMuting)
        XCTAssertNil(manager.timeDidUpdate(45, allowSkip: false))
        XCTAssertFalse(manager.isFilterMuting)
    }

    func testMuteRegionSetsAndClears() {
        manager.applyList(regions([(5, 8, .other, .mute)]))
        XCTAssertNil(manager.timeDidUpdate(6))
        XCTAssertTrue(manager.isFilterMuting)
        XCTAssertNil(manager.timeDidUpdate(9))
        XCTAssertFalse(manager.isFilterMuting)
    }

    func testDisabledCategoryDoesNotAct() {
        UserDefaults.standard.set(false, forKey: FilterCategory.violence.enabledDefaultsKey)
        manager.refreshSettings()
        manager.applyList(regions([(10, 20, .violence, .skip)]))
        XCTAssertNil(manager.timeDidUpdate(15))
    }

    func testMasterSwitchOffDoesNothing() {
        UserDefaults.standard.set(false, forKey: ContentFilterManager.Keys.enabled)
        manager.refreshSettings()
        manager.applyList(regions([(10, 20, .violence, .skip)]))
        XCTAssertNil(manager.timeDidUpdate(15))
        XCTAssertFalse(manager.isFilterMuting)
    }

    func testSubtitleLinesMuteTheirWholeCueUntilWordsArePlaced() {
        manager.subtitleLinesDidChange([SubtitleLine(id: 1, start: 0.5, end: 3, text: "What the fuck")])
        _ = manager.timeDidUpdate(1)
        XCTAssertTrue(manager.isFilterMuting)
        _ = manager.timeDidUpdate(3.5)
        XCTAssertFalse(manager.isFilterMuting)

        manager.subtitleLinesDidChange([])
        _ = manager.timeDidUpdate(1)
        XCTAssertFalse(manager.isFilterMuting)
    }

    func testRefreshSettingsRejudgesTheLineOnScreen() {
        // A line muted under the old settings must not stay muted under new ones.
        manager.subtitleLinesDidChange([SubtitleLine(id: 1, start: 0, end: 3, text: "What the fuck")])
        _ = manager.timeDidUpdate(1)
        XCTAssertTrue(manager.isFilterMuting)
        UserDefaults.standard.set(false, forKey: FilterCategory.profanity.enabledDefaultsKey)
        manager.refreshSettings()
        XCTAssertFalse(manager.isFilterMuting)
    }

    func testHeardWordsNarrowTheMuteToTheWord() {
        manager.applyTranscript([window(10, 14, "You stupid son of a bitch, get out")])
        let words = ["you", "stupid", "son", "of", "a", "bitch", "get", "out"].enumerated().map { index, text in
            SpokenWord(text: text, start: 10.2 + Double(index) * 0.4, end: 10.5 + Double(index) * 0.4, confidence: 0.9)
        }
        // Before the audio is heard, the whole cue mutes.
        _ = manager.timeDidUpdate(10.3)
        XCTAssertTrue(manager.isFilterMuting)

        manager.wordsHeard(words, covering: 5...20)
        _ = manager.timeDidUpdate(10.3)     // "you"
        XCTAssertFalse(manager.isFilterMuting)
        _ = manager.timeDidUpdate(11.5)     // "son of a bitch"
        XCTAssertTrue(manager.isFilterMuting)
        _ = manager.timeDidUpdate(13.2)     // "out"
        XCTAssertFalse(manager.isFilterMuting)
        XCTAssertEqual(manager.nextMuteEdge(after: 12) ?? 0, 12.65, accuracy: 0.01)
    }

    func testPartlyHeardLineIsPlacedOnceItsWordIsHeard() {
        manager.applyTranscript([window(10, 14, "Holy shit, that was crazy, I can't believe it")])
        let words = ["holy", "shit", "that", "was"].enumerated().map { index, text in
            SpokenWord(text: text, start: 10.2 + Double(index) * 0.4, end: 10.5 + Double(index) * 0.4, confidence: 0.9)
        }
        // Heard only to 11.8: the rest of the line isn't transcribed yet.
        manager.wordsHeard(words, covering: 5...11.8)
        _ = manager.timeDidUpdate(10.3)
        XCTAssertFalse(manager.isFilterMuting)
        _ = manager.timeDidUpdate(10.7)
        XCTAssertTrue(manager.isFilterMuting)
        _ = manager.timeDidUpdate(11.3)
        XCTAssertFalse(manager.isFilterMuting)
    }

    func testCustomWordsMuteWhateverTheCategories() {
        FilterCategory.allCases.forEach { UserDefaults.standard.set(false, forKey: $0.enabledDefaultsKey) }
        UserDefaults.standard.set(["stupid"], forKey: ContentFilterManager.Keys.customWords)
        defer { UserDefaults.standard.removeObject(forKey: ContentFilterManager.Keys.customWords) }
        manager.refreshSettings()
        manager.applyTranscript([window(10, 12, "That's stupid"), window(20, 22, "What the fuck")])
        _ = manager.timeDidUpdate(11)
        XCTAssertTrue(manager.isFilterMuting)
        _ = manager.timeDidUpdate(21)
        XCTAssertFalse(manager.isFilterMuting)
    }

    func testSpeechAloneMutesWithNoSubtitles() {
        manager.wordsHeard([SpokenWord(text: "shit", start: 30, end: 30.4, confidence: 0.9),
                            SpokenWord(text: "shut", start: 40, end: 40.3, confidence: 0.9),
                            SpokenWord(text: "damn", start: 50, end: 50.3, confidence: 0.2)],
                           covering: 25...55)
        _ = manager.timeDidUpdate(30.2)
        XCTAssertFalse(manager.isFilterMuting)   // subtitles may still arrive
        manager.setSpeechOnly(true)
        XCTAssertTrue(manager.isFilterMuting)
        _ = manager.timeDidUpdate(40.1)
        XCTAssertFalse(manager.isFilterMuting)
        _ = manager.timeDidUpdate(50.1)
        XCTAssertFalse(manager.isFilterMuting)   // too unsure to act on
    }

    func testBackToBackSkipWindowsTakeOneSeek() {
        manager.applyList(regions([
            (100, 110, .violence, .skip),
            (110, 125, .violence, .skip)
        ]))
        let target = manager.timeDidUpdate(101)
        XCTAssertEqual(target ?? 0, 125.25, accuracy: 0.01)
        XCTAssertNil(manager.timeDidUpdate(125.3))
    }

    func testImportedProfanityHonorsStrength() {
        UserDefaults.standard.set(FilterSeverity.strong.rawValue,
                                  forKey: ContentFilterManager.Keys.profanityStrength)
        manager.refreshSettings()
        manager.applyList(regions([(5, 8, .profanity, .mute)], severity: .mild))
        _ = manager.timeDidUpdate(6)
        XCTAssertFalse(manager.isFilterMuting)

        manager.applyList(regions([(5, 8, .profanity, .mute)], severity: .strong))
        _ = manager.timeDidUpdate(6)
        XCTAssertTrue(manager.isFilterMuting)
    }

    func testTranscriptWindowsMuteWithoutSubtitlesOnScreen() {
        manager.applyTranscript([window(10, 12, "What the fuck"), window(20, 22, "Oh my God")])
        _ = manager.timeDidUpdate(11)
        XCTAssertTrue(manager.isFilterMuting)
        _ = manager.timeDidUpdate(15)
        XCTAssertFalse(manager.isFilterMuting)
        _ = manager.timeDidUpdate(21)
        XCTAssertTrue(manager.isFilterMuting)
    }

    func testTranscriptWindowsFollowSettings() {
        UserDefaults.standard.set(false, forKey: FilterCategory.blasphemy.enabledDefaultsKey)
        UserDefaults.standard.set(FilterSeverity.strong.rawValue,
                                  forKey: ContentFilterManager.Keys.profanityStrength)
        manager.refreshSettings()
        manager.applyTranscript([window(10, 12, "Oh my God"), window(20, 22, "Damn it")])
        _ = manager.timeDidUpdate(11)
        XCTAssertFalse(manager.isFilterMuting)   // blasphemy off
        _ = manager.timeDidUpdate(21)
        XCTAssertFalse(manager.isFilterMuting)   // mild, below "Strong only"
    }

    func testSubtitleDelayShiftsWindowsOnlyForTheSameFile() {
        // A file URL that doesn't exist: the background read fails at once,
        // with no network, and the injected windows stand.
        let source = ContentFilterItem.TranscriptSource(
            url: URL(fileURLWithPath: "/nonexistent/subs.srt"), format: "srt", streamKey: "/library/streams/9")
        manager.beginItem(ContentFilterItem(ratingKey: "1", transcript: source))
        manager.applyTranscript([window(10, 12, "What the fuck")])

        // The same file on screen, shown 5s later: the window moves with it.
        manager.displayedSubtitleDidChange(streamKey: "/library/streams/9", delay: 5)
        _ = manager.timeDidUpdate(11)
        XCTAssertFalse(manager.isFilterMuting)
        _ = manager.timeDidUpdate(16)
        XCTAssertTrue(manager.isFilterMuting)

        // Another track on screen says nothing about this file's timing.
        manager.displayedSubtitleDidChange(streamKey: "/library/streams/2", delay: 5)
        _ = manager.timeDidUpdate(11)
        XCTAssertTrue(manager.isFilterMuting)
    }

    func testPauseSuspendsAndResumes() {
        manager.applyList(regions([(5, 8, .other, .mute), (20, 30, .violence, .skip)]))
        manager.setPaused(true)
        XCTAssertNil(manager.timeDidUpdate(6))
        XCTAssertFalse(manager.isFilterMuting)
        XCTAssertNil(manager.timeDidUpdate(21))

        manager.setPaused(false)
        XCTAssertNotNil(manager.timeDidUpdate(22))
        _ = manager.timeDidUpdate(6)
        XCTAssertTrue(manager.isFilterMuting)
    }

    func testPauseEndsWithTheItem() {
        manager.setPaused(true)
        manager.beginItem(ContentFilterItem(ratingKey: "1"))
        XCTAssertFalse(manager.isPaused)
    }

    func testLanguageSourceFollowsWhatLoaded() {
        XCTAssertFalse(manager.hasLanguageSource)
        // Scene skips alone give no language to mute.
        manager.applyList(regions([(10, 20, .violence, .skip)]))
        XCTAssertFalse(manager.hasLanguageSource)
        XCTAssertTrue(manager.hasSceneSkips)
        // A muted scene is no language source either; an uncategorised mute is.
        manager.applyList(regions([(10, 20, .violence, .mute)]))
        XCTAssertFalse(manager.hasLanguageSource)
        manager.applyList(regions([(10, 20, .other, .mute)]))
        XCTAssertTrue(manager.hasLanguageSource)
        manager.applyList(regions([(10, 20, .profanity, .mute)]))
        XCTAssertTrue(manager.hasLanguageSource)
        // A mute the settings ignore is no source.
        manager.applyList(regions([(10, 20, .profanity, .mute)], severity: .mild))
        XCTAssertFalse(manager.hasLanguageSource)
        manager.applyList(.empty)
        XCTAssertFalse(manager.hasLanguageSource)
        XCTAssertFalse(manager.hasSceneSkips)
        // A subtitle file with no hits was still read.
        manager.applyTranscript([])
        XCTAssertTrue(manager.hasLanguageSource)
        manager.reset()
        XCTAssertFalse(manager.hasLanguageSource)
    }

    func testUnreadableSubtitleFileIsNotASource() async {
        let missing = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).srt")
        manager.beginItem(ContentFilterItem(
            ratingKey: "1",
            transcript: .init(url: missing, format: "srt", streamKey: "/library/streams/1")))
        XCTAssertTrue(manager.hasLanguageSource)
        await manager.transcriptTask?.value
        XCTAssertFalse(manager.hasLanguageSource)
        _ = manager.timeDidUpdate(5)
        XCTAssertFalse(manager.isFilterMuting)
    }

    func testSubtitleFileLoadsThroughTheManager() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).srt")
        try Data("1\n00:00:04,000 --> 00:00:06,000\nWhat the fuck?\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        manager.beginItem(ContentFilterItem(
            ratingKey: "1",
            transcript: .init(url: url, format: "srt", streamKey: "/library/streams/1")))
        await manager.transcriptTask?.value
        XCTAssertTrue(manager.hasLanguageSource)
        _ = manager.timeDidUpdate(3.9)
        XCTAssertFalse(manager.isFilterMuting)
        _ = manager.timeDidUpdate(4)
        XCTAssertTrue(manager.isFilterMuting)
        _ = manager.timeDidUpdate(6)
        XCTAssertFalse(manager.isFilterMuting)
    }
}
