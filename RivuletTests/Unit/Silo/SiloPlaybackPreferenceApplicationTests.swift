// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class SiloPlaybackPreferenceApplicationTests: XCTestCase {
    private func policy(quality: SiloResolvedPolicyValue<MediaQualityPreference> = .unavailable,
                        cap: SiloResolvedPolicyValue<Int> = .unavailable,
                        audio: SiloResolvedPolicyValue<String> = .unavailable,
                        language: SiloResolvedPolicyValue<String> = .unavailable,
                        mode: SiloResolvedPolicyValue<SiloLocalSubtitleMode> = .unavailable,
                        forced: SiloResolvedPolicyValue<Bool> = .unavailable,
                        buffering: SiloResolvedPolicyValue<BufferingQualityPolicy> = .unavailable) -> SiloResolvedPlaybackPolicy {
        .init(followsSilo: false, quality: quality, maxBitrateKbps: cap, audioLanguage: audio,
              subtitleLanguage: language, subtitleMode: mode, showForcedSubtitles: forced,
              bufferingPolicy: buffering)
    }

    func testIndependentQualityCapAndNativeNever() throws {
        let application = try SiloPlaybackPolicyApplication(policy: policy(
            quality: .value(.offered(id: "opaque-quality")), cap: .value(8_000), buffering: .value(.never)))
        XCTAssertEqual(application.quality, .offered(id: "opaque-quality"))
        XCTAssertEqual(application.maxBitrate, 8_000_000)
        XCTAssertTrue(application.ignoreLearnedLimit)
        XCTAssertThrowsError(try SiloPlaybackPolicyApplication(policy: policy(cap: .value(Int.max))))
        XCTAssertEqual(SiloPlaybackRestoreIntent.quality(original: .offered(id: "opaque-quality"),
                                                         current: .automatic), .offered(id: "opaque-quality"))
    }

    func testAudioLanguageUsesActualVersionIndicesAndUnavailableKeepsServerPick() throws {
        let version = try XCTUnwrap(watch().versions?.first)
        XCTAssertEqual(try SiloPlaybackPolicyApplication(policy: policy(audio: .value("eng"))).audioIndex(in: version), 1)
        XCTAssertNil(try SiloPlaybackPolicyApplication(policy: policy(audio: .value("de"))).audioIndex(in: version))
        XCTAssertNil(try SiloPlaybackPolicyApplication(policy: policy(audio: .clear)).audioIndex(in: version))
    }

    func testExplicitOffAndLocalLanguageBeatFollowedAlwaysAndSignature() throws {
        let item = try watch()
        let version = try XCTUnwrap(item.versions?.first)
        let playbackPlan = try plan()
        let followed = try SiloPlaybackPolicyApplication(policy: policy(
            language: .value("fr"), mode: .value(.always)))
        XCTAssertEqual(try SiloInitialSubtitleSelection.resolve(watch: item, version: version,
            plan: playbackPlan, explicitIndex: nil, policy: followed),
            .track(.init(id: "track:french", index: 9)))
        XCTAssertEqual(try SiloInitialSubtitleSelection.resolve(watch: item, version: version,
            plan: playbackPlan, explicitIndex: -1, policy: followed), .off)
    }

    func testClearStopsInheritedAxisWhileUnavailablePreservesNativeSignature() throws {
        let item = try watch()
        let version = try XCTUnwrap(item.versions?.first)
        let playbackPlan = try plan()
        let unavailable = try SiloPlaybackPolicyApplication(policy: policy())
        XCTAssertEqual(try SiloInitialSubtitleSelection.resolve(watch: item, version: version,
            plan: playbackPlan, explicitIndex: nil, policy: unavailable),
            .track(.init(id: "track:english", index: 7)))
        let cleared = try SiloPlaybackPolicyApplication(policy: policy(language: .clear, mode: .clear))
        XCTAssertEqual(try SiloInitialSubtitleSelection.resolve(watch: item, version: version,
            plan: playbackPlan, explicitIndex: nil, policy: cleared),
            .track(.init(id: "track:english", index: 7)))
        let offWatch = try watch(mode: "off", signature: false)
        let offVersion = try XCTUnwrap(offWatch.versions?.first)
        XCTAssertEqual(try SiloInitialSubtitleSelection.resolve(watch: offWatch, version: offVersion,
            plan: playbackPlan, explicitIndex: nil, policy: unavailable), .off)
        XCTAssertEqual(try SiloInitialSubtitleSelection.resolve(watch: offWatch, version: offVersion,
            plan: playbackPlan, explicitIndex: nil, policy: cleared), .leavePlan)
    }

    private func watch(mode: String = "always", signature: Bool = true) throws -> SiloItem {
        let saved = signature ? #", "effective_subtitle_track_signature":{"language":"eng","codec":"ass","forced":false,"hearing_impaired":false,"source":"embedded","label":"English dialogue"}"# : ""
        let json = """
        {"content_id":"synthetic-title","title":"Synthetic","effective_subtitle_mode":"\(mode)",
         "effective_subtitle_language":"eng","effective_show_forced_subtitles":false\(saved),
         "versions":[{"file_id":"file-a","resolution":"1080p","codec_video":"hevc",
           "codec_audio":"aac","hdr":false,"container":"mkv","file_size":1000,"bitrate":4000,
           "audio_tracks":[{"language":"ja","default":true},{"language":"en","default":false}]}]}
        """
        return try SiloJSON.decoder().decode(SiloItem.self, from: Data(json.utf8))
    }

    private func plan() throws -> SiloPlaybackPlan {
        let json = """
        {"protocol_version":3,"plan_id":"plan-a","plan_attempt_key":"opaque-attempt",
         "session_id":"session-a","delivery":"original_http","effective_media_file_id":"file-a",
         "stream":{"url":"/api/v2/stream/session-a","protocol":"http_progressive","headers":{},
           "header_refresh":"none","container":"mkv"},
         "timeline":{"source_start_seconds":0,"stream_origin_seconds":0,"player_start_seconds":0,
           "timeline_offset_seconds":0,"can_seek_anywhere":true,"seek_restoration":"player_position"},
         "source":{"media_file_id":"file-a","duration_seconds":60},"selected_tracks":{},
         "subtitle":{"mode":"off","inventory":[
           {"track_id":"track:english","combined_index":7,"source":"embedded","codec":"ass",
            "language":"en","label":"English dialogue","forced":false,"default":false,
            "hearing_impaired":false,"delivery":"sidecar","url":"/api/v2/subtitles/7.ass"},
           {"track_id":"track:french","combined_index":9,"source":"embedded","codec":"ass",
            "language":"fr","label":"French","forced":false,"default":true,
            "hearing_impaired":false,"delivery":"sidecar","url":"/api/v2/subtitles/9.ass"}]}}
        """
        return try SiloJSON.decoder().decode(SiloPlaybackPlan.self, from: Data(json.utf8))
    }
}
