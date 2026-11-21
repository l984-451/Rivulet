// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveCategoryListTests.swift
//  RivuletTests
//
//  The List layout's category column, its channels and the guide each row opens.
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveCategoryListTests: XCTestCase {
    private func ch(_ id: String, _ group: String?, source: String = "x", rank: Int? = nil,
                    favourite: Bool = false) -> UnifiedChannel {
        UnifiedChannel(id: "\(source):\(id)", sourceType: .xtream, sourceId: source, name: id,
                       groupTitle: group, isFavourite: favourite, groupRank: rank)
    }

    private func build(_ channels: [UnifiedChannel], sources: [(id: String, name: String)] = [("x", "Provider A")],
                       favorites: [String] = [], recents: [String] = [], filter: String? = nil,
                       collapsed: Set<String> = [], lists: [LiveChannelList] = [],
                       pins: [String] = []) -> LiveCategoryList {
        LiveCategoryList.build(LiveCategoryList.Input(
            channels: channels, sources: sources, favoriteIds: favorites, recentChannelIds: recents,
            sourceIdFilter: filter, collapsedSourceIds: collapsed, lists: lists, pinnedKeys: pins))
    }

    private func kinds(_ list: LiveCategoryList) -> [LiveCategory.Kind] { list.categories.map(\.kind) }
    private func names(_ channels: [UnifiedChannel]) -> [String] { channels.map(\.name) }

    // MARK: - Column

    func test_fixedRowsFirst_thenGroupsInProviderOrder() {
        let list = build([ch("a", "Sport", rank: 1), ch("b", "News", rank: 0), ch("c", "Sport", rank: 1)],
                         favorites: ["x:a"], recents: ["x:b"])
        XCTAssertEqual(kinds(list), [.recent, .favorites, .all, .group("News"), .group("Sport")])
        XCTAssertEqual(list.categories.map(\.channelCount), [1, 1, 3, 1, 2])
    }

    func test_emptyRecentAndFavorites_areLeftOut() {
        XCTAssertEqual(kinds(build([ch("a", "Sport")])), [.all, .group("Sport")])
    }

    func test_ungroupedChannels_onlyUnderAllChannels() {
        let list = build([ch("a", nil), ch("b", "  "), ch("c", " Kids ")])
        XCTAssertEqual(kinds(list), [.all, .group("Kids")])
        XCTAssertEqual(names(list.channels(in: LiveCategoryList.id(.all, sourceId: nil))), ["a", "b", "c"])
    }

    func test_emptyInput_isEmpty() {
        let list = build([])
        XCTAssertTrue(list.categories.isEmpty)
        XCTAssertTrue(list.channels(in: "all|").isEmpty)
    }

    func test_twoSources_getSections_withTheirOwnAllChannels() {
        let list = build([ch("a", "Kids", source: "x"), ch("b", "Kids", source: "m"), ch("c", "Music", source: "m")],
                         sources: [("x", "Provider A"), ("m", "Provider B")])
        XCTAssertEqual(list.categories.map(\.title),
                       ["All Channels", "Provider A", "All Channels", "Kids", "Provider B", "All Channels", "Kids", "Music"])
        // The same group name stays apart under each source.
        XCTAssertEqual(names(list.channels(in: LiveCategoryList.id(.group("Kids"), sourceId: "x"))), ["a"])
        XCTAssertEqual(names(list.channels(in: LiveCategoryList.id(.group("Kids"), sourceId: "m"))), ["b"])
    }

    func test_sourceFilter_showsOneSource_withoutHeaders() {
        let list = build([ch("a", "Kids", source: "x"), ch("b", "Music", source: "m")],
                         sources: [("x", "Provider A"), ("m", "Provider B")], filter: "m")
        XCTAssertEqual(kinds(list), [.all, .group("Music")])
        XCTAssertEqual(list.categories.first?.channelCount, 1)
    }

    func test_oneSourceInView_hasNoHeader() {
        XCTAssertFalse(kinds(build([ch("a", "Kids")])).contains(.sourceHeader))
    }

    func test_collapsedSource_keepsItsHeader_andItsChannels() {
        let channels = [ch("a", "Kids", source: "x"), ch("b", "Music", source: "m")]
        let sources: [(id: String, name: String)] = [("x", "Provider A"), ("m", "Provider B")]
        let list = build(channels, sources: sources, collapsed: ["x"])
        XCTAssertEqual(list.categories.map(\.id),
                       ["all|", "source|x", "source|m", "all|m", "group|m|Music"])
        // A selected row that folded away still has its list.
        XCTAssertEqual(names(list.channels(in: "group|x|Kids")), ["a"])
    }

    func test_groupNamesWithSeparators_arePlainText() {
        let list = build([ch("a", "NL | Sport")])
        XCTAssertEqual(list.categories.last?.kind, .group("NL | Sport"))
        XCTAssertEqual(list.guideTarget(for: "group||NL | Sport"), LiveGuideTarget(sourceId: nil, tab: .group("NL | Sport")))
    }

    // MARK: - Channels

    func test_channelInSeveralRows_appearsInEach() {
        let list = build([ch("a", "Sport"), ch("b", "News")], favorites: ["x:a"], recents: ["x:a"])
        XCTAssertEqual(names(list.channels(in: "recent")), ["a"])
        XCTAssertEqual(names(list.channels(in: "favorites")), ["a"])
        XCTAssertEqual(names(list.channels(in: "all|")), ["a", "b"])
        XCTAssertEqual(names(list.channels(in: "group||Sport")), ["a"])
    }

    func test_recents_newestFirst_andFavorites_asArranged() {
        let list = build([ch("a", "S"), ch("b", "S"), ch("c", "S")], favorites: ["x:c", "x:a"], recents: ["x:b", "x:c"])
        XCTAssertEqual(names(list.channels(in: "recent")), ["b", "c"])
        XCTAssertEqual(names(list.channels(in: "favorites")), ["c", "a"])
    }

    func test_sourceFavorites_count_andRemovingOneOnlyChangesFavorites() {
        // "a" is a favourite on the source (Plex), "b" one made in Rivulet.
        let channels = [ch("a", "S", favourite: true), ch("b", "S")]
        let before = build(channels, favorites: ["x:b"])
        let after = build(channels)
        XCTAssertEqual(before.category("favorites")?.channelCount, 2)
        XCTAssertEqual(after.category("favorites")?.channelCount, 1)
        XCTAssertNil(build([ch("b", "S")]).category("favorites"))
        XCTAssertEqual(before.categories.filter { $0.kind != .favorites }, after.categories.filter { $0.kind != .favorites })
    }

    func test_duplicateChannelInLineup_listedOnce() {
        let list = build([ch("a", "S"), ch("a", "S")])
        XCTAssertEqual(list.category("all|")?.channelCount, 1)
        XCTAssertEqual(list.channels(in: "group||S").count, 1)
    }

    // MARK: - Guide

    func test_guideTargets() {
        let list = build([ch("a", "Kids", source: "x"), ch("b", "Kids", source: "m")],
                         sources: [("x", "Provider A"), ("m", "Provider B")], favorites: ["x:a"], recents: ["m:b"])
        XCTAssertEqual(list.guideTarget(for: "recent"), LiveGuideTarget(sourceId: nil, tab: .all))
        XCTAssertEqual(list.guideTarget(for: "favorites"), LiveGuideTarget(sourceId: nil, tab: .favorites))
        XCTAssertEqual(list.guideTarget(for: "all|"), LiveGuideTarget(sourceId: nil, tab: .all))
        XCTAssertEqual(list.guideTarget(for: "all|m"), LiveGuideTarget(sourceId: "m", tab: .all))
        // Only Provider B's Kids, which is what the list showed.
        XCTAssertEqual(list.guideTarget(for: "group|m|Kids"), LiveGuideTarget(sourceId: "m", tab: .group("Kids")))
        XCTAssertNil(list.guideTarget(for: "source|m"))
    }

    func test_guideTargets_underASourceFilter_keepTheFilter() {
        let list = build([ch("a", "Kids", source: "m")], sources: [("m", "Provider B")], filter: "m")
        XCTAssertEqual(list.guideTarget(for: "group||Kids"), LiveGuideTarget(sourceId: "m", tab: .group("Kids")))
        XCTAssertEqual(list.categoryId(for: LiveGuideTarget(sourceId: "m", tab: .group("Kids"))), "group||Kids")
        XCTAssertEqual(list.categoryId(for: LiveGuideTarget(sourceId: "m", tab: .all)), "all|")
    }

    func test_backFromGuide_findsTheTabsRow() {
        let list = build([ch("a", "Kids", source: "x"), ch("b", "Kids", source: "m"), ch("c", "Music", source: "m")],
                         sources: [("x", "Provider A"), ("m", "Provider B")], favorites: ["x:a"])
        XCTAssertEqual(list.categoryId(for: LiveGuideTarget(sourceId: "m", tab: .group("Music"))), "group|m|Music")
        XCTAssertEqual(list.categoryId(for: LiveGuideTarget(sourceId: "m", tab: .all)), "all|m")
        XCTAssertEqual(list.categoryId(for: LiveGuideTarget(sourceId: nil, tab: .favorites)), "favorites")
        // The combined guide: a source's own tab, then a merged group's first source.
        XCTAssertEqual(list.categoryId(for: LiveGuideTarget(sourceId: nil, tab: .group("Provider B"))), "all|m")
        XCTAssertEqual(list.categoryId(for: LiveGuideTarget(sourceId: nil, tab: .group("Kids"))), "group|x|Kids")
        XCTAssertNil(list.categoryId(for: LiveGuideTarget(sourceId: "m", tab: .group("Gone"))))
    }

    // MARK: - Own lists and pins

    func test_ownLists_followFavorites_inTheirOwnOrder_andEmptyOnesAreLeftOut() {
        let lists = [LiveChannelList(id: "L1", name: "Evening", channelIds: ["x:c", "x:a", "x:gone"]),
                     LiveChannelList(id: "L2", name: "Empty", channelIds: ["x:gone"])]
        let list = build([ch("a", "S"), ch("b", "S"), ch("c", "N")], favorites: ["x:b"], lists: lists)
        XCTAssertEqual(kinds(list), [.favorites, .list("L1"), .all, .group("S"), .group("N")])
        XCTAssertEqual(names(list.channels(in: "list|L1")), ["c", "a"])
        XCTAssertEqual(list.category("list|L1")?.title, "Evening")
    }

    func test_pinnedGroup_getsACopyAboveTheSections_andKeepsItsPlace() {
        let channels = [ch("a", "Kids", source: "x"), ch("b", "Kids", source: "m"), ch("c", "Music", source: "m")]
        let sources: [(id: String, name: String)] = [("x", "Provider A"), ("m", "Provider B")]
        let key = LiveCategoryList.pinKey(sourceId: "m", title: "Kids")
        let list = build(channels, sources: sources, pins: [key])
        XCTAssertEqual(list.categories.map(\.id),
                       ["all|", "pin|\(key)", "source|x", "all|x", "group|x|Kids", "source|m", "all|m", "group|m|Kids",
                        "group|m|Music"])
        // Only Provider B's Kids, and the guide limited to it.
        XCTAssertEqual(names(list.channels(in: "pin|\(key)")), ["b"])
        XCTAssertEqual(list.guideTarget(for: "pin|\(key)"), LiveGuideTarget(sourceId: "m", tab: .group("Kids")))
        XCTAssertEqual(list.category("group|m|Kids")?.pinKey, key)
        XCTAssertTrue(list.category("pin|\(key)")?.isPinnedCopy == true)
    }

    func test_pinKey_isTheSameWithAndWithoutSections() {
        let key = LiveCategoryList.pinKey(sourceId: "x", title: "Kids")
        XCTAssertEqual(build([ch("a", "Kids")]).category("group||Kids")?.pinKey, key)
        let sectioned = build([ch("a", "Kids"), ch("b", "Kids", source: "m")],
                              sources: [("x", "A"), ("m", "B")])
        XCTAssertEqual(sectioned.category("group|x|Kids")?.pinKey, key)
    }

    func test_pinOfAGroupThatIsGone_showsNothing() {
        XCTAssertNil(build([ch("a", "Kids")], pins: ["x|Gone"]).categories.first { $0.isPinnedCopy })
    }

    func test_ownList_opensItsGuideTab_andComesBackToIt() {
        let lists = [LiveChannelList(id: "L1", name: "Evening", channelIds: ["x:a"])]
        let list = build([ch("a", "S")], lists: lists)
        XCTAssertEqual(list.guideTarget(for: "list|L1"), LiveGuideTarget(sourceId: nil, tab: .list("L1")))
        XCTAssertEqual(list.categoryId(for: LiveGuideTarget(sourceId: nil, tab: .list("L1"))), "list|L1")
    }

    func test_backFromGuide_onAPinnedGroup_landsOnTheGroupInItsSection() {
        let channels = [ch("a", "Kids", source: "x"), ch("b", "Kids", source: "m")]
        let list = build(channels, sources: [("x", "A"), ("m", "B")],
                         pins: [LiveCategoryList.pinKey(sourceId: "m", title: "Kids")])
        XCTAssertEqual(list.categoryId(for: LiveGuideTarget(sourceId: nil, tab: .group("Kids"))), "group|x|Kids")
    }

    func test_backFromGuide_onTheSameTab_staysOnTheRowItOpenedFrom() {
        let channels = [ch("a", "Kids", source: "x"), ch("b", "Kids", source: "m")]
        let key = LiveCategoryList.pinKey(sourceId: "m", title: "Kids")
        let list = build(channels, sources: [("x", "A"), ("m", "B")], recents: ["m:b"], pins: [key])
        let all = LiveGuideTarget(sourceId: nil, tab: .all)
        // Recently Watched opens All Channels; unchanged, it comes back to itself.
        XCTAssertEqual(list.categoryId(backFrom: all, openedFrom: "recent", channelId: "m:b"), "recent")
        // On a channel it does not hold, the tab's own row has it.
        XCTAssertEqual(list.categoryId(backFrom: all, openedFrom: "recent", channelId: "x:a"), "all|")
        let kids = LiveGuideTarget(sourceId: "m", tab: .group("Kids"))
        XCTAssertEqual(list.categoryId(backFrom: kids, openedFrom: "pin|\(key)", channelId: "m:b"), "pin|\(key)")
        // Another tab chosen in the guide: that tab's row.
        XCTAssertEqual(list.categoryId(backFrom: LiveGuideTarget(sourceId: "m", tab: .all),
                                       openedFrom: "pin|\(key)", channelId: "m:b"), "all|m")
    }

    // MARK: - Group names

    func test_groupNames_withoutTags_unlessTwoWouldReadTheSame() {
        let names = LiveGroupDisplay.names(["| PPV | UFC PPV", "| XX | SPORTS", "| YY | SPORTS", "Kids"])
        XCTAssertEqual(names["| PPV | UFC PPV"], "UFC PPV")
        // Tags with no place to flag would read the same: full names.
        XCTAssertEqual(names["| XX | SPORTS"], "| XX | SPORTS")
        XCTAssertEqual(names["Kids"], "Kids")
        let list = build([ch("a", "| NL | NEDERLAND HD"), ch("b", "| NL | NEDERLAND HD")])
        let group = list.categories.first { $0.kind == .group("| NL | NEDERLAND HD") }
        XCTAssertEqual(group?.title, "🇳🇱 NEDERLAND HD")
        // Still opened and matched by its own title.
        XCTAssertEqual(group.flatMap { list.guideTarget(for: $0.id) }?.tab, .group("| NL | NEDERLAND HD"))
    }

    // MARK: - Numbers

    func test_xtreamNumbers_areNotShown_otherSourcesKeepTheirs() {
        let xtream = UnifiedChannel(id: "x:1", sourceType: .xtream, sourceId: "x", channelNumber: 4318, name: "NPO 1")
        let tuner = UnifiedChannel(id: "p:1", sourceType: .plex, sourceId: "p", channelNumber: 7, name: "BBC One")
        XCTAssertNil(xtream.displayNumber)
        XCTAssertEqual(xtream.displayNumberAndName, "NPO 1")
        XCTAssertEqual(tuner.displayNumberAndName, "7 · BBC One")
        let tagged = UnifiedChannel(id: "x:2", sourceType: .xtream, sourceId: "x", name: "UK |  SKY SPORTS F1")
        XCTAssertEqual(tagged.displayName, "SKY SPORTS F1")
        XCTAssertEqual(UnifiedChannel(id: "p:2", sourceType: .plex, sourceId: "p", name: "UK | BBC").displayName, "UK | BBC")
        // Number search still finds the panel's number.
        XCTAssertEqual(LiveChannelSearch.search("4318", in: LiveChannelSearch.Index([xtream])).channels.map(\.id), ["x:1"])
    }

    // MARK: - Now and next

    func test_nowNext_skipsPlaceholders_andMeasuresProgress() {
        let now = Date(timeIntervalSince1970: 10_000)
        func program(_ id: String, _ start: Double, _ end: Double) -> UnifiedProgram {
            UnifiedProgram(id: id, channelId: "c", title: id, startTime: Date(timeIntervalSince1970: start),
                           endTime: Date(timeIntervalSince1970: end))
        }
        let guide = [program("c:placeholder:1", 9_000, 11_000), program("on", 9_000, 11_000), program("next", 11_000, 12_000)]
        let nowNext = LiveNowNext.of(guide, at: now)
        XCTAssertEqual(nowNext.current?.id, "on")
        XCTAssertEqual(nowNext.next?.id, "next")
        XCTAssertEqual(nowNext.progress(at: now) ?? 0, 0.5, accuracy: 0.001)
        let none = LiveNowNext.of([program("c:placeholder:1", 9_000, 11_000)], at: now)
        XCTAssertNil(none.current)
        XCTAssertNil(none.progress(at: now))
        XCTAssertNil(LiveNowNext.of(nil, at: now).current)
    }

    // MARK: - Size

    /// 20,000 channels in 300 groups over two sources. No threshold yet: the
    /// first measured runs set one.
    func test_largeLineup_buildTime() {
        let channels = (0..<20_000).map { i in
            ch("\(i)", "Group \(i % 300)", source: i % 2 == 0 ? "x" : "m", rank: i % 300)
        }
        let sources: [(id: String, name: String)] = [("x", "Provider A"), ("m", "Provider B")]
        measure {
            let list = build(channels, sources: sources, recents: ["x:0", "m:1"])
            XCTAssertEqual(list.category("all|")?.channelCount, 20_000)
        }
    }
}
