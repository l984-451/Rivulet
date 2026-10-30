// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class UpNextExitTests: XCTestCase {
    private let key = UpNextExit.storageKey

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: key)
        super.tearDown()
    }

    func test_unset_keepsTheCredits() {
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(UpNextExit.current, .credits)
    }

    func test_cycle_visitsEveryOptionAndWraps() {
        XCTAssertEqual(UpNextExit.credits.next, .previousScreen)
        XCTAssertEqual(UpNextExit.previousScreen.next, .home)
        XCTAssertEqual(UpNextExit.home.next, .credits)
    }

    func test_settingsRow_sitsUnderUpNextPanel() {
        let ids = SettingsContent.rows(for: .playback).map(\.id)
        guard let panel = ids.firstIndex(of: "showPostVideoUpNext") else {
            return XCTFail("Up Next Panel row missing")
        }
        XCTAssertEqual(ids.indices.contains(panel + 1) ? ids[panel + 1] : nil, "upNextExit")
        XCTAssertNotNil(SettingsDescriptorStore.descriptor(for: "upNextExit"))
    }
}
