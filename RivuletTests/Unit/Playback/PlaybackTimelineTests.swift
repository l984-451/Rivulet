// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Testing
import XCTest
@testable import Rivulet

@MainActor
final class PlaybackTimelineTests: XCTestCase {
    private let reports = PlaybackReportQueue()
    private var sent: [String] = []
    private var position: TimeInterval = 0
    /// The server's reply to the next report: its reason when it has ended the session.
    private var termination: String?
    private var terminated: [String] = []

    private func makeTimeline(interval: TimeInterval = 10) -> PlaybackTimeline {
        let timeline = PlaybackTimeline(interval: interval, reports: reports, position: { [unowned self] in position }) { [unowned self] state, time in
            sent.append("\(state.rawValue)@\(Int(time))")
            let reply = termination
            return { reply }
        }
        timeline.onTerminated = { [unowned self] in terminated.append($0) }
        return timeline
    }

    /// Lets the report tasks run.
    private func settle() async {
        await reports.tail?.value
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

    func testBufferingRequiresPlayingAndKeepsItsStateOnForcedSeek() async {
        let timeline = makeTimeline()
        timeline.transportChanged(.buffering)
        timeline.tick(12, force: true)
        XCTAssertTrue(sent.isEmpty)
        timeline.transportChanged(.playing)
        position = 42
        timeline.transportChanged(.buffering)
        timeline.tick(43, force: true)
        await timeline.stop(at: 43)?.value
        XCTAssertEqual(sent, ["playing@0", "buffering@42", "buffering@43", "stopped@43"])
    }

    func testRepeatedTransportNotificationsDoNotDuplicateReportsButSeekingDoes() async {
        let timeline = makeTimeline()
        timeline.transportChanged(.playing)
        timeline.transportChanged(.playing)
        position = 2
        timeline.transportChanged(.playing)
        timeline.transportChanged(.buffering)
        timeline.transportChanged(.buffering)
        timeline.transportChanged(.paused)
        timeline.transportChanged(.paused)
        await timeline.stop(at: 2)?.value
        XCTAssertEqual(sent, ["playing@0", "playing@2", "buffering@2", "paused@2", "stopped@2"])
    }

    func testStopAndWatchedWaitForPendingProgressBeforeIncomingSession() async {
        let arrived = expectation(description: "outgoing progress held")
        var release: CheckedContinuation<Void, Never>?
        var delivered: [String] = []
        var item = "first"
        let timeline = PlaybackTimeline(reports: reports, position: { 42 }) { state, _ in
            let captured = item
            return {
                if captured == "first", state == .playing {
                    await withCheckedContinuation { release = $0; arrived.fulfill() }
                }
                delivered.append("\(captured):\(state.rawValue)")
                return nil
            }
        }
        timeline.transportChanged(.playing)
        await fulfillment(of: [arrived], timeout: 1)
        timeline.stop(at: 95)
        reports.enqueue { delivered.append("first:watched") }
        item = "second"
        timeline.begin()
        timeline.transportChanged(.playing)
        XCTAssertTrue(delivered.isEmpty)
        release?.resume()
        await reports.tail?.value
        XCTAssertEqual(delivered, ["first:playing", "first:stopped", "first:watched", "second:playing"])
    }

}

@MainActor
struct PlaybackTimelineTerminationTests {
    @Test(arguments: [false, true])
    func terminationRevokesQueuedWritesWithoutRevokingTheNextItem(_ advances: Bool) async {
        let reports = PlaybackReportQueue()
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish(); release.continuation.finish() }
        var delivered: [String] = []
        var item = "first"
        let timeline = PlaybackTimeline(reports: reports, position: { 1 }) { state, time in
            let label = "\(item):\(state.rawValue)@\(Int(time))"
            return {
                delivered.append(label)
                if label == "first:playing@1" {
                    entered.continuation.yield(())
                    for await _ in release.stream { break }
                    return "Stopped by server"
                }
                return nil
            }
        }
        timeline.transportChanged(.playing)
        for await _ in entered.stream { break }
        timeline.tick(10)
        timeline.tick(20)
        timeline.stop(at: 30)
        reports.enqueue { delivered.append("first:watched") }
        if advances {
            item = "second"
            timeline.begin()
            timeline.transportChanged(.playing)
        }
        release.continuation.yield(())
        await reports.tail?.value
        #expect(delivered == ["first:playing@1"] + (advances ? ["second:playing@1"] : []))
        #expect(timeline.isStopped == !advances)
    }
}
