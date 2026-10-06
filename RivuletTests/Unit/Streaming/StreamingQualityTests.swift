// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class StreamingQualityTests: XCTestCase {
    func test_rawValues_roundTrip() {
        for choice in StreamingQuality.allChoices {
            XCTAssertEqual(StreamingQuality(rawValue: choice.rawValue), choice)
        }
        XCTAssertEqual(StreamingQuality.original.rawValue, "original")
        XCTAssertEqual(StreamingQuality.auto.rawValue, "auto")
        XCTAssertEqual(StreamingQuality.step(QualityStep.step(kbps: 8000)!).rawValue, "8000")
        XCTAssertNil(StreamingQuality(rawValue: "9999"))
        XCTAssertNil(StreamingQuality(rawValue: ""))
    }

    func test_labels() {
        XCTAssertEqual(QualityStep.step(kbps: 20000)?.label, "20 Mbps 1080p")
        XCTAssertEqual(QualityStep.step(kbps: 1500)?.label, "1.5 Mbps 480p")
        XCTAssertEqual(QualityStep.step(kbps: 720)?.label, "720 kbps")
        XCTAssertEqual(StreamingQuality.auto.label, "Auto")
        XCTAssertEqual(StreamingQuality.original.label, "Original")
    }

    func test_ladder_isDescendingAndRelayIsOnIt() {
        let kbps = QualityStep.ladder.map(\.kbps)
        XCTAssertEqual(kbps, [20000, 12000, 8000, 4000, 2000, 1500, 720])
        XCTAssertEqual(QualityStep.relay, QualityStep.step(kbps: 1500))
        XCTAssertEqual(QualityStep.step(kbps: 4000)?.tier, 720)
        XCTAssertEqual(QualityStep.step(kbps: 8000)?.tier, 1080)
    }

    func test_setting_defaultsAndStoredValues() {
        let defaults = UserDefaults(suiteName: "StreamingQualityTests")!
        defaults.removePersistentDomain(forName: "StreamingQualityTests")
        XCTAssertEqual(StreamingQuality.setting(home: true, defaults: defaults), .original)
        XCTAssertEqual(StreamingQuality.setting(home: false, defaults: defaults), .auto)
        defaults.set("4000", forKey: StreamingQuality.awayKey)
        XCTAssertEqual(StreamingQuality.setting(home: false, defaults: defaults), .step(QualityStep.step(kbps: 4000)!))
        defaults.set("garbage", forKey: StreamingQuality.homeKey)
        XCTAssertEqual(StreamingQuality.setting(home: true, defaults: defaults), .original)
    }
}
