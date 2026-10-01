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
    func test_needsDeinterlacing_onlyAReportedInterlaceForcesIt() throws {
        let base = "http://pms:32400/livetv/sessions/abc/0/index.m3u8"
        let interlaced = try XCTUnwrap(URL(string: base + "?rivuletLiveScanType=interlaced"))
        let progressive = try XCTUnwrap(URL(string: base + "?rivuletLiveScanType=Progressive"))
        // A Dispatcharr channel carries no scan type. Forcing it onto the
        // software path made 4K60 stutter and put HomePod audio ~3s late.
        let dispatcharr = try XCTUnwrap(URL(string: "http://192.168.1.140:9191/proxy/ts/stream/abc"))

        XCTAssertTrue(AetherPlayer.needsDeinterlacing(interlaced))
        XCTAssertFalse(AetherPlayer.needsDeinterlacing(progressive))
        XCTAssertFalse(AetherPlayer.needsDeinterlacing(dispatcharr))
    }

    // MARK: - resolveStreamURL

    /// A failed tune used to hand back the untuned guide-entry URL. PMS answers
    /// that with 400 every time, and each 400 drove another tune.
    func test_failedTuneResolvesToNothing() async throws {
        let server = "http://127.0.0.1:9"  // nothing listens, so the tune fails at once
        let guideEntry = try XCTUnwrap(URL(string: server + "/video/:/transcode/universal/start.m3u8"
            + "?path=/tv.plex.providers.epg.xmltv:34/metadata/58&session=a"))
        let channel = UnifiedChannel(id: "58", sourceType: .plex, sourceId: "plex:" + server,
                                     name: "Test", streamURL: guideEntry)
        let provider = PlexLiveTVProvider(serverURL: server, authToken: "t", serverName: "Test")

        let resolved = try? await provider.resolveStreamURL(for: channel)
        XCTAssertNil(resolved)
    }
}
