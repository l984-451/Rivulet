// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class SettingsUsageTelemetryTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SettingsUsageTelemetryTests")
        defaults.removePersistentDomain(forName: "SettingsUsageTelemetryTests")
    }

    func test_snapshot_reportsStoredValuesNotDisplayText() {
        defaults.set(true, forKey: "skipPreviewCarousel")
        defaults.set(20, forKey: "autoplayCountdown")
        defaults.set("guide", forKey: "liveTVLayout")
        let snapshot = SettingsUsageTelemetry.snapshot(defaults: defaults)
        XCTAssertEqual(snapshot["skipPreviewCarousel"], "true")
        XCTAssertEqual(snapshot["autoplayCountdown"], "20")
        XCTAssertEqual(snapshot["liveTVLayout"], "guide")
        XCTAssertEqual(snapshot["showPosterTitles"], "default")
        XCTAssertEqual(snapshot["schema"], SettingsUsageTelemetry.schema)
    }

    func test_snapshot_neverSendsWhatTheUserTyped() {
        defaults.set("heck, darn", forKey: "contentFilter.customWords")
        defaults.set(["plex:abc:1", "m3u:def:2"], forKey: "liveTVFavoriteChannelIds")
        let snapshot = SettingsUsageTelemetry.snapshot(defaults: defaults)
        XCTAssertEqual(snapshot["contentFilter.customWords"], "set")
        XCTAssertEqual(snapshot["liveTVFavoriteChannelIds"], "2")
        XCTAssertEqual(SettingsUsageTelemetry.value("http://192.168.1.2:32400"), "set")
    }

    func test_contentFilterCategories_matchTheToggles() {
        XCTAssertEqual(SettingsUsageTelemetry.contentFilterCategories,
                       FilterCategory.userToggleable.map(\.rawValue))
    }
}
