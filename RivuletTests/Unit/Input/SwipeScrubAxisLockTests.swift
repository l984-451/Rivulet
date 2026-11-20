// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The VOD swipe-to-scrub pan's axis lock (cumulative translation, 24 pt, 2:1
/// for horizontal, 1.5:1 for vertical), which decides whether a touch is a scrub.
final class SwipeScrubAxisLockTests: XCTestCase {

    /// Feeds cumulative (x, y) samples and returns the axis after each one.
    private func feed(_ lock: inout SwipeScrubAxisLock, _ samples: [(Double, Double)]) -> [SwipeScrubAxisLock.Axis] {
        samples.map { lock.update(translationX: $0.0, translationY: $0.1) }
    }

    func test_verticalSwipe_withEarlySidewaysWobble_neverLocksHorizontal() {
        // Up swipes whose first samples lean sideways by up to 15 pt, either way:
        // the old one-shot velocity test read these as scrubs.
        let wobbles: [[(Double, Double)]] = [
            [(4, -1), (9, -2), (15, -3), (15, -8), (14, -16), (12, -26), (8, -45), (5, -80), (3, -140)],
            [(-6, 0), (-12, -2), (-15, -5), (-15, -12), (-13, -22), (-10, -30), (-6, -60), (-2, -120)],
            [(15, 0), (15, -4), (15, -10), (15, -18), (15, -24), (14, -40), (10, -90)],
        ]
        for samples in wobbles {
            var lock = SwipeScrubAxisLock()
            let axes = feed(&lock, samples)
            XCTAssertFalse(axes.contains(.horizontal), "wobble \(samples) locked horizontal")
            XCTAssertEqual(lock.axis, .vertical)
        }
    }

    func test_cleanHorizontalSwipe_locksHorizontalAt24Points() {
        var lock = SwipeScrubAxisLock()
        XCTAssertEqual(feed(&lock, [(5, 0), (12, 1), (23.9, 1)]), [.undecided, .undecided, .undecided])
        XCTAssertEqual(lock.update(translationX: 24, translationY: 1), .horizontal)

        var left = SwipeScrubAxisLock()
        XCTAssertEqual(left.update(translationX: -23, translationY: 0), .undecided)
        XCTAssertEqual(left.update(translationX: -24, translationY: -2), .horizontal)
    }

    func test_fortyDegreeDiagonal_neverLocks() {
        // 40 degrees off either axis, in all four quadrants, out to 400 pt.
        for degrees in [40.0, 50.0, 130.0, 140.0, 220.0, 230.0, 310.0, 320.0] {
            var lock = SwipeScrubAxisLock()
            let radians = degrees * .pi / 180
            for step in 1...40 {
                let r = Double(step) * 10
                lock.update(translationX: r * cos(radians), translationY: r * sin(radians))
            }
            XCTAssertEqual(lock.axis, .undecided, "\(degrees) degrees locked")
        }
    }

    func test_verticalSwipe_locksVertical() {
        var up = SwipeScrubAxisLock()
        XCTAssertEqual(feed(&up, [(0, -10), (1, -23)]), [.undecided, .undecided])
        XCTAssertEqual(up.update(translationX: 2, translationY: -24), .vertical)

        var down = SwipeScrubAxisLock()
        XCTAssertEqual(down.update(translationX: -3, translationY: 30), .vertical)
    }

    func test_lock_isStickyOnceDecided_untilReset() {
        var lock = SwipeScrubAxisLock()
        XCTAssertEqual(lock.update(translationX: 30, translationY: 0), .horizontal)
        // A scrub that then curves straight up stays a scrub.
        XCTAssertEqual(lock.update(translationX: 30, translationY: -200), .horizontal)
        XCTAssertEqual(lock.update(translationX: 0, translationY: 0), .horizontal)

        lock.reset()
        XCTAssertEqual(lock.axis, .undecided)
        XCTAssertEqual(lock.update(translationX: 0, translationY: -30), .vertical)
        // An Up swipe that then drifts sideways never becomes a scrub.
        XCTAssertEqual(lock.update(translationX: 300, translationY: -30), .vertical)
    }

    /// The ratio edges are inclusive, in every quadrant.
    func test_dominanceBoundaries() {
        for (sx, sy) in [(1.0, 1.0), (-1.0, 1.0), (1.0, -1.0), (-1.0, -1.0)] {
            // Horizontal needs x >= 2y.
            XCTAssertEqual(SwipeScrubAxisLock.classify(translationX: sx * 48, translationY: sy * 24), .horizontal)
            XCTAssertEqual(SwipeScrubAxisLock.classify(translationX: sx * 47.9, translationY: sy * 24), .undecided)
            // Vertical needs y >= 1.5x.
            XCTAssertEqual(SwipeScrubAxisLock.classify(translationX: sx * 24, translationY: sy * 36), .vertical)
            XCTAssertEqual(SwipeScrubAxisLock.classify(translationX: sx * 24, translationY: sy * 35.9), .undecided)
        }
    }

    /// An Up swipe whose first 24 pt run 30 degrees above horizontal (the old 2:1
    /// velocity test refused it) is not a scrub, and still locks vertical once it
    /// turns up.
    func test_thirtyDegreeStart_thenUp_neverLocksHorizontal() {
        var lock = SwipeScrubAxisLock()
        let axes = feed(&lock, [(12, -7), (24, -14), (30, -40), (32, -90), (33, -160)])
        XCTAssertFalse(axes.contains(.horizontal))
        XCTAssertEqual(lock.axis, .vertical)
    }

    func test_touchThatEndsSmall_staysUndecided() {
        var lock = SwipeScrubAxisLock()
        _ = feed(&lock, [(3, 2), (8, -6), (12, -10)])
        XCTAssertEqual(lock.axis, .undecided)
    }
}
