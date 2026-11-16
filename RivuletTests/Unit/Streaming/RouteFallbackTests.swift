// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class RouteFallbackTests: XCTestCase {
    private let step = QualityStep.step(kbps: 4000)!

    func test_originalFailure_transcodesOnce() {
        XCTAssertTrue(RouteFallback.transcodesAfterOriginalFailure(plan: .original, hasSwitched: false, isLocal: false, isStacked: false))
        XCTAssertFalse(RouteFallback.transcodesAfterOriginalFailure(plan: .original, hasSwitched: true, isLocal: false, isStacked: false))
    }

    func test_noTranscodeRoute_forADownloadOrAStackedTitle() {
        XCTAssertFalse(RouteFallback.transcodesAfterOriginalFailure(plan: .original, hasSwitched: false, isLocal: true, isStacked: false))
        XCTAssertFalse(RouteFallback.transcodesAfterOriginalFailure(plan: .original, hasSwitched: false, isLocal: false, isStacked: true))
    }

    func test_aTranscodeNeverTranscodesAgain() {
        XCTAssertFalse(RouteFallback.transcodesAfterOriginalFailure(plan: .transcode(step), hasSwitched: false, isLocal: false, isStacked: false))
    }

    func test_transcodeFailure_playsOriginalOnlyWhenQualityChoseItAndNotOnRelay() {
        XCTAssertTrue(RouteFallback.playsOriginalAfterTranscodeFailure(plan: .transcode(step), hasSwitched: false, isRelay: false))
        XCTAssertFalse(RouteFallback.playsOriginalAfterTranscodeFailure(plan: .transcode(step), hasSwitched: false, isRelay: true))
        XCTAssertFalse(RouteFallback.playsOriginalAfterTranscodeFailure(plan: .original, hasSwitched: false, isRelay: false))
    }

    /// Whichever route fails first hands over; the one it hands to cannot hand back.
    func test_oneSwitchPerItem_cannotPingPong() {
        var switched = false
        // The file fails: the transcode takes over (plan becomes a transcode, the switch is spent).
        XCTAssertTrue(RouteFallback.transcodesAfterOriginalFailure(plan: .original, hasSwitched: switched, isLocal: false, isStacked: false))
        switched = true
        XCTAssertFalse(RouteFallback.playsOriginalAfterTranscodeFailure(plan: .transcode(step), hasSwitched: switched, isRelay: false))
        // The other order: a step fails first, the file takes over and then cannot hand back.
        switched = false
        XCTAssertTrue(RouteFallback.playsOriginalAfterTranscodeFailure(plan: .transcode(step), hasSwitched: switched, isRelay: false))
        switched = true
        XCTAssertFalse(RouteFallback.transcodesAfterOriginalFailure(plan: .original, hasSwitched: switched, isLocal: false, isStacked: false))
    }
}
