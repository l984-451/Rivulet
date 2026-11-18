// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// Fixtures trimmed from PMS 1.43.5 replies for a Dolby Vision MKV under a 4 Mbps remote limit (#677).
final class TranscodeStartWatchTests: XCTestCase {
    func test_decisionVerdict_saysWhetherTheSessionCopiesOrConverts() {
        let json = #"""
        {"MediaContainer":{"generalDecisionCode":1001,"generalDecisionText":"Direct play not available; Conversion OK.",
         "transcodeDecisionCode":1001,"Metadata":[{"Media":[{"videoResolution":"720p","Part":[{"Stream":[
         {"streamType":1,"codec":"h264","decision":"transcode"},{"streamType":2,"codec":"aac","decision":"transcode"}]}]}]}]}}
        """#
        XCTAssertEqual(PlexNetworkManager.transcodeVerdict(in: Data(json.utf8)),
                       "general=1001 transcode=1001: Direct play not available; Conversion OK."
                       + " [video transcode h264 720p, audio transcode aac]")
    }

    private let sessions = #"""
    {"MediaContainer":{"size":2,"TranscodeSession":[
     {"key":"BEHIND-1","throttled":false,"speed":0.4,"videoDecision":"transcode","audioDecision":"transcode",
      "videoCodec":"h264","transcodeHwRequested":false},
     {"key":"AHEAD-2","throttled":true,"speed":0.0,"videoDecision":"copy","audioDecision":"copy","videoCodec":"hevc"}]}}
    """#

    func test_status_isFoundBySession_andSaysWhenTheServerIsBehind() throws {
        let behind = try XCTUnwrap(PlexNetworkManager.transcodeStatus(in: Data(sessions.utf8), sessionId: "BEHIND-1"))
        XCTAssertTrue(behind.isBehind)
        XCTAssertEqual(behind.summary, "video=transcode h264 audio=transcode speed=0.4x throttled=false hw=false")
        XCTAssertTrue(TranscodeStartWatch.notice(for: behind).detail?.contains("0.4") == true)

        // Throttled reports speed 0: it is ahead, so the wait is the network's.
        let ahead = try XCTUnwrap(PlexNetworkManager.transcodeStatus(in: Data(sessions.utf8), sessionId: "AHEAD-2"))
        XCTAssertFalse(ahead.isBehind)
        XCTAssertNotEqual(TranscodeStartWatch.notice(for: ahead), TranscodeStartWatch.notice(for: behind))

        XCTAssertNil(PlexNetworkManager.transcodeStatus(in: Data(sessions.utf8), sessionId: "GONE"))
        XCTAssertNotEqual(TranscodeStartWatch.notice(for: nil), TranscodeStartWatch.notice(for: ahead))
    }
}
