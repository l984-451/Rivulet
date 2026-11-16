// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class ServerRefusalTests: XCTestCase {
    private func decision(_ general: Int, _ text: String, transcode: Int? = nil) -> PlexTranscodeDecision? {
        let transcodeField = transcode.map { #","transcodeDecisionCode":\#($0)"# } ?? ""
        let json = #"{"MediaContainer":{"generalDecisionCode":\#(general),"generalDecisionText":"\#(text)"\#(transcodeField)}}"#
        return PlexNetworkManager.transcodeDecision(in: Data(json.utf8))
    }

    /// Measured: a relay user without Plex Pass got 2013 with the server's own text, then start.m3u8 answered 200.
    func test_2013_isPlexPassRequired_andBlocksTheTranscode() throws {
        let refusal = try XCTUnwrap(decision(2013, "Remote playback requires a Remote Watch Pass or Plex Pass.")?.refusal)
        XCTAssertEqual(refusal.reason, .plexPassRequired)
        XCTAssertTrue(refusal.blocksTranscode)
        XCTAssertTrue(refusal.message.contains("Plex Pass"))
    }

    func test_2000_andNoConversionProfile_cannotConvert() throws {
        XCTAssertEqual(decision(2000, "Neither direct play nor conversion is available.", transcode: 4005)?.refusal?.reason, .cannotConvert)
        XCTAssertEqual(ServerRefusal.decision(general: 2001, generalText: nil, transcode: 4005, transcodeText: nil)?.reason, .cannotConvert)
    }

    func test_playableDecisions_andOurOwnMalformedRequest_areNotRefusals() {
        XCTAssertNil(decision(1000, "Direct play OK.")?.refusal)
        XCTAssertNil(decision(1001, "Direct play not available; Conversion OK.", transcode: 1001)?.refusal)
        XCTAssertNil(decision(2004, "Could not construct decision request")?.refusal)
        XCTAssertNil(PlexNetworkManager.transcodeDecision(in: Data("<html>400 Bad Request</html>".utf8)))
    }

    func test_otherDecisionError_carriesTheServersSentence_andStillStartsTheTranscode() throws {
        let refusal = try XCTUnwrap(decision(2010, "Too many streams.")?.refusal)
        XCTAssertEqual(refusal.reason, .other("Too many streams."))
        XCTAssertFalse(refusal.blocksTranscode)
        XCTAssertTrue(refusal.message.contains("Too many streams."))
        XCTAssertEqual(ServerRefusal(reason: .other(nil)).message, ServerRefusal(reason: .other("")).message)
    }

    func test_providerSignals() {
        XCTAssertEqual(ServerRefusal(playbackErrorCode: "NotAllowed")?.reason, .notAllowed)
        XCTAssertEqual(ServerRefusal(playbackErrorCode: "RateLimitExceeded")?.reason, .streamLimit)
        XCTAssertNil(ServerRefusal(playbackErrorCode: "NoCompatibleStream"))
        XCTAssertNil(ServerRefusal(playbackErrorCode: nil))
        XCTAssertEqual(ServerRefusal(error: MediaProviderError.transcodeRequired)?.reason, .cannotStream)
        XCTAssertNil(ServerRefusal(error: MediaProviderError.unreachable))
    }

    func test_playbackFailureMessage_isTheRefusalsText() {
        let refusal = ServerRefusal(reason: .fileMissing)
        XCTAssertEqual(PlaybackFailure.message(for: refusal), refusal.message)
    }

    func test_serverRefusals_areNotCapturedAsErrors() {
        XCTAssertTrue(PlaybackDiagnostics.isServerRefusal(PlayerError.serverRefused("x")))
        XCTAssertTrue(PlaybackDiagnostics.isServerRefusal(MediaProviderError.transcodeRequired))
        XCTAssertFalse(PlaybackDiagnostics.isServerRefusal(PlayerError.loadFailed("x")))
    }
}
