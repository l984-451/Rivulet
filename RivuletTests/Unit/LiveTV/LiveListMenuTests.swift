// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveListMenuTests.swift
//  RivuletTests
//
//  The iOS and Mac "Add to List" submenu and list naming: own lists only,
//  ticked where the channel is, New List… last, and a name makes or renames.
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveListMenuTests: XCTestCase {
    private let suite = "LiveListMenuTests"
    private var lists: LiveChannelListStore!
    private let channel = UnifiedChannel(id: "x:1", sourceType: .xtream, sourceId: "x", name: "NPO 1")

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suite)
        lists = LiveChannelListStore(defaults: UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func test_addToList_offersOwnListsTicked_thenNewList() throws {
        let mine = try XCTUnwrap(lists.createList(named: "Mine", with: "x:1"))
        _ = lists.createList(named: "Other", with: "x:2")
        _ = lists.createSmartList(named: "Dutch", rules: LiveSmartRules([.origin("NL")]))
        let recorder = LiveRecorder()
        let menu = LiveMenu.listMenu(for: channel, recorder: recorder, lists: lists)
        XCTAssertEqual(menu.children.map(\.title), ["Mine", "Other", String(localized: "New List…")])
        XCTAssertEqual(menu.children.first?.systemImage, "checkmark")
        menu.children[0].perform()
        XCTAssertEqual(lists.list(mine.id)?.channelIds, [])
        menu.children.last?.perform()
        XCTAssertEqual(recorder.naming?.channelId, "x:1")
    }

    func test_naming_makesAListHoldingTheChannel_orRenames() throws {
        let recorder = LiveRecorder()
        recorder.askNewList(holding: channel)
        recorder.namingText = "  Evening  "
        let id = try XCTUnwrap(recorder.commitName(lists: lists))
        XCTAssertEqual(lists.list(id)?.name, "Evening")
        XCTAssertEqual(lists.list(id)?.channelIds, ["x:1"])
        XCTAssertNil(recorder.naming)

        recorder.askRename(try XCTUnwrap(lists.list(id)))
        XCTAssertEqual(recorder.namingText, "Evening")
        recorder.namingText = "Late"
        recorder.commitName(lists: lists)
        XCTAssertEqual(lists.list(id)?.name, "Late")

        recorder.askNewList(holding: channel)
        recorder.namingText = "   "
        XCTAssertNil(recorder.commitName(lists: lists))
        XCTAssertEqual(lists.lists.count, 1)
    }
}
