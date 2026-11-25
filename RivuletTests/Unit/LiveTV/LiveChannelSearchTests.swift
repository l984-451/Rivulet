// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveChannelSearchTests.swift
//  RivuletTests
//
//  Looking up a channel by name, number or call sign, and by what is on now.
//

import XCTest
@testable import Rivulet

@MainActor
final class LiveChannelSearchTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100_000)

    private func ch(_ id: String, _ name: String, number: Int? = nil, callSign: String? = nil) -> UnifiedChannel {
        UnifiedChannel(id: id, sourceType: .xtream, sourceId: "x", channelNumber: number.map { ChannelNumber(major: $0) },
                       name: name, callSign: callSign)
    }

    private func program(_ channel: String, _ title: String, from start: Double, to end: Double) -> UnifiedProgram {
        UnifiedProgram(id: "\(channel):\(title)", channelId: channel, title: title,
                       startTime: now.addingTimeInterval(start), endTime: now.addingTimeInterval(end))
    }

    private func names(_ query: String, _ channels: [UnifiedChannel]) -> [String] {
        LiveChannelSearch.search(query, in: .init(channels)).channels.map(\.name)
    }

    func test_normalized_foldsCaseAccentsAndSeparators() {
        XCTAssertEqual(LiveChannelSearch.normalized("| NL |  NPO 1 FHD"), "nl npo 1 fhd")
        XCTAssertEqual(LiveChannelSearch.normalized("Télé-Québec"), "tele quebec")
        XCTAssertEqual(LiveChannelSearch.normalized(" ||| "), "")
    }

    func test_matchesIgnoringSeparatorsAndCase() {
        let channels = [ch("1", "| NL | NPO 1 FHD 50FPS"), ch("2", "| NL | RTL 4 FHD"), ch("3", "| BE | VRT 1")]
        XCTAssertEqual(names("npo 1", channels), ["| NL | NPO 1 FHD 50FPS"])
        XCTAssertEqual(names("RTL", channels), ["| NL | RTL 4 FHD"])
        XCTAssertEqual(names("nl", channels).count, 2)
    }

    func test_everyWordMustMatch() {
        let channels = [ch("1", "Ziggo Sport 2"), ch("2", "Ziggo Sport Golf")]
        XCTAssertEqual(names("ziggo golf", channels), ["Ziggo Sport Golf"])
    }

    func test_ranking_numberThenNameThenPrefixThenWordsThenAnywhere() {
        let channels = [ch("a", "Discovery 24"), ch("b", "24 Kitchen"), ch("c", "NPO 24"), ch("d", "Channel", number: 24),
                        ch("e", "Mix24x7"), ch("f", "24")]
        XCTAssertEqual(names("24", channels), ["Channel", "24", "24 Kitchen", "Discovery 24", "NPO 24", "Mix24x7"])
    }

    func test_callSign_matches() {
        XCTAssertEqual(names("wnbc", [ch("1", "NBC 4 New York", callSign: "WNBC")]), ["NBC 4 New York"])
    }

    func test_emptyOrSeparatorOnlyQuery_findsNothing() {
        let index = LiveChannelSearch.Index([ch("1", "NPO 1")])
        XCTAssertTrue(LiveChannelSearch.search("  ", in: index).isEmpty)
        XCTAssertTrue(LiveChannelSearch.search("|", in: index).isEmpty)
    }

    func test_duplicateChannels_listedOnce() {
        XCTAssertEqual(names("npo", [ch("1", "NPO 1"), ch("1", "NPO 1")]), ["NPO 1"])
    }

    func test_onNow_matchesAiringTitles_only() {
        let channels = [ch("1", "NPO 1"), ch("2", "RTL 4"), ch("3", "SBS 6")]
        let epg = [
            "1": [program("1", "Journaal", from: -600, to: 600)],
            "2": [program("2", "Late Journaal", from: 600, to: 1200)],          // not yet on
            "3": [program("3", "Journaal Extra", from: -1200, to: -600),         // over
                  program("3", "Het Journaal", from: -600, to: 600)],
        ]
        let results = LiveChannelSearch.search("journaal", in: .init(channels, epg: epg, now: now))
        XCTAssertEqual(results.onNow.map(\.program.title), ["Journaal", "Het Journaal"])
        XCTAssertEqual(results.onNow.map(\.channel.name), ["NPO 1", "SBS 6"])
        XCTAssertTrue(results.channels.isEmpty)
    }

    func test_onNow_skipsPlaceholders() {
        let epg = ["1": [UnifiedProgram(id: "1:placeholder:0", channelId: "1", title: "No guide data available.",
                                        startTime: now.addingTimeInterval(-60), endTime: now.addingTimeInterval(60))]]
        XCTAssertTrue(LiveChannelSearch.search("guide", in: .init([ch("1", "A")], epg: epg, now: now)).onNow.isEmpty)
    }

    func test_limits() {
        let channels = (0..<300).map { ch("\($0)", "Sport \($0)") }
        XCTAssertEqual(LiveChannelSearch.search("sport", in: .init(channels), channelLimit: 100).channels.count, 100)
    }

    /// 20,000 channels with a programme each: one keystroke's search.
    func test_largeLineup_searchTime() {
        let channels = (0..<20_000).map { ch("\($0)", "| NL | Channel \($0) FHD") }
        let epg = Dictionary(uniqueKeysWithValues: channels.map {
            ($0.id, [program($0.id, "Show \($0.id)", from: -600, to: 600)])
        })
        let index = LiveChannelSearch.Index(channels, epg: epg, now: now)
        measure {
            _ = LiveChannelSearch.search("channel 19", in: index)
        }
    }

    /// The same lineup's index, built as the guide or the minute changes.
    func test_largeLineup_indexTime() {
        let channels = (0..<20_000).map { ch("\($0)", "| NL | Channel \($0) FHD") }
        let epg = Dictionary(uniqueKeysWithValues: channels.map {
            ($0.id, [program($0.id, "Show \($0.id)", from: -600, to: 600)])
        })
        measure {
            _ = LiveChannelSearch.Index(channels, epg: epg, now: now)
        }
    }
}
