// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveGroupOrderTests.swift
//  RivuletTests
//
//  Channel groups keep the order the source publishes (#568).
//

import XCTest
@testable import Rivulet

final class LiveGroupOrderTests: XCTestCase {
    private func ch(_ id: String, _ group: String?, source: String = "s1", rank: Int? = nil, number: Int = 0) -> UnifiedChannel {
        UnifiedChannel(id: id, sourceType: .genericM3U, sourceId: source, channelNumber: ChannelNumber(major: number),
                       name: id, groupTitle: group, groupRank: rank)
    }

    func test_m3u_firstAppearance_evenWhenMergedListIsSortedByNumber() {
        // File order: Zulu, Alpha. The merged list is number-sorted, so Alpha's channel comes first.
        let file = [ch("a", "Zulu", number: 9), ch("b", "Alpha", number: 5), ch("c", "Zulu", number: 1)]
        let merged = LiveGroupOrder.ranked(file).sorted { $0.channelNumber! < $1.channelNumber! }
        XCTAssertEqual(LiveGroupOrder.titles(in: merged), ["Zulu", "Alpha"])
    }

    func test_xtream_categoryOrderBeatsChannelOrder() {
        let channels = [ch("a", "Alpha", rank: 1), ch("b", "Zulu", rank: 0), ch("c", "Orphan")]
        XCTAssertEqual(LiveGroupOrder.titles(in: channels), ["Zulu", "Alpha", "Orphan"])
    }

    func test_twoSources_followSourceOrder_thenOwnOrder() {
        let channels = [ch("a", "News", source: "2", rank: 0), ch("b", "Sports", source: "1", rank: 1),
                        ch("c", "Movies", source: "1", rank: 0), ch("d", "Sports", source: "2", rank: 1)]
        XCTAssertEqual(LiveGroupOrder.titles(in: channels, sourceOrder: ["1", "2"]), ["Movies", "Sports", "News"])
        XCTAssertEqual(LiveGroupOrder.titles(in: channels, sourceOrder: ["2", "1"]), ["News", "Sports", "Movies"])
    }

    func test_noRanks_fallBackToListPosition_andBlanksDrop() {
        let channels = [ch("a", " Kids "), ch("b", ""), ch("c", nil), ch("d", "Adult"), ch("e", "Kids")]
        XCTAssertEqual(LiveGroupOrder.titles(in: channels), ["Kids", "Adult"])
    }
}
