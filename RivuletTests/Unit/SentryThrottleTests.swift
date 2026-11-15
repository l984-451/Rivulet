// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class SentryThrottleTests: XCTestCase {
    func test_sameKey_admittedOnce() {
        var throttle = SentryThrottle()
        XCTAssertTrue(throttle.admit("a"))
        XCTAssertFalse(throttle.admit("a"))
        XCTAssertTrue(throttle.admit("b"))
    }

    func test_limit_allowsThatMany() {
        var throttle = SentryThrottle()
        XCTAssertTrue(throttle.admit("hang", limit: 2))
        XCTAssertTrue(throttle.admit("hang", limit: 2))
        XCTAssertFalse(throttle.admit("hang", limit: 2))
    }

    func test_totalCap_stopsNewKeys() {
        var throttle = SentryThrottle(maxTotal: 2)
        XCTAssertTrue(throttle.admit("a"))
        XCTAssertTrue(throttle.admit("b"))
        XCTAssertFalse(throttle.admit("c"))
    }

    func test_key_separatesMessagesOfOneType() {
        struct Failure: Error { let message: String }
        XCTAssertNotEqual(SentryThrottle.key(for: Failure(message: "x")), SentryThrottle.key(for: Failure(message: "y")))
        XCTAssertEqual(SentryThrottle.key(for: Failure(message: "x")), SentryThrottle.key(for: Failure(message: "x")))
    }
}
