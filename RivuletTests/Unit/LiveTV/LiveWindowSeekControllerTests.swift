// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class LiveWindowSeekControllerTests: XCTestCase {

    /// A stand-in player: a 30-minute window ending at 2_000, playing at the edge.
    @MainActor
    private final class FakePlayer {
        var window: LiveSeekableWindow? = LiveSeekableWindow(lowerBound: 200, upperBound: 2_000)
        var position: TimeInterval = 2_000
        var seeks: [TimeInterval] = []
        var edgeSeeks = 0
        var plays = 0
        var paused = false
        var seekDelay: Duration = .zero
        /// Where a seek leaves the playhead, when it lands on a new axis (a recording reload).
        var landsAt: TimeInterval?

        // Weak, as the app's own closures are: a seek still landing when a test
        // ends must not reach back into a freed fake.
        func makePlayer() -> LiveWindowSeekController.Player {
            .init(
                window: { [weak self] in self?.window },
                position: { [weak self] in self?.position ?? 0 },
                seek: { [weak self] target in
                    guard let self else { return }
                    self.seeks.append(target)
                    let delay = self.seekDelay
                    if delay > .zero { try? await Task.sleep(for: delay) }
                    self.position = self.landsAt ?? target
                },
                seekToLiveEdge: { [weak self] in
                    guard let self else { return }
                    self.edgeSeeks += 1
                    self.position = self.window?.upperBound ?? self.position
                },
                play: { [weak self] in self?.plays += 1 },
                isUserPaused: { [weak self] in self?.paused ?? false }
            )
        }
    }

    private func settle() async throws {
        try await Task.sleep(for: LiveWindowSeekController.commitDelay + .milliseconds(250))
    }

    func testPressesStackIntoOneSeek() async throws {
        let fake = FakePlayer()
        let controller = LiveWindowSeekController()
        controller.attach(fake.makePlayer())

        for _ in 0..<3 { controller.step(by: -10) }
        XCTAssertEqual(controller.pendingRequest, .position(1_970))
        XCTAssertEqual(controller.behindLiveSeconds(in: try XCTUnwrap(controller.window)), 30)

        try await settle()
        XCTAssertEqual(fake.seeks, [1_970])
        XCTAssertNil(controller.pendingRequest)
        XCTAssertEqual(fake.plays, 1)
        XCTAssertTrue(controller.isBehindLive(in: try XCTUnwrap(controller.window)))
    }

    func testSteppingBackToTheEdgeIsGoLive() async throws {
        let fake = FakePlayer()
        fake.position = 1_900
        let controller = LiveWindowSeekController()
        controller.attach(fake.makePlayer())

        controller.step(by: 200)
        XCTAssertEqual(controller.pendingRequest, .liveEdge)
        try await settle()
        XCTAssertEqual(fake.edgeSeeks, 1)
        XCTAssertEqual(fake.seeks, [])
        XCTAssertFalse(controller.isBehindLive(in: try XCTUnwrap(controller.window)))
    }

    /// Start from Beginning: the engine holds 200...2000 but the recording's head is 600 s on.
    func testReachLetsASkipPastTheWindowAndStopsAtTheHead() async throws {
        let fake = FakePlayer()
        let controller = LiveWindowSeekController()
        var player = fake.makePlayer()
        player.reach = { (0, 580) }
        controller.attach(player)

        controller.step(by: 300)
        XCTAssertEqual(controller.pendingRequest, .position(2_300))
        try await settle()
        XCTAssertEqual(fake.seeks, [2_300])

        controller.step(by: 600)
        XCTAssertEqual(controller.pendingRequest, .liveEdge)
    }

    func testReachGoesBackBeforeTheWindowOnlyAsFarAsItReaches() async throws {
        let fake = FakePlayer()
        fake.position = 210
        let controller = LiveWindowSeekController()
        var player = fake.makePlayer()
        player.reach = { (50, 0) }
        controller.attach(player)

        controller.step(by: -30)
        XCTAssertEqual(controller.pendingRequest, .position(180))
        controller.step(by: -100)
        XCTAssertEqual(controller.pendingRequest, .position(150))
    }

    func testSeekNeverResumesAPausedViewer() async throws {
        let fake = FakePlayer()
        fake.paused = true
        let controller = LiveWindowSeekController()
        controller.attach(fake.makePlayer())

        controller.step(by: -60)
        try await settle()
        XCTAssertEqual(fake.seeks, [1_940])
        XCTAssertEqual(fake.plays, 0)
    }

    func testOnlyOneSeekRunsAtATime() async throws {
        let fake = FakePlayer()
        // Lands at ~1.95s: the second press's commit (~1.15s) and the first
        // check (~1.4s) both fall while it is still in flight.
        fake.seekDelay = .milliseconds(1_500)
        let controller = LiveWindowSeekController()
        controller.attach(fake.makePlayer())

        controller.step(by: -10)
        try await settle()  // first seek is now landing
        controller.step(by: -10)
        try await settle()  // second commit fires while the first is in flight
        XCTAssertEqual(fake.seeks, [1_990])
        try await Task.sleep(for: .milliseconds(1_300))
        // The landing worker drained the newer target, measured from the press.
        XCTAssertEqual(fake.seeks, [1_990, 1_980])
    }

    func testPressesWhileASeekLandsApplyFromWhereItLanded() async throws {
        let fake = FakePlayer()
        fake.seekDelay = .milliseconds(800)
        // A recording reload: the seek lands at 300 on a new axis.
        fake.landsAt = 300
        let controller = LiveWindowSeekController()
        controller.attach(fake.makePlayer())

        controller.step(by: -100)
        try await settle()
        XCTAssertTrue(controller.isLanding)
        fake.window = LiveSeekableWindow(lowerBound: 10, upperBound: 400)
        controller.step(by: -10)
        controller.step(by: -10)
        try await Task.sleep(for: .milliseconds(800))
        fake.landsAt = nil
        try await settle()
        XCTAssertEqual(fake.seeks, [1_900, 280])
        XCTAssertEqual(fake.edgeSeeks, 0)
    }

    func testNoWindowCannotBeSeeked() {
        let fake = FakePlayer()
        fake.window = nil
        let controller = LiveWindowSeekController()
        controller.attach(fake.makePlayer())

        XCTAssertNil(controller.window)
        controller.step(by: -10)
        XCTAssertNil(controller.pendingRequest)
    }

    func testResetDropsAStagedSeek() async throws {
        let fake = FakePlayer()
        let controller = LiveWindowSeekController()
        controller.attach(fake.makePlayer())

        controller.step(by: -10)
        controller.cancelPending()
        XCTAssertNil(controller.pendingRequest)
        controller.step(by: -10)
        controller.reset()
        try await settle()
        XCTAssertEqual(fake.seeks, [])
        XCTAssertNil(controller.window)
    }

    func testResumePastTheWindowTailLandsInsideIt() async throws {
        let fake = FakePlayer()
        fake.position = 150
        let controller = LiveWindowSeekController()
        controller.attach(fake.makePlayer())

        controller.clampResumeIntoWindow()
        try await settle()
        XCTAssertEqual(fake.seeks, [206])
    }

    func testPauseCountsAsTimeShiftUntilBackAtTheEdge() throws {
        let fake = FakePlayer()
        let controller = LiveWindowSeekController()
        controller.attach(fake.makePlayer())
        let window = try XCTUnwrap(controller.window)

        fake.paused = true
        controller.notePaused()
        fake.position = 1_990
        XCTAssertTrue(controller.isBehindLive(in: window))
        fake.paused = false
        fake.position = 1_999
        XCTAssertFalse(controller.isBehindLive(in: window))
        // Time shift ended: the 30s rule applies again.
        fake.position = 1_990
        XCTAssertFalse(controller.isBehindLive(in: window))
    }
}
