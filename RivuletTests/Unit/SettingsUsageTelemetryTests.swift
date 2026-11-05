// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class SettingsUsageTelemetryTests: XCTestCase {

    func test_snapshot_keysPreferenceRowsByPage() {
        let snapshot = SettingsUsageTelemetry.snapshot()
        XCTAssertNotNil(snapshot["playback.upscaleLowResolution"])
        XCTAssertNotNil(snapshot["sidebar.showDiscoverTab"])
        XCTAssertNotNil(snapshot["liveTV.defaultLayout"])
    }

    func test_snapshot_leavesOutTextAndHeaders() {
        let keys = SettingsUsageTelemetry.snapshot().keys
        XCTAssertFalse(keys.contains("contentFilter.cf_sourceURL"), "the list source is a URL")
        XCTAssertFalse(keys.contains { $0.contains("hdr_") })
    }
}
