// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveGuideLabelTests.swift
//  RivuletTests
//
//  Channel numbers with sub-channels (#430) and the guide's second line and
//  qualifier tag (#429, #434).
//

import XCTest
@testable import Rivulet

final class LiveGuideLabelTests: XCTestCase {

    func test_channelNumber_keepsTheSubChannel() {
        XCTAssertEqual(ChannelNumber("10.1")?.description, "10.1")
        XCTAssertEqual(ChannelNumber("10-1")?.description, "10.1")
        XCTAssertEqual(ChannelNumber(" 7 ")?.description, "7")
        XCTAssertEqual(ChannelNumber("19.10"), ChannelNumber(major: 19, minor: 10))
        XCTAssertNil(ChannelNumber("HBO"))
        XCTAssertNil(ChannelNumber(""))
    }

    func test_channelNumber_sortsSubChannelsAfterTheirMain() {
        let numbers = ["19.6", "10.2", "11", "10", "10.10", "10.1"].compactMap(ChannelNumber.init)
        XCTAssertEqual(numbers.sorted().map(\.description), ["10", "10.1", "10.2", "10.10", "11", "19.6"])
        XCTAssertLessThan(ChannelNumber(major: 999, minor: 9), .max)
    }

    func test_m3u_readsADecimalChannelNumber() async throws {
        let playlist = """
            #EXTM3U
            #EXTINF:-1 tvg-chno="19.6",WBRC-DT6
            http://example.com/1.ts
            """
        let channels = try await M3UParser().parse(content: playlist)
        XCTAssertEqual(channels.first?.channelNumber?.description, "19.6")
    }

    func test_guideDetail_fallsBackToTheEpisodeNumber() {
        XCTAssertEqual(program(subtitle: "Fed Day", episode: "S1 E22").guideDetail, "Fed Day")
        XCTAssertEqual(program(subtitle: nil, episode: "S3 E4").guideDetail, "S3 E4")
        XCTAssertEqual(program(subtitle: "", episode: "S3 E4").guideDetail, "S3 E4")
        XCTAssertNil(program(subtitle: "Ghosts", episode: nil).guideDetail, "a subtitle repeating the title")
    }

    func test_guideTag_prefersLiveOverNew() {
        XCTAssertEqual(program(isNew: true).guideTag, "NEW")
        XCTAssertEqual(program(title: "Live: Horse Racing", isNew: true).guideTag, "LIVE")
        XCTAssertNil(program().guideTag)
    }

    func test_jellyfinNew_followsJellyfinWeb() throws {
        func isNew(_ flags: String) throws -> Bool {
            let json = #"{"Id":"p","Name":"Ghosts","StartDate":"2026-10-21T08:00:00.0000000Z","EndDate":"2026-10-21T09:00:00.0000000Z""#
                + (flags.isEmpty ? "" : ",\(flags)") + "}"
            let dto = try JellyfinJSON.decoder().decode(JFLiveProgram.self, from: Data(json.utf8))
            return try XCTUnwrap(dto.unifiedProgram(channelId: "c", baseURL: URL(string: "http://jf")!)).isNew
        }
        XCTAssertTrue(try isNew(#""IsSeries":true"#), "Schedules Direct marks a new episode by not marking it a repeat")
        XCTAssertFalse(try isNew(#""IsSeries":true,"IsRepeat":true"#))
        XCTAssertTrue(try isNew(#""IsPremiere":true"#))
        XCTAssertFalse(try isNew(#""IsNews":true"#))
    }

    private func program(title: String = "Ghosts", subtitle: String? = nil, episode: String? = nil,
                         isNew: Bool = false) -> UnifiedProgram {
        UnifiedProgram(id: "p", channelId: "c", title: title, subtitle: subtitle,
                       startTime: Date(), endTime: Date().addingTimeInterval(1800),
                       episodeNumber: episode, isNew: isNew)
    }
}
