// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class ProgressReportThrottleTests: XCTestCase {
    private func shouldReport(state: String,
                              time: TimeInterval,
                              lastState: String?,
                              lastTime: TimeInterval?,
                              force: Bool = false) -> Bool {
        PlexProgressReporter.shouldReport(state: state,
                                          time: time,
                                          lastState: lastState,
                                          lastTime: lastTime,
                                          force: force)
    }

    func testFirstReportAlwaysSends() {
        XCTAssertTrue(shouldReport(state: "playing", time: 0, lastState: nil, lastTime: nil))
    }

    func testSameStateWithinThrottleIsDropped() {
        XCTAssertFalse(shouldReport(state: "playing", time: 12, lastState: "playing", lastTime: 10))
    }

    func testSameStatePastThrottleSends() {
        XCTAssertTrue(shouldReport(state: "playing", time: 15, lastState: "playing", lastTime: 10))
    }

    // Pausing freezes playback time, so the paused report carries the same
    // position as the playing report before it. It must still reach the server.
    func testPauseAtSamePositionSends() {
        XCTAssertTrue(shouldReport(state: "paused", time: 10, lastState: "playing", lastTime: 10))
    }

    // The episode-transition "stopped" report lands seconds after the last
    // periodic one (UniversalPlayerViewModel.markCurrentAsWatched).
    func testStopShortlyAfterPlayingSends() {
        XCTAssertTrue(shouldReport(state: "stopped", time: 1201, lastState: "playing", lastTime: 1200))
    }

    // Plex turns a session's first report into its webhook: paused first sends
    // media.pause with no media.play (#433).
    func testPauseBeforePlayingIsDropped() {
        XCTAssertFalse(shouldReport(state: "paused", time: 0, lastState: nil, lastTime: nil, force: true))
        XCTAssertFalse(shouldReport(state: "paused", time: 0, lastState: "stopped", lastTime: 1200, force: true))
    }

    func testForceBypassesThrottle() {
        XCTAssertTrue(shouldReport(state: "playing", time: 10, lastState: "playing", lastTime: 10, force: true))
    }
}

final class TimelineTerminationTests: XCTestCase {
    private func text(_ json: String) -> String? {
        PlexNetworkManager.timelineTermination(in: Data(json.utf8))
    }

    func testPlainReplyIsNotATermination() {
        XCTAssertNil(text(#"{"MediaContainer":{"size":1,"playbackState":"ignore","skipCount":1,"viewCount":2,"viewOffset":70200}}"#))
        XCTAssertNil(text(""))
    }

    // PMS 1.43.5's reply after a dashboard Stop.
    func testTerminationCarriesServerReason() {
        let reply = #"{"MediaContainer":{"size":1,"playbackState":"ignore","skipCount":1,"terminationCode":2006,"terminationText":"\"l984_451\" asked to stop your playback from this server: Bedtime","viewCount":2,"viewOffset":70200}}"#
        XCTAssertEqual(text(reply), #""l984_451" asked to stop your playback from this server: Bedtime"#)
    }

    func testCodeWithoutTextStillTerminates() {
        XCTAssertNotNil(text(#"{"MediaContainer":{"terminationCode":2006}}"#))
    }
}
