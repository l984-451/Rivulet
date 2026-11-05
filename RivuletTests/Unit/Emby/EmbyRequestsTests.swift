// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyRequestsTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbyRequestsTests: XCTestCase {
    private let server = FakeJellyfinServer()
    private let base = URL(string: "http://emby.local:8096")!

    private func route(_ method: String, _ path: String) -> String {
        EmbyRequests.route(method, path, userID: "u1")
    }

    func test_routes() {
        XCTAssertEqual(route("GET", "UserViews"), "Users/u1/Views")
        XCTAssertEqual(route("GET", "UserItems/Resume"), "Users/u1/Items/Resume")
        XCTAssertEqual(route("POST", "UserItems/i9/UserData"), "Users/u1/Items/i9/UserData")
        XCTAssertEqual(route("DELETE", "UserItems/i9/Rating"), "Users/u1/Items/i9/Rating")
        XCTAssertEqual(route("POST", "UserPlayedItems/i9"), "Users/u1/PlayedItems/i9")
        XCTAssertEqual(route("DELETE", "UserFavoriteItems/i9"), "Users/u1/FavoriteItems/i9")
        XCTAssertEqual(route("GET", "Users/Me"), "Users/u1")
        XCTAssertEqual(route("GET", "Items"), "Users/u1/Items")
        XCTAssertEqual(route("GET", "Items/i9"), "Users/u1/Items/i9")
        XCTAssertEqual(route("GET", "Items/Latest"), "Users/u1/Items/Latest")
        XCTAssertEqual(route("GET", "Items/i9/SpecialFeatures"), "Users/u1/Items/i9/SpecialFeatures")
        // Not user routes on Emby.
        XCTAssertEqual(route("GET", "Items/i9/Similar"), "Items/i9/Similar")
        XCTAssertEqual(route("POST", "Items/i9/PlaybackInfo"), "Items/i9/PlaybackInfo")
        XCTAssertEqual(route("DELETE", "Items/i9"), "Items/i9")
        XCTAssertEqual(route("GET", "Shows/NextUp"), "Shows/NextUp")
    }

    /// The Jellyfin client, unchanged, through the Emby transport.
    func test_jellyfinClient_throughEmbyTransport() async throws {
        server.respond("/Users/u1/Views", body: #"{"Items":[],"TotalRecordCount":0}"#)
        let client = JellyfinClient(baseURL: base, token: "tok", transport: EmbyRequests.transport(
            baseURL: base, userID: "u1", token: "tok", sending: server.transport))
        let _: JFQueryResult = try await client.get("UserViews")
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "http://emby.local:8096/Users/u1/Views?UserId=u1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Authorization"), client.authorization)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Emby-Token"), "tok")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func test_rewrite_keepsQuery_andReverseProxyPrefix() throws {
        let proxied = URL(string: "https://h.example/emby")!
        var request = URLRequest(url: URL(string: "https://h.example/emby/Shows/NextUp?limit=1&fields=A%2CB")!)
        request.httpMethod = "GET"
        let out = EmbyRequests.rewrite(request, baseURL: proxied, userID: "u1", token: nil)
        XCTAssertEqual(out.url?.absoluteString, "https://h.example/emby/Shows/NextUp?limit=1&fields=A%2CB&UserId=u1")
    }

    func test_rewrite_doesNotDoubleUserId_norTouchPOSTQueries() throws {
        var get = URLRequest(url: URL(string: "http://emby.local:8096/Items?userId=u1")!)
        get.httpMethod = "GET"
        XCTAssertEqual(EmbyRequests.rewrite(get, baseURL: base, userID: "u1", token: nil).url?.absoluteString,
                       "http://emby.local:8096/Users/u1/Items?userId=u1")
        var post = URLRequest(url: URL(string: "http://emby.local:8096/Sessions/Playing")!)
        post.httpMethod = "POST"
        XCTAssertEqual(EmbyRequests.rewrite(post, baseURL: base, userID: "u1", token: nil).url?.absoluteString,
                       "http://emby.local:8096/Sessions/Playing")
    }

    /// Before sign-in there is no user: only the header moves.
    func test_rewrite_beforeSignIn_keepsPath() {
        var request = URLRequest(url: URL(string: "http://emby.local:8096/Users/AuthenticateByName")!)
        request.httpMethod = "POST"
        request.setValue("MediaBrowser Client=\"Rivulet\"", forHTTPHeaderField: "Authorization")
        let out = EmbyRequests.rewrite(request, baseURL: base, userID: nil, token: nil)
        XCTAssertEqual(out.url, request.url)
        XCTAssertEqual(out.value(forHTTPHeaderField: "X-Emby-Authorization"), "MediaBrowser Client=\"Rivulet\"")
        XCTAssertNil(out.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(out.value(forHTTPHeaderField: "X-Emby-Token"))
    }

    func test_versions() {
        XCTAssertTrue(EmbySession.isEmby(productName: "Emby Server", version: "4.9.1.80"))
        XCTAssertTrue(EmbySession.isEmby(productName: nil, version: "4.11.0.13"))
        XCTAssertFalse(EmbySession.isEmby(productName: "Jellyfin Server", version: "10.10.7"))
        XCTAssertFalse(EmbySession.isEmby(productName: nil, version: "10.10.7"))
        XCTAssertTrue(EmbySession.isSupported(version: "4.11.0.13"))
        XCTAssertTrue(EmbySession.isSupported(version: "4.8.0.0"))
        XCTAssertFalse(EmbySession.isSupported(version: "4.7.14.0"))
        XCTAssertFalse(EmbySession.isSupported(version: nil))
    }
}
