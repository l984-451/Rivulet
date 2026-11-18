// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class MemoryDiagnosticsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    func test_firstSample_crumbs() {
        var policy = MemoryCrumbPolicy()
        XCTAssertTrue(policy.shouldCrumb(footprintMB: 900, now: t0))
    }

    func test_smallChange_staysQuiet_largeChangeCrumbs() {
        var policy = MemoryCrumbPolicy()
        _ = policy.shouldCrumb(footprintMB: 900, now: t0)
        XCTAssertFalse(policy.shouldCrumb(footprintMB: 930, now: t0 + 30))
        XCTAssertTrue(policy.shouldCrumb(footprintMB: 960, now: t0 + 60))
        XCTAssertTrue(policy.shouldCrumb(footprintMB: 880, now: t0 + 90))
    }

    func test_longQuiet_crumbsAnyway() {
        var policy = MemoryCrumbPolicy()
        _ = policy.shouldCrumb(footprintMB: 900, now: t0)
        XCTAssertFalse(policy.shouldCrumb(footprintMB: 901, now: t0 + 299))
        XCTAssertTrue(policy.shouldCrumb(footprintMB: 901, now: t0 + 300))
    }

    func test_unreadableFootprint_neverCrumbs() {
        var policy = MemoryCrumbPolicy()
        XCTAssertFalse(policy.shouldCrumb(footprintMB: -1, now: t0))
    }

    func test_sidebarTabLabels_carryNoIds() {
        XCTAssertEqual(SidebarTab.library(key: "secret-key").diagnosticsLabel, "library")
        XCTAssertEqual(SidebarTab.providerLibrary(providerID: "p", libraryID: "l").diagnosticsLabel, "library")
        XCTAssertEqual(SidebarTab.liveTV(sourceId: "abc").diagnosticsLabel, "live_tv")
    }
}
