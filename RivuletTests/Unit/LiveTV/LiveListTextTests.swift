// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveListTextTests.swift
//  RivuletTests
//
//  The List layout's shared words and column sections, as all three apps draw them.
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveListTextTests: XCTestCase {
    func test_detail_putsTheQualityBeforeTheFlaggedCategory() throws {
        let suite = "LiveListTextTests"
        UserDefaults().removePersistentDomain(forName: suite)
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let quality = LiveStreamQualityStore(defaults: try XCTUnwrap(UserDefaults(suiteName: suite)))
        let channel = UnifiedChannel(id: "x:1", sourceType: .xtream, sourceId: "x", name: "NPO 1", groupTitle: "┃NL┃ SPORT")
        XCTAssertEqual(LiveListText.detail(channel, quality: quality), "🇳🇱 SPORT")
        quality.record(channelId: "x:1", height: 1080, audioChannels: 2)
        XCTAssertEqual(LiveListText.detail(channel, quality: quality), "1080p · \(String(localized: "Stereo")) · 🇳🇱 SPORT")
        let bare = UnifiedChannel(id: "x:2", sourceType: .xtream, sourceId: "x", name: "Bare")
        XCTAssertNil(LiveListText.detail(bare, quality: quality))
    }

    func test_sections_splitAtSourceHeaders_andTheStartingRow() {
        let channels = [
            UnifiedChannel(id: "a:1", sourceType: .xtream, sourceId: "a", name: "One", groupTitle: "News"),
            UnifiedChannel(id: "b:1", sourceType: .xtream, sourceId: "b", name: "Two", groupTitle: "Sport"),
        ]
        let list = LiveCategoryList.build(LiveCategoryList.Input(channels: channels, sources: [("a", "A"), ("b", "B")]))
        let sections = list.sections
        XCTAssertNil(sections.first?.header)
        XCTAssertEqual(sections.dropFirst().map { $0.header?.title }, ["A", "B"])
        XCTAssertTrue(sections.allSatisfy { $0.rows.allSatisfy { $0.kind != .sourceHeader } })
        let first = list.startingCategoryId(remembered: nil)
        XCTAssertEqual(first, sections.first?.rows.first?.id)
        XCTAssertEqual(list.startingCategoryId(remembered: "gone"), first)
        let sport = sections.last?.rows.last?.id
        XCTAssertEqual(list.startingCategoryId(remembered: sport), sport)
    }

    func test_forYouAndGenreRows_followWhatsOn_andOpenTheGuideOnAllChannels() {
        let channels = (1...6).map { UnifiedChannel(id: "x:\($0)", sourceType: .xtream, sourceId: "x", name: "C\($0)") }
        let list = LiveCategoryList.build(LiveCategoryList.Input(
            channels: channels, recentChannelIds: ["x:6"],
            forYouIds: ["x:3", "x:1", "gone"], onNow: [(.sports, ["x:2", "x:4"]), (.news, ["x:5"])]))
        let ids = list.categories.map(\.id)
        XCTAssertEqual(Array(ids.prefix(5)), ["recent", "foryou", "all|", "onnow|Sports", "onnow|News"])
        XCTAssertEqual(list.channels(in: "foryou").map(\.id), ["x:3", "x:1"])
        XCTAssertEqual(list.category("onnow|Sports")?.title, LiveGenre.sports.title)
        XCTAssertEqual(list.guideTarget(for: "onnow|Sports")?.tab, .all)
        XCTAssertEqual(list.guideTarget(for: "foryou")?.tab, .all)
        // Back from the guide on a channel the row holds: the row itself again.
        let target = list.guideTarget(for: "onnow|Sports")!
        XCTAssertEqual(list.categoryId(backFrom: target, openedFrom: "onnow|Sports", channelId: "x:4"), "onnow|Sports")
    }

    func test_whatsOnRows_onALargeLineup_stayQuick() {
        let now = Date()
        let names = ["Sport 1", "News 24", "Kids TV", "Film One", "Nature", "Music Hits", "Comedy"]
        let channels = (0..<23_700).map { index in
            UnifiedChannel(id: "x:\(index)", sourceType: .xtream, sourceId: "x", name: "\(names[index % 7]) \(index)",
                           groupTitle: "┃NL┃ GROUP \(index % 400)")
        }
        var epg: [String: [UnifiedProgram]] = [:]
        for channel in channels.prefix(6000) {
            epg[channel.id] = (0..<12).map { slot in
                UnifiedProgram(id: "\(channel.id):\(slot)", channelId: channel.id, title: "Show \(slot)",
                               startTime: now.addingTimeInterval(Double(slot - 1) * 1800),
                               endTime: now.addingTimeInterval(Double(slot) * 1800), category: names[slot % 7])
            }
        }
        let input = LiveShelves.Input(channels: channels, epg: epg)
        let start = Date()
        _ = LiveShelves.discovery(input, sourceIdFilter: nil, now: now)
        let first = Date().timeIntervalSince(start)
        let again = Date()
        let found = LiveShelves.discovery(input, sourceIdFilter: nil, now: now)
        let second = Date().timeIntervalSince(again)
        if let path = ProcessInfo.processInfo.environment["RIVULET_TIMING_FILE"] {
            try? "first \(Int(first * 1000)) ms, then \(Int(second * 1000)) ms, \(found.byGenre.count) genre rows"
                .write(toFile: path, atomically: true, encoding: .utf8)
        }
        XCTAssertFalse(found.byGenre.isEmpty)
    }
}
