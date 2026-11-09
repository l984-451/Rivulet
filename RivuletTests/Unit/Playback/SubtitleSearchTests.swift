// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import XCTest
@testable import Rivulet

final class SubtitleSearchTests: XCTestCase {
    // MARK: - Language

    func test_alpha2_prefersTheSubtitleLanguageOverTheDevice() {
        XCTAssertEqual(SubtitleSearchLanguage.alpha2(preferred: "eng", device: "deu"), "en")
        XCTAssertEqual(SubtitleSearchLanguage.alpha2(preferred: "spa", device: "eng"), "es")
    }

    func test_alpha2_fallsBackToTheDevice() {
        XCTAssertEqual(SubtitleSearchLanguage.alpha2(preferred: nil, device: "deu"), "de")
        XCTAssertEqual(SubtitleSearchLanguage.alpha2(preferred: "", device: "fra"), "fr")
    }

    func test_alpha3_isThreeLetterForJellyfinAndEmby() {
        XCTAssertEqual(SubtitleSearchLanguage.alpha3("en"), "eng")
        XCTAssertEqual(SubtitleSearchLanguage.alpha3("de"), "deu")
    }

    // MARK: - Result mapping

    func test_jellyfinResult_mapsFieldsAndDropsRowsWithoutAnId() throws {
        let json = """
        [{"Id":"abc","Name":"Movie.2020.BluRay","Format":"srt","ThreeLetterISOLanguageName":"eng",
          "ProviderName":"Open Subtitles","HearingImpaired":true,"Forced":false},
         {"Name":"no id"}]
        """
        let dtos = try JellyfinJSON.decoder().decode([JFRemoteSubtitle].self, from: Data(json.utf8))
        let results = dtos.compactMap(JellyfinProvider.subtitleResult)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].id, "abc")
        XCTAssertEqual(results[0].title, "Movie.2020.BluRay")
        XCTAssertEqual(results[0].format, "srt")
        XCTAssertTrue(results[0].isHearingImpaired)
        XCTAssertFalse(results[0].isForced)
    }

    func test_embyResult_readsTheIsPrefixedFlags() throws {
        let json = #"[{"Id":"7","Name":"x","Format":"ass","ThreeLetterISOLanguageName":"deu","IsForced":true,"IsHearingImpaired":false}]"#
        let dtos = try EmbyJSON.decoder().decode([EmbyRemoteSubtitle].self, from: Data(json.utf8))
        let result = try XCTUnwrap(dtos.compactMap(EmbyProvider.subtitleResult).first)
        XCTAssertTrue(result.isForced)
        XCTAssertFalse(result.isHearingImpaired)
    }

    func test_plexResult_usesTheResultKeyAsTheId() throws {
        let json = #"{"streamType":3,"key":"/library/streams/9","codec":"srt","displayTitle":"English (SRT)","language":"English","forced":true}"#
        let stream = try JSONDecoder().decode(PlexStream.self, from: Data(json.utf8))
        let result = PlexSubtitleSearch.result(stream)
        XCTAssertEqual(result.id, "/library/streams/9")
        XCTAssertEqual(result.title, "English (SRT)")
        XCTAssertTrue(result.isForced)
        XCTAssertEqual(result.detail, "English • SRT • " + String(localized: "Forced"))
    }

    // MARK: - Capability

    func test_jellyfin_needsAdminOrSubtitleManagement() throws {
        func policy(_ json: String) throws -> JFUserWithPolicy.Policy? {
            try JellyfinJSON.decoder().decode(JFUserWithPolicy.self, from: Data(#"{"Policy":\#(json)}"#.utf8)).policy
        }
        let fetchers = [JFLibraryAvailableOptions.Fetcher(name: "Open Subtitles")]
        XCTAssertTrue(JellyfinProvider.allowsSubtitleSearch(policy: try policy(#"{"IsAdministrator":true}"#), fetchers: fetchers))
        XCTAssertTrue(JellyfinProvider.allowsSubtitleSearch(policy: try policy(#"{"EnableSubtitleManagement":true}"#), fetchers: fetchers))
        XCTAssertFalse(JellyfinProvider.allowsSubtitleSearch(policy: try policy(#"{"IsAdministrator":false,"EnableSubtitleManagement":false}"#), fetchers: fetchers))
    }

    func test_jellyfin_hidesTheRowWhenNoProviderIsInstalled() throws {
        let admin = try JellyfinJSON.decoder().decode(JFUserWithPolicy.self, from: Data(#"{"Policy":{"IsAdministrator":true}}"#.utf8)).policy
        XCTAssertFalse(JellyfinProvider.allowsSubtitleSearch(policy: admin, fetchers: []))
        XCTAssertTrue(JellyfinProvider.allowsSubtitleSearch(policy: admin, fetchers: nil))
    }

    func test_emby_unsetRightCountsAsAllowed() {
        var policy = EmbySession.Policy()
        let fetchers = [EmbyLibraryAvailableOptions.Fetcher(name: "Open Subtitles")]
        XCTAssertTrue(EmbyProvider.allowsSubtitleSearch(policy: policy, fetchers: fetchers))
        policy.enableSubtitleDownloading = false
        XCTAssertFalse(EmbyProvider.allowsSubtitleSearch(policy: policy, fetchers: fetchers))
        policy.isAdministrator = true
        XCTAssertTrue(EmbyProvider.allowsSubtitleSearch(policy: policy, fetchers: fetchers))
        XCTAssertFalse(EmbyProvider.allowsSubtitleSearch(policy: policy, fetchers: []))
    }
}
