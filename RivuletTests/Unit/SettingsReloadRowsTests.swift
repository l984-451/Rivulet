// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsReloadRowsTests.swift
//  RivuletTests
//
//  A page can be told to reload before its list has laid out (the Plex page
//  does, as it loads). The list then reads its row count for the first time
//  inside the update, and that count must be the one from before the change.
//

import XCTest
@testable import Rivulet

@MainActor
final class SettingsReloadRowsTests: XCTestCase {

    override func tearDown() async throws {
        SettingsContent.addSourceDraft = nil
        try await super.tearDown()
    }

    func test_reloadBeforeFirstLayout_withFewerRows_keepsTheListConsistent() {
        SettingsContent.addSourceDraft = AddSourceDraft()
        let page = SettingsPageViewController(page: .addXtream)
        page.loadViewIfNeeded()                 // five rows, and the list has not laid out
        SettingsContent.addSourceDraft = nil

        page.reloadRows()                       // one placeholder row

        XCTAssertEqual(page.collectionView.numberOfItems(inSection: 0), 1)
    }
}
