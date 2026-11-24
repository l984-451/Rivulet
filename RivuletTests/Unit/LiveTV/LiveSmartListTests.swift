// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveSmartListTests.swift
//  RivuletTests
//
//  Smart channel lists: rules of one kind widen, of different kinds narrow; a
//  country comes from the category's tag, else the channel's; lists saved
//  before smart lists still load; and a smart list shows in the List layout.
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveSmartListTests: XCTestCase {
    private func ch(_ id: String, _ name: String, group: String?, source: String = "x") -> UnifiedChannel {
        UnifiedChannel(id: "\(source):\(id)", sourceType: .xtream, sourceId: source, name: name, groupTitle: group)
    }

    private lazy var lineup = [
        ch("1", "┃NL┃ NPO 1 HD", group: "┃NL┃ NEDERLAND HD"),
        ch("2", "┃NL┃ ESPN 1 HD", group: "┃NL┃ SPORT"),
        ch("3", "┃UK┃ SKY SPORTS F1", group: "┃UK┃ SPORTS"),
        ch("4", "┃BE┃ VRT 1", group: "| BE | VLAANDEREN"),
        ch("5", "BBC NEWS", group: "NEWS", source: "y"),
        ch("6", "┃FR┃ CANAL+", group: "VARIOUS"),
    ]

    private func names(_ rules: LiveSmartRules) -> [String] {
        rules.channels(in: lineup).map(\.id)
    }

    func test_sameKindWidens_differentKindsNarrow() {
        XCTAssertEqual(names(LiveSmartRules([.origin("NL")])), ["x:1", "x:2"])
        XCTAssertEqual(names(LiveSmartRules([.origin("NL"), .origin("BE")])), ["x:1", "x:2", "x:4"])
        XCTAssertEqual(names(LiveSmartRules([.origin("NL"), .genre(.sports)])), ["x:2"])
        XCTAssertEqual(names(LiveSmartRules([.genre(.sports)])), ["x:2", "x:3"])
        XCTAssertEqual(names(LiveSmartRules([.source("y")])), ["y:5"])
        XCTAssertEqual(names(LiveSmartRules([.word("bbc")])), ["y:5"])
        XCTAssertEqual(names(LiveSmartRules()), [])
    }

    func test_countryFromTheCategory_elseTheChannel_andUKIsGB() {
        XCTAssertEqual(names(LiveSmartRules([.origin("GB")])), ["x:3"])
        XCTAssertEqual(names(LiveSmartRules([.origin("FR")])), ["x:6"])
        XCTAssertEqual(LiveSmartRules.origins(in: lineup), ["BE", "NL", "GB"].sorted {
            ContentOrigin.title(forOrigin: $0).dropFirst(2) < ContentOrigin.title(forOrigin: $1).dropFirst(2)
        })
    }

    func test_genreFromTheGuide_whenNameAndCategorySayNothing() {
        let plain = [ch("9", "TV 9", group: "VARIOUS")]
        let now = Date()
        let guide = ["x:9": (0..<3).map {
            UnifiedProgram(id: "p\($0)", channelId: "x:9", title: "Match", startTime: now, endTime: now, category: "Football")
        }]
        XCTAssertEqual(LiveSmartRules([.genre(.sports)]).channels(in: plain, epg: guide).map(\.id), ["x:9"])
        XCTAssertTrue(LiveSmartRules([.genre(.sports)]).channels(in: plain).isEmpty)
    }

    func test_followsTheLineup() {
        let rules = LiveSmartRules([.origin("NL")])
        XCTAssertEqual(rules.channels(in: lineup).count, 2)
        lineup.append(ch("7", "┃NL┃ RTL 4", group: "┃NL┃ NEDERLAND HD"))
        XCTAssertEqual(rules.channels(in: lineup).count, 3)
    }

    func test_ruleEditing_keepsOneOfEach() {
        var rules = LiveSmartRules([.origin("NL"), .origin("NL"), .word("  ")])
        XCTAssertEqual(rules.rules, [.origin("NL")])
        rules.add(.genre(.news))
        rules.remove(.origin("NL"))
        XCTAssertEqual(rules.rules, [.genre(.news)])
    }

    func test_origins_readAsTheViewerDoes() {
        XCTAssertEqual(ContentOrigin.origin(forTag: "UK"), "GB")
        XCTAssertEqual(ContentOrigin.origin(forTag: "FR-4K"), "FR")
        XCTAssertEqual(ContentOrigin.origin(forTag: "MULTI / LINGO"), "MULTI")
        XCTAssertNil(ContentOrigin.origin(forTag: "PPV"))
        XCTAssertTrue(ContentOrigin.title(forOrigin: "NL").hasPrefix("🇳🇱 "))
        XCTAssertFalse(ContentOrigin.title(forOrigin: "KURD").contains("KURD"))
        XCTAssertEqual(ContentOrigin.marker(forTag: "UK"), "🇬🇧")
    }

    func test_store_smartLists_areSaved_andTakeNoChannelByHand() throws {
        let suite = "LiveSmartListTests"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = LiveChannelListStore(defaults: defaults)
        XCTAssertNil(store.createSmartList(named: "Empty", rules: LiveSmartRules()))
        let list = try XCTUnwrap(store.createSmartList(named: "Sport NL", rules: LiveSmartRules([.origin("NL")])))
        store.toggle("x:9", in: list.id)
        store.setRules(LiveSmartRules(), for: list.id)
        store.setRules(LiveSmartRules([.origin("NL"), .genre(.sports)]), for: list.id)
        let reloaded = LiveChannelListStore(defaults: defaults).list(list.id)
        XCTAssertEqual(reloaded?.channelIds, [])
        XCTAssertEqual(reloaded?.rules?.rules, [.origin("NL"), .genre(.sports)])
    }

    func test_listsSavedBeforeSmartLists_stillLoad() throws {
        let json = #"[{"id":"a","name":"Mine","channelIds":["x:1"]}]"#
        let lists = try JSONDecoder().decode([LiveChannelList].self, from: Data(json.utf8))
        XCTAssertEqual(lists.first?.channelIds, ["x:1"])
        XCTAssertFalse(lists.first?.isSmart ?? true)
    }

    func test_smartListShowsInTheListLayout_withItsMatches() {
        let smart = LiveChannelList(id: "s", name: "Sport", channelIds: [], rules: LiveSmartRules([.genre(.sports)]))
        let empty = LiveChannelList(id: "e", name: "Nothing", channelIds: [], rules: LiveSmartRules([.origin("JP")]))
        let list = LiveCategoryList.build(LiveCategoryList.Input(channels: lineup, sources: [("x", "A"), ("y", "B")],
                                                                 lists: [smart, empty]))
        XCTAssertEqual(list.channels(in: "list|s").map(\.id), ["x:2", "x:3"])
        XCTAssertNil(list.category("list|e"))
    }

    func test_draft_newList_takesTheFirstRulesName_andReadsTheWords() throws {
        let suite = "LiveSmartListDraftTests"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LiveChannelListStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        var draft = LiveSmartListDraft(listId: nil, store: store)
        XCTAssertFalse(draft.canSave)
        draft.set(.genre(.news), on: true)
        draft.wordsText = "bbc, , cnn "
        let id = try XCTUnwrap(draft.save(store: store))
        let list = try XCTUnwrap(store.list(id))
        XCTAssertEqual(list.name, LiveGenre.news.title)
        XCTAssertEqual(list.rules?.rules, [.genre(.news), .word("bbc"), .word("cnn")])
        XCTAssertEqual(LiveChannelList.forFilter(list.filterTag, store: store)?.id, id)
        XCTAssertNil(LiveChannelList.forFilter("NEWS", store: store))

        var edit = LiveSmartListDraft(listId: id, store: store)
        XCTAssertEqual(edit.wordsText, "bbc, cnn")
        edit.set(.genre(.news), on: false)
        edit.set(.origin("NL"), on: true)
        edit.wordsText = ""
        edit.name = "Dutch"
        edit.save(store: store)
        XCTAssertEqual(store.list(id)?.name, "Dutch")
        XCTAssertEqual(store.list(id)?.rules?.rules, [.origin("NL")])
    }

    func test_matchesAreKeptPerVersion_andARegroupWithTheSameShapeIsSeen() {
        let rules = LiveSmartRules([.origin("NL")])
        let v1 = LiveSmartRules.Versions(channels: 101, epg: 0)
        XCTAssertEqual(rules.channels(in: lineup, versions: v1).map(\.id), ["x:1", "x:2"])
        // Same size, same ends, a middle channel regrouped: a new lineup version, a fresh match.
        lineup[1] = ch("2", "┃BE┃ ESPN 1 HD", group: "| BE | SPORT")
        XCTAssertEqual(rules.channels(in: lineup, versions: LiveSmartRules.Versions(channels: 102, epg: 0)).map(\.id),
                       ["x:1"])
    }

    func test_listNames_stayUnique() throws {
        let suite = "LiveSmartListNameTests"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = LiveChannelListStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let first = try XCTUnwrap(store.createSmartList(named: "Sports", rules: LiveSmartRules([.genre(.sports)])))
        let second = try XCTUnwrap(store.createList(named: "sports", with: "x:1"))
        XCTAssertEqual(second.name, "sports 2")
        store.rename(first.id, to: "Sports")
        XCTAssertEqual(store.list(first.id)?.name, "Sports")
        store.rename(second.id, to: "Sports")
        XCTAssertEqual(store.list(second.id)?.name, "Sports 2")
    }
}
