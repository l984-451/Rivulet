// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexWatchlistAPIPagingTests.swift
//  RivuletTests
//
//  fetchAll pages until the container's totalSize is covered. A watchlist
//  longer than one Plex page was previously truncated to whatever the default
//  page happened to be, which the Watchlist grid (issue #287) makes visible.
//

import XCTest
@testable import Rivulet

final class PlexWatchlistAPIPagingTests: XCTestCase {

    private var session: URLSession!

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        session = URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.reset()
        session = nil
        super.tearDown()
    }

    private func pageURL(start: Int) -> URL {
        var components = URLComponents(string: "https://discover.provider.plex.tv/library/sections/watchlist/all")!
        components.queryItems = [
            URLQueryItem(name: "includeGuids", value: "1"),
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "100"),
            URLQueryItem(name: "X-Plex-Token", value: "test-token")
        ]
        return components.url!
    }

    private func page(totalSize: Int, start: Int, count: Int) -> [String: Any] {
        let metadata = (0..<count).map { offset -> [String: Any] in
            [
                "ratingKey": "\(start + offset)",
                "title": "Title \(start + offset)",
                "type": "movie",
                "Guid": [["id": "tmdb://\(start + offset)"]]
            ]
        }
        return ["MediaContainer": ["totalSize": totalSize, "size": count, "Metadata": metadata]]
    }

    func test_fetchAll_pagesUntilTotalSizeIsCovered() async throws {
        MockURLProtocol.mockJSON(url: pageURL(start: 0), json: page(totalSize: 150, start: 0, count: 100))
        MockURLProtocol.mockJSON(url: pageURL(start: 100), json: page(totalSize: 150, start: 100, count: 50))

        let items = try await PlexWatchlistAPI(session: session).fetchAll(token: "test-token")

        XCTAssertEqual(items.count, 150, "both pages should be concatenated")
        XCTAssertEqual(items.first?.id, "0")
        XCTAssertEqual(items.last?.id, "149")
        XCTAssertEqual(MockURLProtocol.requestHistory.count, 2, "one request per page, no extra trailing page")
    }

    func test_fetchAll_singlePageMakesOneRequest() async throws {
        MockURLProtocol.mockJSON(url: pageURL(start: 0), json: page(totalSize: 12, start: 0, count: 12))

        let items = try await PlexWatchlistAPI(session: session).fetchAll(token: "test-token")

        XCTAssertEqual(items.count, 12)
        XCTAssertEqual(MockURLProtocol.requestHistory.count, 1)
    }

    /// Unsupported types (anything but movie/show) are dropped during decode,
    /// so a page can yield fewer items than it holds. The loop must still
    /// advance by the requested page size rather than stalling on the short
    /// result and re-requesting the same offset forever.
    func test_fetchAll_doesNotLoopWhenTypesAreFilteredOut() async throws {
        var first = page(totalSize: 150, start: 0, count: 100)
        var container = first["MediaContainer"] as! [String: Any]
        container["Metadata"] = (0..<100).map { offset -> [String: Any] in
            ["ratingKey": "\(offset)", "title": "Artist \(offset)", "type": "artist"]
        }
        first["MediaContainer"] = container
        MockURLProtocol.mockJSON(url: pageURL(start: 0), json: first)
        MockURLProtocol.mockJSON(url: pageURL(start: 100), json: page(totalSize: 150, start: 100, count: 50))

        let items = try await PlexWatchlistAPI(session: session).fetchAll(token: "test-token")

        XCTAssertEqual(items.count, 50, "the filtered page contributes nothing")
        XCTAssertEqual(MockURLProtocol.requestHistory.count, 2)
    }
}
