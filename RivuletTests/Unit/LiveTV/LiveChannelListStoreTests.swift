// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveChannelListStoreTests.swift
//  RivuletTests
//
//  The viewer's own channel lists and pinned categories, and that they keep.
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveChannelListStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "LiveChannelListStoreTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func test_listLifecycle_isSaved() {
        let store = LiveChannelListStore(defaults: defaults)
        let made = store.createList(named: "  Evening ", with: "a")
        XCTAssertEqual(made?.name, "Evening")
        let id = try! XCTUnwrap(made?.id)
        store.toggle("b", in: id)
        store.toggle("a", in: id)
        store.rename(id, to: "Late")

        let reloaded = LiveChannelListStore(defaults: defaults)
        XCTAssertEqual(reloaded.lists, [LiveChannelList(id: id, name: "Late", channelIds: ["b"])])

        reloaded.delete(id)
        XCTAssertTrue(LiveChannelListStore(defaults: defaults).lists.isEmpty)
    }

    func test_blankNames_makeAndRenameNothing() {
        let store = LiveChannelListStore(defaults: defaults)
        XCTAssertNil(store.createList(named: "   ", with: "a"))
        let id = try! XCTUnwrap(store.createList(named: "A", with: "a")?.id)
        store.rename(id, to: " ")
        XCTAssertEqual(store.list(id)?.name, "A")
    }

    func test_pins_toggle_inOrder_andAreSaved() {
        let store = LiveChannelListStore(defaults: defaults)
        store.togglePin("x|Kids")
        store.togglePin("x|News")
        store.togglePin("x|Kids")
        store.togglePin("x|Kids")
        XCTAssertEqual(LiveChannelListStore(defaults: defaults).pinnedCategoryKeys, ["x|News", "x|Kids"])
        XCTAssertTrue(store.isPinned("x|News"))
    }

    func test_tabTitle_setsAClashingListApart() {
        let list = LiveChannelList(id: "L1", name: "Sport", channelIds: [])
        XCTAssertEqual(list.tabTitle(taken: ["News"]), "Sport")
        XCTAssertEqual(list.tabTitle(taken: ["Sport", "News"]), "Sport (List)")
    }
}
