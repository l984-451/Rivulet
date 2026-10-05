// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveShelvesTests.swift
//  RivuletTests
//
//  What's On's rows: their order, what each holds, and the pregame block that
//  stands in for the game after it.
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveShelvesTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func channel(_ id: String, group: String, number: Int) -> UnifiedChannel {
        UnifiedChannel(id: id, sourceType: .genericM3U, sourceId: "s", channelNumber: number, name: id,
                       groupTitle: group)
    }

    private func program(_ channelId: String, _ title: String, from start: TimeInterval, to end: TimeInterval) -> UnifiedProgram {
        UnifiedProgram(id: "\(channelId):\(start)", channelId: channelId, title: title,
                       startTime: now.addingTimeInterval(start), endTime: now.addingTimeInterval(end))
    }

    func test_representativeBuild() throws {
        let channels = [
            channel("news", group: "Local", number: 1),
            channel("game", group: "Sports", number: 2),
            channel("film", group: "Local", number: 3),
            channel("empty", group: "Sports", number: 4),
        ]
        let pregame = "UPCOMING: Team A at Team B"
        let epg = [
            "news": [program("news", "Evening News", from: -600, to: 1200),
                     program("news", "Weather", from: 1200, to: 3000)],
            "game": [program("game", pregame, from: -600, to: 900),
                     program("game", "Team A at Team B", from: 900, to: 9000)],
            "film": [program("film", "A Film", from: -3600, to: 3600)],
            "empty": [program("empty", "No Game Scheduled", from: -600, to: 600)],
        ]
        let recording = LiveTVScheduledRecording(id: "r1", sourceId: "s", title: "A Film", subtitle: nil,
                                                 startTime: now.addingTimeInterval(-3600),
                                                 endTime: now.addingTimeInterval(3600), status: .recording,
                                                 channelName: nil, channelId: "film", programGuid: nil,
                                                 ruleId: nil, posterURL: nil)

        let shelves = LiveShelves.build(LiveShelves.Input(
            channels: channels, epg: epg, recentChannelIds: ["film", "gone"], favoriteIds: ["empty", "news"],
            suggestionsEnabled: false, scheduledRecordings: [recording]), sourceIdFilter: nil, now: now)

        XCTAssertEqual(shelves.map(\.id), ["recent", "recordings", "favorites", "now", "soon",
                                           "group|Local", "group|Sports"])
        XCTAssertEqual(shelves.map(\.title), ["Recently Watched", "Recordings", "Favorites", "On Now",
                                              "Starting Soon", "Local", "Sports"])
        let items = Dictionary(uniqueKeysWithValues: shelves.map { ($0.id, $0.items) })

        // The film is recording, so its cards say so.
        XCTAssertEqual(items["recent"]?.map(\.id), ["recent|film"])
        XCTAssertEqual(items["recent"]?.first?.setToRecord, true)
        XCTAssertEqual(items["recordings"]?.map(\.id), ["rec|r1"])
        // Favorites keep a chosen empty slot; On Now drops it and the pregame block.
        XCTAssertEqual(items["favorites"]?.map(\.id), ["favorites|empty", "favorites|news"])
        XCTAssertEqual(items["now"]?.map(\.id), ["now|news", "now|film"])
        // Starting Soon: next programmes inside 90 minutes, soonest first.
        XCTAssertEqual(items["soon"]?.map { $0.program?.title }, ["Team A at Team B", "Weather"])
        // In a group row the pregame block is the game it holds.
        let game = try XCTUnwrap(items["group|Sports"]?.first)
        XCTAssertEqual(game.kind, .upcoming)
        XCTAssertEqual(game.id, "group|Sports|game:900.0")
        XCTAssertEqual(game.program?.title, "Team A at Team B")
    }

    func test_sourceFilter() {
        let other = UnifiedChannel(id: "x", sourceType: .plex, sourceId: "p", name: "x")
        let shelves = LiveShelves.build(LiveShelves.Input(
            channels: [channel("news", group: "", number: 1), other],
            epg: ["x": [program("x", "Show", from: -60, to: 60)], "news": [program("news", "News", from: -60, to: 60)]],
            suggestionsEnabled: false), sourceIdFilter: "p", now: now)
        XCTAssertEqual(shelves.map(\.id), ["now"])
        XCTAssertEqual(shelves.first?.items.map(\.id), ["now|x"])
    }
}
