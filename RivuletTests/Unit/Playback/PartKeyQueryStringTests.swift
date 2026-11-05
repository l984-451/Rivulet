// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PartKeyQueryStringTests.swift
//  RivuletTests
//
//  A Part key with its own query (`/services/iva/.../video.mp4?fmt=4`) must keep
//  its '?' unencoded in the direct-play URL, and library part keys must come
//  through byte-identical (#255).
//

import XCTest
@testable import Rivulet

final class PartKeyQueryStringTests: XCTestCase {

    // MARK: - Ordinary library parts must not change

    func test_libraryPartKey_isUnchanged() {
        let key = "/library/parts/98765/1234567890/file.mkv"
        let (path, items) = PlexPartKey.split(key)
        XCTAssertEqual(path, key)
        XCTAssertTrue(items.isEmpty)
    }

    func test_libraryPartKeyWithEncodedSpaces_isUnchanged() {
        let key = "/library/parts/1/2/My%20Movie.mkv"
        let (path, items) = PlexPartKey.split(key)
        XCTAssertEqual(path, key)
        XCTAssertTrue(items.isEmpty)
    }

    // MARK: - IVA keys carrying a query string — the #255 defect

    func test_ivaKeyWithQueryString_splitsPathFromQuery() {
        let (path, items) = PlexPartKey.split(
            "/services/iva/assets/715933/video.mp4?fmt=4&bitrate=5000"
        )
        XCTAssertEqual(path, "/services/iva/assets/715933/video.mp4")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first(where: { $0.name == "fmt" })?.value, "4")
        XCTAssertEqual(items.first(where: { $0.name == "bitrate" })?.value, "5000")
    }

    /// The key may also arrive with the delimiter already percent-encoded.
    /// Assigning that to `.path` would double-encode it to %253F.
    func test_ivaKeyWithEncodedDelimiter_splitsPathFromQuery() {
        let (path, items) = PlexPartKey.split(
            "/services/iva/assets/715933/video.mp4%3Ffmt=4&bitrate=5000"
        )
        XCTAssertEqual(path, "/services/iva/assets/715933/video.mp4")
        XCTAssertEqual(items.first(where: { $0.name == "fmt" })?.value, "4")
        XCTAssertEqual(items.first(where: { $0.name == "bitrate" })?.value, "5000")
    }

    /// Only the FIRST delimiter splits; later ones belong to the query.
    func test_onlyFirstDelimiterSplits() {
        let (path, items) = PlexPartKey.split("/a/b.mp4?u=http%3A%2F%2Fx")
        XCTAssertEqual(path, "/a/b.mp4")
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.value, "http://x")
    }

    // MARK: - The full URL is well-formed (what the server actually receives)

    /// End-to-end shape check: exactly one '?', no encoded delimiter, and the
    /// key's own parameters surviving alongside the token.
    func test_composedURL_isWellFormed() {
        let server = URL(string: "https://example.plex.direct:32400")!
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        let (path, inherited) = PlexPartKey.split(
            "/services/iva/assets/715933/video.mp4?fmt=4&bitrate=5000"
        )
        components.path = path
        components.queryItems = inherited + [URLQueryItem(name: "X-Plex-Token", value: "TOK")]

        let absolute = components.url!.absoluteString
        XCTAssertFalse(absolute.contains("%3F"), "encoded '?' means the server sees it as part of the path")
        XCTAssertFalse(absolute.contains("%253F"), "double-encoded delimiter")
        XCTAssertEqual(absolute.filter { $0 == "?" }.count, 1, "exactly one query delimiter")
        XCTAssertTrue(absolute.contains("fmt=4"))
        XCTAssertTrue(absolute.contains("bitrate=5000"))
        XCTAssertTrue(absolute.contains("X-Plex-Token=TOK"))
        XCTAssertTrue(absolute.hasPrefix("https://example.plex.direct:32400/services/iva/assets/715933/video.mp4?"))
    }

    func test_composedURL_forLibraryPart_isUnchangedShape() {
        let server = URL(string: "https://example.plex.direct:32400")!
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        let (path, inherited) = PlexPartKey.split("/library/parts/98765/1234567890/file.mkv")
        components.path = path
        components.queryItems = inherited + [URLQueryItem(name: "X-Plex-Token", value: "TOK")]

        XCTAssertEqual(
            components.url!.absoluteString,
            "https://example.plex.direct:32400/library/parts/98765/1234567890/file.mkv?X-Plex-Token=TOK"
        )
    }
}
