// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTunerBusyTests.swift
//  RivuletTests
//
//  Only Dispatcharr's out-of-connections answer may read as busy: any other
//  503 is a broken source and keeps the fallback ladder.
//

import XCTest
@testable import Rivulet

final class LiveTunerBusyTests: XCTestCase {

    func test_onlyTheConnectionLimitRefusalIsBusy() {
        let busy = Data(#"{"error": "All active M3U profiles have reached maximum connection limits", "waited": "3s"}"#.utf8)
        XCTAssertTrue(LiveTunerBusy.isBusyResponse(status: 503, body: busy))
        XCTAssertFalse(LiveTunerBusy.isBusyResponse(status: 200, body: busy))
        XCTAssertFalse(LiveTunerBusy.isBusyResponse(status: 503, body: Data(#"{"error": "Upstream timed out"}"#.utf8)))
        XCTAssertFalse(LiveTunerBusy.isBusyResponse(status: 503, body: Data("<html>Service Unavailable</html>".utf8)))
    }
}
