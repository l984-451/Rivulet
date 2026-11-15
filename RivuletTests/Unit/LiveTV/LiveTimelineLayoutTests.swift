// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class LiveSeekableWindowTests: XCTestCase {
    func testUsesNewestContiguousRange() {
        let window = LiveSeekableWindow(ranges: [(start: 100, duration: 20), (start: 125, duration: 15)])
        XCTAssertEqual(window?.lowerBound, 125)
        XCTAssertEqual(window?.upperBound, 140)
    }

    func testRejectsInvalidAndEmptyRanges() {
        XCTAssertNil(LiveSeekableWindow(ranges: []))
        XCTAssertNil(LiveSeekableWindow(ranges: [(start: .nan, duration: 30), (start: 10, duration: 0)]))
    }

    func testHoldbackSizedWindowIsNotSeekable() {
        XCTAssertEqual(LiveSeekableWindow(ranges: [(start: 0, duration: 59)])?.isSeekable, false)
        XCTAssertEqual(LiveSeekableWindow(ranges: [(start: 0, duration: 60)])?.isSeekable, true)
    }

    func testSeekTargetStaysClearOfTheOldestSegment() {
        let window = LiveSeekableWindow(lowerBound: 100, upperBound: 1_900)
        XCTAssertEqual(window.seekTarget(0), 106)
        XCTAssertEqual(window.seekTarget(5_000), 1_900)
        XCTAssertEqual(window.seekTarget(500), 500)
    }

    func testBehindLiveOnlyWhenTheViewerIsActuallyBehind() {
        // A channel nobody touched: HLS's normal delay swings as segments land.
        for behind in [0.5, 3, 9, 24] as [TimeInterval] {
            XCTAssertFalse(LiveSeekableWindow.isBehindLive(behind, timeShifted: false), "\(behind)s")
        }
        XCTAssertTrue(LiveSeekableWindow.isBehindLive(30, timeShifted: false))
        XCTAssertTrue(LiveSeekableWindow.isBehindLive(4, timeShifted: true))
        XCTAssertFalse(LiveSeekableWindow.isBehindLive(2, timeShifted: true))
    }
}

final class LiveTimelineLayoutTests: XCTestCase {
    private let ten = Date(timeIntervalSince1970: 36_000)

    private func program(_ startHour: Double, _ endHour: Double) -> UnifiedProgram {
        UnifiedProgram(
            id: "\(startHour)", channelId: "c", title: "P",
            startTime: Date(timeIntervalSince1970: startHour * 3_600),
            endTime: Date(timeIntervalSince1970: endHour * 3_600)
        )
    }

    func testNothingToMeasureWithoutGuideOrWindow() {
        XCTAssertNil(LiveTimelineLayout(now: ten, program: nil, seekWindowSeconds: nil, behindLiveSeconds: 0))
    }

    func testWithoutAWindowTheBarMeasuresTheProgramme() throws {
        let layout = try XCTUnwrap(LiveTimelineLayout(
            now: ten.addingTimeInterval(1_800), program: program(10, 11),
            seekWindowSeconds: nil, behindLiveSeconds: 0
        ))
        XCTAssertEqual(layout.start, ten)
        XCTAssertEqual(layout.boundaries, [])
        XCTAssertNil(layout.seekableStart)
        XCTAssertEqual(layout.aired, 0.5, accuracy: 0.0001)
        XCTAssertEqual(layout.playing, 0.5, accuracy: 0.0001)
    }

    func testWindowReachesBackIntoEarlierProgrammes() throws {
        let layout = try XCTUnwrap(LiveTimelineLayout(
            now: ten.addingTimeInterval(1_800), program: program(10, 11),
            earlierPrograms: [program(8, 9), program(9, 10)],
            seekWindowSeconds: 7_200, behindLiveSeconds: 1_800
        ))
        // 08:00–11:00, split at 09:00 and 10:00, seekable from 08:30.
        XCTAssertEqual(layout.start, Date(timeIntervalSince1970: 8 * 3_600))
        XCTAssertEqual(layout.boundaries.count, 2)
        XCTAssertEqual(layout.boundaries[0], 1.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(layout.boundaries[1], 2.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(layout.seekableStart), 1.0 / 6, accuracy: 0.0001)
        XCTAssertEqual(layout.aired, 2.5 / 3, accuracy: 0.0001)
        XCTAssertEqual(layout.playing, 2.0 / 3, accuracy: 0.0001)
        XCTAssertEqual(layout.onScreen, ten)
    }

    func testWindowPastTheGuideRunsOnToTheWindowStart() throws {
        let layout = try XCTUnwrap(LiveTimelineLayout(
            now: ten.addingTimeInterval(1_800), program: program(10, 11),
            seekWindowSeconds: 7_200, behindLiveSeconds: 0
        ))
        XCTAssertEqual(layout.start, ten.addingTimeInterval(-5_400))
        XCTAssertEqual(layout.boundaries.count, 1)
        XCTAssertEqual(try XCTUnwrap(layout.seekableStart), 0, accuracy: 0.0001)
    }

    func testGapInTheGuideEndsTheWalk() throws {
        // 08:00–09:00 is followed by a hole until 10:00: only 10:00 is a boundary.
        let layout = try XCTUnwrap(LiveTimelineLayout(
            now: ten.addingTimeInterval(1_800), program: program(10, 11),
            earlierPrograms: [program(8, 9)],
            seekWindowSeconds: 7_200, behindLiveSeconds: 0
        ))
        XCTAssertEqual(layout.boundaries.count, 1)
        XCTAssertEqual(layout.start, ten.addingTimeInterval(-5_400))
    }

    func testVeryDeepWindowIsCappedToTheLookback() throws {
        let now = ten.addingTimeInterval(1_800)
        let layout = try XCTUnwrap(LiveTimelineLayout(
            now: now, program: program(10, 11),
            seekWindowSeconds: 24 * 3_600, behindLiveSeconds: 0
        ))
        XCTAssertEqual(layout.start, now.addingTimeInterval(-LiveTimelineLayout.maximumLookback))
    }

    func testWindowWithoutGuideFillsToTheEdge() throws {
        let layout = try XCTUnwrap(LiveTimelineLayout(
            now: ten, program: nil, seekWindowSeconds: 600, behindLiveSeconds: 150
        ))
        XCTAssertEqual(layout.start, ten.addingTimeInterval(-600))
        XCTAssertEqual(layout.aired, 1)
        XCTAssertEqual(layout.playing, 0.75, accuracy: 0.0001)
    }
}
