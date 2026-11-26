// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class PlayerScrubSessionTests: XCTestCase {
    private var playhead: TimeInterval = 200
    private var changes: [TimeInterval] = []

    private func makeSession(wheelIdleDelay: TimeInterval = 0.8) -> PlayerScrubSession {
        let s = PlayerScrubSession(range: { 100...400 }, position: { [unowned self] in playhead },
                                   wheelIdleDelay: wheelIdleDelay)
        s.onScrubTimeChanged = { [unowned self] in changes.append($0) }
        return s
    }

    func testStepClampsAtBothEnds() {
        let s = makeSession()
        s.step(by: 1000)
        XCTAssertEqual(s.scrubTime, 400)
        s.step(by: -1000)
        XCTAssertEqual(s.scrubTime, 100)
        XCTAssertTrue(s.isScrubbing)
    }

    func testJumpClamps() {
        let s = makeSession()
        s.jump(to: 50)
        XCTAssertEqual(s.scrubTime, 100)
        s.jump(to: 999)
        XCTAssertEqual(s.scrubTime, 400)
    }

    func testStartsAtPlayheadAndNotifies() {
        let s = makeSession()
        s.step(by: 10)
        XCTAssertEqual(s.scrubTime, 210)
        XCTAssertEqual(changes, [200, 210])
    }

    func testShuttleEntersJumpsAndSteps() {
        let s = makeSession()
        s.shuttle(forward: true)
        XCTAssertEqual(s.scrubSpeed, 1)
        XCTAssertEqual(s.scrubTime, 210)
        s.shuttle(forward: true)
        XCTAssertEqual(s.scrubSpeed, 2)
        XCTAssertEqual(s.scrubTime, 220)
        s.cancel()
    }

    func testShuttleReverseStepsDownThenCrosses() {
        let s = makeSession()
        s.shuttle(forward: true)
        s.shuttle(forward: true)
        s.shuttle(forward: false)
        XCTAssertEqual(s.scrubSpeed, 1)
        s.shuttle(forward: false)
        XCTAssertEqual(s.scrubSpeed, -1)
        s.cancel()
    }

    func testTickAdvancesByRateAndStopsAtRangeEnd() {
        let s = makeSession()
        playhead = 395
        s.shuttle(forward: true)
        XCTAssertEqual(s.scrubTime, 400)
        // Jump already hit the end; the next tick must stop the shuttle there.
        s.tick()
        XCTAssertEqual(s.scrubSpeed, 0)
        XCTAssertEqual(s.scrubTime, 400)
        XCTAssertTrue(s.isScrubbing)
    }

    func testTickMovesByRatePerInterval() {
        let s = makeSession()
        s.shuttle(forward: true)
        let before = s.scrubTime
        s.tick()
        XCTAssertEqual(s.scrubTime - before, ShuttleGrammar.rate(forLevel: 1) * 0.1, accuracy: 0.0001)
        s.cancel()
    }

    func testTickStopsAtRangeStartGoingBackward() {
        let s = makeSession()
        playhead = 105
        s.shuttle(forward: false)
        XCTAssertEqual(s.scrubTime, 100)
        s.tick()
        XCTAssertEqual(s.scrubSpeed, 0)
        XCTAssertEqual(s.scrubTime, 100)
    }

    func testSwipeTakesOverShuttle() {
        let s = makeSession()
        s.shuttle(forward: true)
        s.swipe(by: 5)
        XCTAssertEqual(s.scrubSpeed, 0)
        let t = s.scrubTime
        s.tick()
        XCTAssertEqual(s.scrubTime, t)
        s.cancel()
    }

    func testWheelTakesOverShuttleAndSetsFlag() {
        let s = makeSession()
        s.shuttle(forward: true)
        s.wheel(by: 3)
        XCTAssertEqual(s.scrubSpeed, 0)
        XCTAssertTrue(s.wheelScrubbing)
        s.cancel()
    }

    func testWheelFlagClearsWhenIdle() async throws {
        let s = makeSession(wheelIdleDelay: 0.05)
        s.wheel(by: 3)
        XCTAssertTrue(s.wheelScrubbing)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(s.wheelScrubbing)
        XCTAssertTrue(s.isScrubbing)
    }

    func testWheelFlagHeldWhileRingRests() async throws {
        let s = makeSession(wheelIdleDelay: 0.05)
        var resting = true
        s.holdsWheel = { resting }
        s.wheel(by: 3)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(s.wheelScrubbing)
        resting = false
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(s.wheelScrubbing)
    }

    func testCommitReturnsTargetAndClearsState() {
        let s = makeSession()
        s.shuttle(forward: true)
        s.wheel(by: 7)
        XCTAssertEqual(s.commit(), 217)
        XCTAssertFalse(s.isScrubbing)
        XCTAssertEqual(s.scrubSpeed, 0)
        XCTAssertFalse(s.wheelScrubbing)
        XCTAssertNil(s.commit())
    }

    func testCommitTargetKeepsStateUntilFinish() {
        let s = makeSession()
        s.step(by: 20)
        XCTAssertEqual(s.commitTarget(), 220)
        XCTAssertTrue(s.isScrubbing)
        s.finish()
        XCTAssertFalse(s.isScrubbing)
    }

    func testCancelRestoresPlayhead() {
        let s = makeSession()
        s.shuttle(forward: true)
        playhead = 250
        s.cancel()
        XCTAssertFalse(s.isScrubbing)
        XCTAssertEqual(s.scrubSpeed, 0)
        XCTAssertEqual(s.scrubTime, 250)
    }
}
