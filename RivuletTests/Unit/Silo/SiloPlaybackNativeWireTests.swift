// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class SiloPlaybackNativeWireTests: XCTestCase {
    func testNativeDecisionPreservesNumericFileIdentityForCatalogSelection() throws {
        let decision = try decode(effectiveID: "42", sourceID: "42")
        let plan = try XCTUnwrap(decision.playbackPlan)
        XCTAssertEqual(plan.effectiveMediaFileId, "42")
        XCTAssertEqual(plan.source.mediaFileId, "42")
        XCTAssertEqual(plan.source.durationSeconds, 7200)
        XCTAssertEqual(plan.selectedTracks.audio?.id, "file:42:audio:0")
        XCTAssertEqual(plan.subtitle.inventory.first?.trackId, "file:42:subtitle:1")
        XCTAssertEqual(plan.stream.url, "/stream/session-a")
    }

    func testExistingStringFileIdentitiesRemainOpaque() throws {
        let plan = try XCTUnwrap(decode(effectiveID: "\"file-a\"", sourceID: "\"file-a\"").playbackPlan)
        XCTAssertEqual(plan.effectiveMediaFileId, "file-a")
        XCTAssertEqual(plan.source.mediaFileId, "file-a")
        let numericString = try XCTUnwrap(decode(effectiveID: "\"42\"", sourceID: "\"42\"").playbackPlan)
        XCTAssertEqual(numericString.effectiveMediaFileId, "42")
        XCTAssertEqual(numericString.source.mediaFileId, "42")
    }

    func testMalformedFileIdentitiesAreRejected() {
        for invalid in ["null", "0", "-1", "42.5", "true", "\"\"", "\"   \"", "{}"] {
            XCTAssertThrowsError(try decode(effectiveID: invalid, sourceID: "42"), "effective: \(invalid)")
            XCTAssertThrowsError(try decode(effectiveID: "42", sourceID: invalid), "source: \(invalid)")
        }
    }

    private func decode(effectiveID: String, sourceID: String) throws -> SiloPlaybackDecision {
        // Mirrors the native v3 golden decision's nested plan, source, timeline,
        // selected tracks and subtitle inventory with synthetic session values.
        let json = """
        {
          "protocol_version":3,"outcome":"playable","session_id":"session-a",
          "server_features":["playback_plan_v3","plan_source_duration_v1"],
          "playback_plan":{
            "protocol_version":3,"plan_id":"plan-a","plan_attempt_key":"attempt-a",
            "session_id":"session-a","delivery":"original_http",
            "stream":{"url":"/stream/session-a","protocol":"http_progressive",
                      "container":"mp4","headers":{},"header_refresh":"none"},
            "timeline":{"source_start_seconds":12.5,"stream_origin_seconds":0,
                        "player_start_seconds":12.5,"timeline_offset_seconds":0,
                        "can_seek_anywhere":true,"seek_restoration":"player_position"},
            "selected_tracks":{"audio":{"id":"file:42:audio:0","index":0},
                               "subtitle":{"id":"file:42:subtitle:1","index":1}},
            "subtitle":{"mode":"render","track_id":"file:42:subtitle:1",
                        "embedded":{"stream_index":3,"container_track_id":"4"},
                        "inventory":[{"track_id":"file:42:subtitle:1","combined_index":1,
                                      "source":"embedded","codec":"mov_text","forced":false,
                                      "default":false,"hearing_impaired":false,"delivery":"sidecar"}]},
            "effective_media_file_id":\(effectiveID),
            "source":{"media_file_id":\(sourceID),"duration_seconds":7200}
          }
        }
        """
        return try SiloJSON.decoder().decode(SiloPlaybackDecision.self, from: Data(json.utf8))
    }
}
