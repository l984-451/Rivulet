// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlaybackInputCoordinatorTests.swift
//  RivuletTests
//
//  Unit tests for deduplication and coalescing behavior in PlaybackInputCoordinator.
//

import XCTest
@testable import Rivulet

@MainActor
final class PlaybackInputCoordinatorTests: XCTestCase {

    private final class MockTarget: PlaybackInputTarget {
        var isScrubbingForInput = false
        private(set) var received: [(PlaybackInputAction, PlaybackInputSource)] = []
        /// Fulfilled when the first action arrives.
        var firstArrival: XCTestExpectation?

        func handleInputAction(_ action: PlaybackInputAction, source: PlaybackInputSource) {
            received.append((action, source))
            if received.count == 1 { firstArrival?.fulfill() }
        }
    }

    /// Waits for the coalesce timer's flush rather than a fixed delay, so a
    /// busy machine slows the test down instead of failing it.
    private func waitForCoalescedDispatch(to target: MockTarget) {
        let arrived = expectation(description: "coalesced seek dispatched")
        target.firstArrival = arrived
        wait(for: [arrived], timeout: 5)
    }

    func testRapidStepSeeksAreCoalescedIntoSingleRelativeSeek() {
        let coordinator = PlaybackInputCoordinator()
        let target = MockTarget()
        coordinator.target = target

        coordinator.handle(action: .stepSeek(forward: true), source: .siriMicroGamepad)
        coordinator.handle(action: .stepSeek(forward: true), source: .siriMicroGamepad)
        coordinator.handle(action: .stepSeek(forward: false), source: .siriMicroGamepad)

        waitForCoalescedDispatch(to: target)

        XCTAssertEqual(target.received.count, 1)
        guard let first = target.received.first else { return }
        guard case .seekRelative(let seconds) = first.0 else {
            return XCTFail("Expected coalesced seekRelative action")
        }
        XCTAssertEqual(seconds, InputConfig.tapSeekSeconds, accuracy: 0.0001)
    }

    func testDuplicateRelativeSeekFromDifferentSourcesIsDeduped() {
        let coordinator = PlaybackInputCoordinator()
        let target = MockTarget()
        coordinator.target = target

        coordinator.handle(action: .stepSeek(forward: true), source: .siriMicroGamepad)
        coordinator.handle(action: .stepSeek(forward: true), source: .irPress)

        waitForCoalescedDispatch(to: target)

        XCTAssertEqual(target.received.count, 1)
        guard let first = target.received.first else { return }
        guard case .seekRelative(let seconds) = first.0 else {
            return XCTFail("Expected seekRelative action")
        }
        XCTAssertEqual(seconds, InputConfig.tapSeekSeconds, accuracy: 0.0001)
    }

    func testScrubNudgeIsDispatchedImmediatelyWithoutCoalescing() throws {
        let coordinator = PlaybackInputCoordinator()
        let target = MockTarget()
        coordinator.target = target

        coordinator.handle(action: .scrubNudge(forward: true), source: .keyboard)

        XCTAssertEqual(target.received.count, 1)
        let first = try XCTUnwrap(target.received.first)
        XCTAssertEqual(first.0, .scrubNudge(forward: true))
        XCTAssertEqual(first.1, .keyboard)
    }

    func testRapidTransportCommandsFromDifferentInputPathsAreDeduped() throws {
        let coordinator = PlaybackInputCoordinator()
        let target = MockTarget()
        coordinator.target = target

        coordinator.handle(action: .playPause, source: .keyboard)
        coordinator.handle(action: .pause, source: .mpRemoteCommand)
        coordinator.handle(action: .playPause, source: .swiftUICommand)

        XCTAssertEqual(target.received.count, 1)
        let first = try XCTUnwrap(target.received.first)
        XCTAssertEqual(first.0, .playPause)
        XCTAssertEqual(first.1, .keyboard)
    }

    func testSeekWhileScrubbingBypassesCoalescing() throws {
        let coordinator = PlaybackInputCoordinator()
        let target = MockTarget()
        target.isScrubbingForInput = true
        coordinator.target = target

        coordinator.handle(action: .stepSeek(forward: true), source: .extendedGamepad)

        XCTAssertEqual(target.received.count, 1)
        let first = try XCTUnwrap(target.received.first)
        guard case .seekRelative(let seconds) = first.0 else {
            return XCTFail("Expected immediate seekRelative while scrubbing")
        }
        XCTAssertEqual(seconds, InputConfig.tapSeekSeconds, accuracy: 0.0001)
    }
}
