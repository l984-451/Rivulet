// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexLiveURLTests.swift
//  RivuletTests
//
//  The two live-URL rules whose failure is silent at runtime: the client
//  profile's clause separator, and the scan type that picks the decode path.
//

import XCTest
@testable import Rivulet

final class PlexLiveURLTests: XCTestCase {

    // MARK: - finalizedLiveURL

    /// Rebuilding a live URL through `queryItems` decodes `%2B` back to a raw
    /// `+`, which PMS reads as a space between profile clauses.
    func test_finalizedLiveURL_encodesClauseSeparators() throws {
        var components = try XCTUnwrap(URLComponents(string: "http://pms:32400/video/:/transcode/universal/start.m3u8"))
        components.queryItems = [
            URLQueryItem(name: "X-Plex-Client-Profile-Extra",
                         value: PlexLiveTVChannel.liveClientProfileExtras()),
        ]

        let url = try XCTUnwrap(PlexLiveTVChannel.finalizedLiveURL(components))
        let query = try XCTUnwrap(url.query)

        XCTAssertFalse(query.contains("+"), "raw clause separator survived: \(query)")
        XCTAssertTrue(query.contains("%2B"))
    }

    /// The round trip that broke `buildStreamURL`: parse an already-correct URL,
    /// swap one item, rebuild.
    func test_finalizedLiveURL_survivesARebuild() throws {
        var components = try XCTUnwrap(URLComponents(string: "http://pms:32400/video/:/transcode/universal/start.m3u8"))
        components.queryItems = [
            URLQueryItem(name: "session", value: "A"),
            URLQueryItem(name: "X-Plex-Client-Profile-Extra",
                         value: PlexLiveTVChannel.liveClientProfileExtras()),
        ]
        let first = try XCTUnwrap(PlexLiveTVChannel.finalizedLiveURL(components))

        var rebuilt = try XCTUnwrap(URLComponents(url: first, resolvingAgainstBaseURL: false))
        rebuilt.queryItems = rebuilt.queryItems?.map {
            $0.name == "session" ? URLQueryItem(name: "session", value: "B") : $0
        }
        let second = try XCTUnwrap(PlexLiveTVChannel.finalizedLiveURL(rebuilt))

        XCTAssertFalse(try XCTUnwrap(second.query).contains("+"))
        let extra = URLComponents(url: second, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "X-Plex-Client-Profile-Extra" }?.value
        XCTAssertEqual(extra, PlexLiveTVChannel.liveClientProfileExtras())
    }

    // MARK: - needsDeinterlacing

    @MainActor
    func test_needsDeinterlacing_onlyAnExplicitProgressiveOptsOut() throws {
        let base = "http://pms:32400/livetv/sessions/abc/0/index.m3u8"
        let absent = try XCTUnwrap(URL(string: base))
        let interlaced = try XCTUnwrap(URL(string: base + "?rivuletLiveScanType=interlaced"))
        let progressive = try XCTUnwrap(URL(string: base + "?rivuletLiveScanType=Progressive"))

        XCTAssertTrue(AetherPlayer.needsDeinterlacing(absent))
        XCTAssertTrue(AetherPlayer.needsDeinterlacing(interlaced))
        XCTAssertFalse(AetherPlayer.needsDeinterlacing(progressive))
    }
}
