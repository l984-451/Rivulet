// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class SkipLengthKeysTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "SkipLengthKeysTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func test_tvOSForwardKeyMovesToSharedName() {
        defaults.set(15, forKey: "skipSeconds")
        SkipLengthKeys.migrateLegacyKeys(in: defaults)
        XCTAssertEqual(defaults.object(forKey: SkipLengthKeys.forward) as? Int, 15)
        XCTAssertNil(defaults.object(forKey: "skipSeconds"))
    }

    func test_iOSKeysMoveToSharedNames() {
        defaults.set(5, forKey: "playerSkipBackwardSeconds")
        defaults.set(10, forKey: "playerSkipForwardSeconds")
        SkipLengthKeys.migrateLegacyKeys(in: defaults)
        XCTAssertEqual(defaults.object(forKey: SkipLengthKeys.back) as? Int, 5)
        XCTAssertEqual(defaults.object(forKey: SkipLengthKeys.forward) as? Int, 10)
        XCTAssertNil(defaults.object(forKey: "playerSkipBackwardSeconds"))
        XCTAssertNil(defaults.object(forKey: "playerSkipForwardSeconds"))
    }

    func test_valueAlreadyUnderNewNameWins() {
        defaults.set(30, forKey: SkipLengthKeys.forward)
        defaults.set(5, forKey: "skipSeconds")
        SkipLengthKeys.migrateLegacyKeys(in: defaults)
        XCTAssertEqual(defaults.integer(forKey: SkipLengthKeys.forward), 30)
        XCTAssertNil(defaults.object(forKey: "skipSeconds"))
    }

    func test_bothAppsOfferTheSameLengths() {
        XCTAssertEqual(SkipLengthKeys.options, [5, 10, 15, 30, 60])
        XCTAssertEqual(SkipInterval.allCases.map(\.rawValue), SkipLengthKeys.options)
    }

    func test_unsetStaysUnset() {
        SkipLengthKeys.migrateLegacyKeys(in: defaults)
        XCTAssertNil(defaults.object(forKey: SkipLengthKeys.forward))
        XCTAssertNil(defaults.object(forKey: SkipLengthKeys.back))
    }

    func test_runningTwiceKeepsTheValue() {
        defaults.set(15, forKey: "skipSeconds")
        SkipLengthKeys.migrateLegacyKeys(in: defaults)
        SkipLengthKeys.migrateLegacyKeys(in: defaults)
        XCTAssertEqual(defaults.integer(forKey: SkipLengthKeys.forward), 15)
    }
}
