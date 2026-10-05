// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  IPTVGuideMatchTests.swift
//  RivuletTests
//
//  A playlist channel finds its guide by tvg-id, tvg-name or name: exact id,
//  then id ignoring case, then display name. Repeated tvg-ids get distinct
//  ids and the same guide.
//

import XCTest
@testable import Rivulet

final class IPTVGuideMatchTests: XCTestCase {

    private let xmltv = """
    <?xml version="1.0" encoding="UTF-8"?>
    <tv>
      <channel id="ESPN.us"><display-name>ESPN</display-name></channel>
      <channel id="cnn.us"><display-name>CNN International</display-name></channel>
      <channel id="bbc1"><display-name>BBC One</display-name></channel>
      <channel id="tq"><display-name>Télé-Québec</display-name></channel>
      <programme start="20240115120000 +0000" stop="20240115130000 +0000" channel="ESPN.us"><title>SportsCenter</title></programme>
      <programme start="20240115120000 +0000" stop="20240115130000 +0000" channel="cnn.us"><title>News</title></programme>
      <programme start="20240115120000 +0000" stop="20240115130000 +0000" channel="bbc1"><title>EastEnders</title></programme>
    </tv>
    """

    func test_matchesExactIdThenIdIgnoringCaseThenDisplayName() async throws {
        let result = try await XMLTVParser().parse(data: Data(xmltv.utf8))

        let ids = result.guideIds(for: [
            "exact": ["ESPN.us"],
            "case": ["CNN.US"],
            "name": ["", "bbc one!"],
            "accents": ["tele quebec"],
            "byTvgName": ["missing", "ESPN.us"],
            "none": ["Unknown"],
        ])

        XCTAssertEqual(ids, ["exact": "ESPN.us", "case": "cnn.us", "name": "bbc1",
                             "accents": "tq", "byTvgName": "ESPN.us"])
    }

    /// Every candidate is tried as an exact id before any looser match.
    func test_exactIdOnAnyCandidateBeatsAnEarlierNameMatch() async throws {
        let result = try await XMLTVParser().parse(data: Data(xmltv.utf8))
        XCTAssertEqual(result.guideIds(for: ["c": ["BBC One", "cnn.us"]]), ["c": "cnn.us"])
    }

    func test_repeatedTvgIds_getSuffixedIds_andShareTheGuide() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let m3u = dir.appendingPathComponent("playlist.m3u")
        let epg = dir.appendingPathComponent("guide.xml")
        try """
        #EXTM3U
        #EXTINF:-1 tvg-id="ESPN.us",ESPN
        http://example.invalid/1
        #EXTINF:-1 tvg-id="ESPN.us",ESPN HD
        http://example.invalid/2
        #EXTINF:-1 tvg-id="ESPN.us",ESPN 4K
        http://example.invalid/3
        #EXTINF:-1,BBC One
        http://example.invalid/4
        """.write(to: m3u, atomically: true, encoding: .utf8)
        try xmltv.write(to: epg, atomically: true, encoding: .utf8)

        let provider = IPTVProvider(m3uURL: m3u, epgURL: epg, sourceId: "m3u:test", displayName: "Test")
        let channels = try await provider.refreshChannels()
        let espn = UnifiedChannel.makeId(sourceType: .genericM3U, sourceId: "m3u:test", channelId: "ESPN.us")
        let bbc = UnifiedChannel.makeId(sourceType: .genericM3U, sourceId: "m3u:test", channelId: "BBC One")
        XCTAssertEqual(channels.map(\.id), [espn, espn + "#1", espn + "#2", bbc])

        let guide = try await provider.fetchEPG(for: channels, startDate: .distantPast, endDate: .distantFuture)
        for id in [espn, espn + "#1", espn + "#2"] {
            XCTAssertEqual(guide[id]?.map(\.title), ["SportsCenter"], id)
        }
        XCTAssertEqual(guide[bbc]?.map(\.title), ["EastEnders"])
        XCTAssertNotEqual(guide[espn]?.first?.id, guide[espn + "#1"]?.first?.id)
    }
}
