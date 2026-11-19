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

    /// Bodies measured on PMS 1.43.5 for the wildcard direct-play decision (#677).
    func test_directPlayDecision_refusedOnlyWhenTheCodeIsNot1000() {
        let allowed = #"{"MediaContainer":{"directPlayDecisionCode":1000,"generalDecisionCode":1000}}"#
        let refused = #"{"MediaContainer":{"directPlayDecisionCode":3000,"generalDecisionCode":2000,"transcodeDecisionCode":4005}}"#
        XCTAssertFalse(PlexNetworkManager.refusesDirectPlay(Data(allowed.utf8)))
        XCTAssertTrue(PlexNetworkManager.refusesDirectPlay(Data(refused.utf8)))
        // No verdict is not a refusal: the file is tried as before.
        XCTAssertFalse(PlexNetworkManager.refusesDirectPlay(Data("<MediaContainer/>".utf8)))
        XCTAssertFalse(PlexNetworkManager.refusesDirectPlay(Data(#"{"MediaContainer":{}}"#.utf8)))
    }

    /// Measured on PMS 1.43.5 with a 2 Mbps remote stream limit: the direct-play code still says 1000.
    private let refusedForBandwidth = #"{"MediaContainer":{"size":0,"directPlayDecisionCode":1000,"directPlayDecisionText":"Direct play OK.","generalDecisionCode":2000,"generalDecisionText":"Neither direct play nor conversion is available.","transcodeDecisionCode":4005}}"#
    private let refusedForAudioTrack = #"{"MediaContainer":{"directPlayDecisionCode":3000,"directPlayDecisionText":"App cannot direct play this item. Selected audio stream is not the first audio stream and app cannot select audio streams in direct play.","generalDecisionCode":2000,"transcodeDecisionCode":4005}}"#

    func test_directPlayDecision_aRemoteLimitIsReadFromTheGeneralCode() {
        XCTAssertTrue(PlexNetworkManager.refusesDirectPlay(Data(refusedForBandwidth.utf8)))
    }

    func test_directPlayDecisionText_isTheServersReason() {
        XCTAssertEqual(PlexNetworkManager.directPlayDecisionText(Data(refusedForAudioTrack.utf8)),
                       "App cannot direct play this item. Selected audio stream is not the first audio stream and app cannot select audio streams in direct play.")
        XCTAssertEqual(PlexNetworkManager.directPlayDecisionText(Data(refusedForBandwidth.utf8)),
                       "Neither direct play nor conversion is available.")
        XCTAssertNil(PlexNetworkManager.directPlayDecisionText(Data("<MediaContainer/>".utf8)))
    }

    func test_directPlayRefusedNotice_namesTheStep_orTheServersBest() {
        XCTAssertEqual(ServerRefusal.directPlayRefusedNotice(convertingTo: nil).title, "Server Is Converting")
        XCTAssertTrue(ServerRefusal.directPlayRefusedNotice(convertingTo: nil).detail?.contains("best quality it allows") == true)
        // The step's label stays on one line.
        XCTAssertTrue(ServerRefusal.directPlayRefusedNotice(convertingTo: QualityStep.ladder[0]).detail?
            .contains("20\u{00A0}Mbps\u{00A0}1080p") == true)
        XCTAssertFalse(ServerRefusal(reason: .directPlayRefused).blocksTranscode)
    }

    func test_shown_prefersABlockingDecision_thenTheMissingFile_onlyAfterAFailure() {
        let blocking = ServerRefusal(reason: .plexPassRequired)
        let soft = ServerRefusal(reason: .other("x"))
        XCTAssertEqual(ServerRefusal.shown(decision: blocking, fileIsMissing: true, failed: false), blocking)
        XCTAssertEqual(ServerRefusal.shown(decision: nil, fileIsMissing: true, failed: true)?.reason, .fileMissing)
        XCTAssertEqual(ServerRefusal.shown(decision: soft, fileIsMissing: true, failed: true)?.reason, .fileMissing)
        XCTAssertEqual(ServerRefusal.shown(decision: soft, fileIsMissing: false, failed: true), soft)
        // A flag alone never stops a file that plays: nothing is shown without a failure.
        XCTAssertNil(ServerRefusal.shown(decision: nil, fileIsMissing: true, failed: false))
        XCTAssertNil(ServerRefusal.shown(decision: soft, fileIsMissing: false, failed: false))
    }
}
