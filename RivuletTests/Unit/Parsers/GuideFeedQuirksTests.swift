// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  GuideFeedQuirksTests.swift
//  RivuletTests
//
//  Guide feeds other players read and Rivulet used to drop: programmes with no
//  `stop`, `+HH:MM` offsets, a channel known by its second display name, and a
//  guide named only in the playlist header.
//

import XCTest
@testable import Rivulet

final class GuideFeedQuirksTests: XCTestCase {

    func test_missingStop_endsAtNextStart_lastIsDropped() async throws {
        let xml = """
        <tv>
          <programme start="20260101100000 +0000" channel="a"><title>One</title></programme>
          <programme start="20260101110000 +0000" stop="20260101120000 +0000" channel="a"><title>Two</title></programme>
          <programme start="20260101120000 +0000" channel="a"><title>Last</title></programme>
        </tv>
        """
        let programs = try await XMLTVParser().parse(data: Data(xml.utf8)).programs["a"] ?? []
        XCTAssertEqual(programs.map(\.title), ["One", "Two"])
        XCTAssertEqual(programs[0].stop, programs[1].start)
    }

    func test_filterKeepsOnlyPlaylistChannelsFromNotBefore() async throws {
        let xml = """
        <tv>
          <channel id="fox.us"><display-name>FOX 6</display-name></channel>
          <channel id="other"><display-name>Elsewhere</display-name></channel>
          <programme start="20260101100000 +0000" stop="20260101110000 +0000" channel="fox.us"><title>Past</title></programme>
          <programme start="20260101120000 +0000" stop="20260101130000 +0000" channel="fox.us"><title>Now</title></programme>
          <programme start="20260101120000 +0000" stop="20260101130000 +0000" channel="other"><title>Not ours</title></programme>
          <programme start="20260101120000 +0000" stop="20260101130000 +0000" channel="byid"><title>By id</title></programme>
        </tv>
        """
        let filter = XMLTVParser.GuideFilter(
            candidates: ["u1": ["FOX 6"], "u2": ["BYID"]],
            notBefore: try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T11:30:00Z"))
        )
        let result = try await XMLTVParser().parse(data: Data(xml.utf8), filter: filter)
        XCTAssertEqual(result.programs["fox.us"]?.map(\.title), ["Now"])
        XCTAssertNil(result.programs["other"])
        XCTAssertEqual(result.programs["byid"]?.map(\.title), ["By id"], "an id with no <channel> still matches")
    }

    func test_colonOffset() async throws {
        let xml = """
        <tv><programme start="20260101200000 +08:00" stop="20260101210000 -05:30" channel="a"><title>T</title></programme></tv>
        """
        let result = try await XMLTVParser().parse(data: Data(xml.utf8))
        let program = try XCTUnwrap(result.programs["a"]?.first)
        XCTAssertEqual(program.start, ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
        XCTAssertEqual(program.stop, ISO8601DateFormatter().date(from: "2026-01-02T02:30:00Z"))
    }

    func test_matchesLaterDisplayName() async throws {
        let xml = """
        <tv>
          <channel id="id.1"><display-name>WBRC FOX 6</display-name><display-name>6</display-name><display-name>FOX 6</display-name></channel>
          <channel id="id.2"><display-name>FOX 6</display-name></channel>
        </tv>
        """
        let result = try await XMLTVParser().parse(data: Data(xml.utf8))
        XCTAssertEqual(result.channels["id.1"]?.displayName, "WBRC FOX 6")
        let ids = result.guideIds(for: ["byNumber": ["6"], "first": ["FOX 6"]])
        XCTAssertEqual(ids["byNumber"], "id.1")
        // A channel's first name outranks another channel's third.
        XCTAssertEqual(ids["first"], "id.2")
    }

    func test_playlistHeaderGuide() async throws {
        XCTAssertEqual(M3UParser.guideURL(inHeader: #"#EXTM3U x-tvg-url="http://g.test/a.xml,http://g.test/b.xml""#),
                       URL(string: "http://g.test/a.xml"))
        XCTAssertEqual(M3UParser.guideURL(inHeader: #"#EXTM3U url-tvg="https://g.test/epg.xml.gz""#),
                       URL(string: "https://g.test/epg.xml.gz"))
        XCTAssertNil(M3UParser.guideURL(inHeader: "#EXTM3U"))
        XCTAssertNil(M3UParser.guideURL(inHeader: #"#EXTM3U x-tvg-url="file:///etc/x""#))

        let parser = M3UParser()
        _ = try await parser.parse(content: "#EXTM3U tvg-url=\"http://g.test/x.xml\"\n#EXTINF:-1,A\nhttp://s.test/a\n")
        let header = await parser.headerGuideURL
        XCTAssertEqual(header, URL(string: "http://g.test/x.xml"))
    }
}
