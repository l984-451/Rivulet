// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class CreditsBehaviorTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "CreditsBehaviorTests")
        defaults.removePersistentDomain(forName: "CreditsBehaviorTests")
    }

    func testDecisionTable() {
        XCTAssertTrue(CreditsBehavior.upNext.showsUpNextAtCredits)
        XCTAssertFalse(CreditsBehavior.skipButton.showsUpNextAtCredits)
        XCTAssertFalse(CreditsBehavior.nothing.showsUpNextAtCredits)
        XCTAssertTrue(CreditsBehavior.upNext.showsSkipPill)
        XCTAssertTrue(CreditsBehavior.skipButton.showsSkipPill)
        XCTAssertFalse(CreditsBehavior.nothing.showsSkipPill)
        XCTAssertFalse(CreditsBehavior.upNext.opensUpNextAtEnd)
        XCTAssertTrue(CreditsBehavior.skipButton.opensUpNextAtEnd)
        XCTAssertTrue(CreditsBehavior.nothing.opensUpNextAtEnd)
    }

    func testMigrationTable() {
        XCTAssertEqual(CreditsBehavior.migrated(upNextPanel: nil, showSkipCredits: nil), .upNext)
        XCTAssertEqual(CreditsBehavior.migrated(upNextPanel: true, showSkipCredits: false), .upNext)
        XCTAssertEqual(CreditsBehavior.migrated(upNextPanel: false, showSkipCredits: nil), .skipButton)
        XCTAssertEqual(CreditsBehavior.migrated(upNextPanel: false, showSkipCredits: true), .skipButton)
        XCTAssertEqual(CreditsBehavior.migrated(upNextPanel: false, showSkipCredits: false), .nothing)
    }

    func testFirstReadMigratesAndRemovesOldKeys() {
        defaults.set(false, forKey: "showPostVideoUpNext")
        defaults.set(false, forKey: "showSkipCredits")
        defaults.set(true, forKey: "autoSkipCredits")
        XCTAssertEqual(CreditsBehavior.current(defaults: defaults), .nothing)
        for key in CreditsBehavior.legacyKeys { XCTAssertNil(defaults.object(forKey: key), key) }
        XCTAssertEqual(CreditsBehavior.current(defaults: defaults), .nothing)
    }

    func testFreshInstallIsUpNext() {
        XCTAssertEqual(CreditsBehavior.current(defaults: defaults), .upNext)
    }
}
