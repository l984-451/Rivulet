// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class QualityDecisionTests: XCTestCase {
    private let s8 = QualityStep.step(kbps: 8000)!
    private let s4 = QualityStep.step(kbps: 4000)!

    func test_original_playsOriginal_unlessRelay() {
        XCTAssertEqual(QualityDecision.decide(setting: .original, sourceKbps: 60000, measuredKbps: nil, isRelay: false), .original)
        XCTAssertEqual(QualityDecision.decide(setting: .original, sourceKbps: 60000, measuredKbps: nil, isRelay: true), .transcode(.relay))
    }

    func test_fixedStep_playsOriginalWhenSourceAlreadyFits() {
        XCTAssertEqual(QualityDecision.decide(setting: .step(s8), sourceKbps: 6000, measuredKbps: nil, isRelay: false), .original)
        XCTAssertEqual(QualityDecision.decide(setting: .step(s8), sourceKbps: 9000, measuredKbps: nil, isRelay: false), .transcode(s8))
        XCTAssertEqual(QualityDecision.decide(setting: .step(s8), sourceKbps: nil, measuredKbps: nil, isRelay: false), .transcode(s8))
    }

    func test_fixedStep_onRelay_isClamped() {
        let s720 = QualityStep.step(kbps: 720)!
        XCTAssertEqual(QualityDecision.decide(setting: .step(s8), sourceKbps: 9000, measuredKbps: nil, isRelay: true), .transcode(.relay))
        XCTAssertEqual(QualityDecision.decide(setting: .step(s720), sourceKbps: 9000, measuredKbps: nil, isRelay: true), .transcode(s720))
    }

    func test_auto() {
        // 75% of 20 Mbps = 15 Mbps budget.
        XCTAssertEqual(QualityDecision.decide(setting: .auto, sourceKbps: 14000, measuredKbps: 20000, isRelay: false), .original)
        XCTAssertEqual(QualityDecision.decide(setting: .auto, sourceKbps: 40000, measuredKbps: 20000, isRelay: false), .transcode(QualityStep.step(kbps: 12000)!))
        // Budget below the lowest step still transcodes at the lowest step.
        XCTAssertEqual(QualityDecision.decide(setting: .auto, sourceKbps: 40000, measuredKbps: 300, isRelay: false), .transcode(QualityStep.ladder.last!))
        // Unknown source plays the original; a failed probe uses 4 Mbps when the source is above it.
        XCTAssertEqual(QualityDecision.decide(setting: .auto, sourceKbps: nil, measuredKbps: 1000, isRelay: false), .original)
        XCTAssertEqual(QualityDecision.decide(setting: .auto, sourceKbps: 9000, measuredKbps: nil, isRelay: false), .transcode(s4))
        XCTAssertEqual(QualityDecision.decide(setting: .auto, sourceKbps: 3000, measuredKbps: nil, isRelay: false), .original)
    }

    func test_capAndProbeNeed() {
        XCTAssertNil(QualityDecision.capKbps(setting: .original, measuredKbps: nil, isRelay: false))
        XCTAssertEqual(QualityDecision.capKbps(setting: .original, measuredKbps: nil, isRelay: true), 1500)
        XCTAssertEqual(QualityDecision.capKbps(setting: .step(s8), measuredKbps: nil, isRelay: false), 8000)
        XCTAssertEqual(QualityDecision.capKbps(setting: .auto, measuredKbps: 20000, isRelay: false), 15000)
        XCTAssertEqual(QualityDecision.capKbps(setting: .auto, measuredKbps: nil, isRelay: false), 4000)
        XCTAssertTrue(QualityDecision.needsProbe(setting: .auto, isRelay: false))
        XCTAssertFalse(QualityDecision.needsProbe(setting: .auto, isRelay: true))
        XCTAssertFalse(QualityDecision.needsProbe(setting: .original, isRelay: false))
    }

    func test_stepDown() {
        XCTAssertEqual(QualityDecision.stepDown(from: .original, sourceKbps: 15000), QualityStep.step(kbps: 12000))
        XCTAssertEqual(QualityDecision.stepDown(from: .original, sourceKbps: nil), QualityStep.step(kbps: 20000))
        XCTAssertEqual(QualityDecision.stepDown(from: .transcode(s8), sourceKbps: 40000), s4)
        XCTAssertNil(QualityDecision.stepDown(from: .transcode(QualityStep.ladder.last!), sourceKbps: 40000))
    }

    func test_probeRateMath() {
        XCTAssertEqual(ThroughputProbe.kbps(bytes: 2_500_000, seconds: 1), 20000)
        XCTAssertNil(ThroughputProbe.kbps(bytes: 1000, seconds: 1))     // too little to judge
        XCTAssertNil(ThroughputProbe.kbps(bytes: 2_500_000, seconds: 0))
    }

    func test_sourceKbps_fallsBackToSizeOverDuration() throws {
        let json = #"{"id":1,"duration":7200000,"bitrate":null,"Part":[{"id":2,"key":"/k","duration":7200000,"size":9000000000}]}"#
        let media = try JSONDecoder().decode(PlexMedia.self, from: Data(json.utf8))
        XCTAssertEqual(media.sourceKbps, 10000)   // 9 GB over 2 h = 10 Mbps
    }
}
