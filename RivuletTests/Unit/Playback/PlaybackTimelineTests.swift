// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class PlaybackTimelineTests: XCTestCase {
    private var sent: [String] = []
    private var position: TimeInterval = 0
    /// The server's reply to the next report: its reason when it has ended the session.
    private var termination: String?
    private var terminated: [String] = []

    private func makeTimeline(interval: TimeInterval = 10) -> PlaybackTimeline {
        let timeline = PlaybackTimeline(interval: interval, position: { [unowned self] in position }) { [unowned self] state, time in
            sent.append("\(state.rawValue)@\(Int(time))")
            let reply = termination
            return { reply }
        }
        timeline.onTerminated = { [unowned self] in terminated.append($0) }
        return timeline
    }

    /// Lets the report tasks run.
    private func settle() async {
        for _ in 0..<5 { await Task.yield() }
    }

    // #433: the engine holds paused while loading; a session must open with playing.
    func testPausedBeforePlayingIsNotSent() {
        let timeline = makeTimeline()
        timeline.transportChanged(.paused)
        timeline.tick(30)
        XCTAssertEqual(sent, [])
    }

    func testPlayingThenPausedSends() {
        let timeline = makeTimeline()
        position = 5
        timeline.transportChanged(.playing)
        timeline.transportChanged(.paused)
        XCTAssertEqual(sent, ["playing@5", "paused@5"])
    }

    func testTicksReportOncePerInterval() {
        let timeline = makeTimeline()
        timeline.transportChanged(.playing)
        for time in stride(from: 0.5, through: 25, by: 0.5) { timeline.tick(time) }
        XCTAssertEqual(sent, ["playing@0", "playing@10", "playing@20"])
    }

    func testSeekWhilePausedReports() {
        let timeline = makeTimeline()
        timeline.transportChanged(.playing)
        timeline.transportChanged(.paused)
        timeline.tick(600)
        XCTAssertEqual(sent.last, "paused@600")
    }

    func testTicksIgnoredWhileBuffering() {
        let timeline = makeTimeline()
        timeline.transportChanged(.playing)
        timeline.transportChanged(.other)
        timeline.tick(40)
        XCTAssertEqual(sent, ["playing@0"])
    }

    func testStopSendsOnce() {
        let timeline = makeTimeline()
        timeline.transportChanged(.playing)
        XCTAssertNotNil(timeline.stop(at: 100))
        XCTAssertNil(timeline.stop(at: 100))
        timeline.tick(120)
        XCTAssertEqual(sent, ["playing@0", "stopped@100"])
    }

    func testPlayingAfterStopReopens() {
        let timeline = makeTimeline()
        timeline.transportChanged(.playing)
        timeline.stop(at: 100)
        position = 90
        timeline.transportChanged(.playing)
        XCTAssertEqual(sent.last, "playing@90")
        XCTAssertFalse(timeline.isStopped)
    }

    // #605: once the server ends the session, the player's zeroed clock must never reach it.
    func testServerTerminationGoesQuiet() async {
        let timeline = makeTimeline()
        timeline.transportChanged(.playing)
        position = 1052
        termination = "Playback has been paused for too long."
        timeline.transportChanged(.paused)
        await settle()
        XCTAssertEqual(terminated, ["Playback has been paused for too long."])
        XCTAssertTrue(timeline.isStopped)

        position = 0
        timeline.tick(0)
        XCTAssertNil(timeline.stop(at: 0))
        XCTAssertEqual(sent, ["playing@0", "paused@1052"])
    }

    func testTerminationFromThePreviousItemIsIgnored() async {
        let timeline = makeTimeline()
        termination = "stopped"
        timeline.transportChanged(.playing)
        timeline.begin()
        await settle()
        XCTAssertEqual(terminated, [])
        XCTAssertFalse(timeline.isStopped)
    }

    func testBeginReopensAndRequiresPlayingFirst() {
        let timeline = makeTimeline()
        timeline.transportChanged(.playing)
        timeline.stop(at: 50)
        timeline.begin()
        timeline.transportChanged(.paused)
        XCTAssertEqual(sent, ["playing@0", "stopped@50"])
        timeline.transportChanged(.playing)
        XCTAssertEqual(sent.last, "playing@0")
    }

    // #403: the server only ends a paused session it keeps hearing about.
    func testPausedRepeatsUntilPlaying() async throws {
        let timeline = makeTimeline(interval: 0.05)
        timeline.transportChanged(.playing)
        timeline.transportChanged(.paused)
        try await Task.sleep(for: .milliseconds(180))
        timeline.transportChanged(.playing)
        let count = sent.filter { $0.hasPrefix("paused") }.count
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertGreaterThanOrEqual(count, 3)
        XCTAssertEqual(sent.filter { $0.hasPrefix("paused") }.count, count)
    }
}
