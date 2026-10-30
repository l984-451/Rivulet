// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class SiloAutomaticSubtitleTests: XCTestCase {
    func test_profileAlwaysSelectsLanguageBeforeFirstStreamAndExplicitOffWins() throws {
        let plan = try makePlan()
        let watch = try makeWatch(mode: "always", language: "eng")
        let version = try XCTUnwrap(watch.versions?.first)
        let selected = try SiloInitialSubtitleSelection.resolve(watch: watch, version: version,
                                                                 plan: plan, explicitIndex: nil)
        XCTAssertEqual(selected, .track(SiloTrackIdentity(id: "opaque:english", index: 7)))
        XCTAssertTrue(selected.differs(from: plan))
        XCTAssertEqual(try SiloInitialSubtitleSelection.resolve(watch: watch, version: version,
                                                                 plan: plan, explicitIndex: -1), .off)
    }

    func test_effectiveSeriesOffBeatsBroaderAlwaysAndSavedSignature() throws {
        let plan = try makePlan()
        let watch = try makeWatch(mode: "off", language: "en", signature: true)
        let version = try XCTUnwrap(watch.versions?.first)
        XCTAssertEqual(try SiloInitialSubtitleSelection.resolve(watch: watch, version: version,
                                                                 plan: plan, explicitIndex: nil), .off)
    }

    func test_signatureUsesAuthoritativeOpaqueIdentityAndNotCatalogOrdinal() throws {
        let plan = try makePlan()
        let watch = try makeWatch(mode: "auto", language: "fr", signature: true)
        let version = try XCTUnwrap(watch.versions?.first)
        XCTAssertEqual(try SiloInitialSubtitleSelection.resolve(watch: watch, version: version,
                                                                 plan: plan, explicitIndex: nil),
                       .track(SiloTrackIdentity(id: "opaque:english", index: 7)))
        XCTAssertThrowsError(try SiloInitialSubtitleSelection.resolve(watch: watch, version: version,
                                                                      plan: plan, explicitIndex: 1))
    }

    private func makeWatch(mode: String, language: String, signature: Bool = false) throws -> SiloItem {
        let saved = signature ? #", "effective_subtitle_track_signature":{"language":"eng","codec":"ass","forced":false,"hearing_impaired":false,"source":"embedded","label":"English dialogue"}"# : ""
        let json = """
        {"content_id":"movie-a","title":"Synthetic", "effective_subtitle_mode":"\(mode)",
         "effective_subtitle_language":"\(language)","effective_show_forced_subtitles":false\(saved),
         "versions":[{"file_id":"file-a","resolution":"1080p","codec_video":"hevc",
          "codec_audio":"aac","hdr":false,"container":"mkv","file_size":1000,"bitrate":4000,
          "audio_tracks":[{"language":"ja","default":true}],
          "subtitle_tracks":[{"index":11,"codec":"ass","language":"en","title":"English dialogue",
                              "external":false,"forced":false,"default":false,"hearing_impaired":false}]}]}
        """
        return try SiloJSON.decoder().decode(SiloItem.self, from: Data(json.utf8))
    }

    private func makePlan() throws -> SiloPlaybackPlan {
        let json = """
        {"protocol_version":3,"plan_id":"plan-a","plan_attempt_key":"opaque-attempt",
         "session_id":"session-a","delivery":"original_http","effective_media_file_id":"file-a",
         "stream":{"url":"/api/v2/stream/session-a","protocol":"http_progressive","headers":{},
                   "header_refresh":"none","container":"mkv"},
         "timeline":{"source_start_seconds":0,"stream_origin_seconds":0,"player_start_seconds":0,
                     "timeline_offset_seconds":0,"can_seek_anywhere":true,"seek_restoration":"player_position"},
         "source":{"media_file_id":"file-a","duration_seconds":60},"selected_tracks":{},
         "subtitle":{"mode":"off","inventory":[
            {"track_id":"opaque:default","combined_index":3,"source":"embedded","codec":"ass",
             "language":"fr","label":"French","forced":false,"default":true,
             "hearing_impaired":false,"delivery":"sidecar","url":"/api/v2/subtitles/3.ass"},
            {"track_id":"opaque:english","combined_index":7,"source":"embedded","codec":"ass",
             "language":"en","label":"English dialogue","forced":false,"default":false,
             "hearing_impaired":false,"delivery":"sidecar","url":"/api/v2/subtitles/7.ass"}]}}
        """
        return try SiloJSON.decoder().decode(SiloPlaybackPlan.self, from: Data(json.utf8))
    }
}
