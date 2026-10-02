// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinClientTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class JellyfinClientTests: XCTestCase {
    private let server = FakeJellyfinServer()

    private func client(base: String = "http://jf.local:8096", token: String? = "tok") -> JellyfinClient {
        JellyfinClient(baseURL: URL(string: base)!, token: token, transport: server.transport)
    }

    func test_url_keepsReverseProxySubpath_andEncodesPlus() {
        let url = client(base: "https://h.example/jellyfin")
            .url("Items", [URLQueryItem(name: "searchTerm", value: "C++ & co")])
        XCTAssertEqual(url.absoluteString, "https://h.example/jellyfin/Items?searchTerm=C%2B%2B%20%26%20co")
    }

    func test_authorization_isMediaBrowserScheme_withToken() {
        let header = client().authorization
        XCTAssertTrue(header.hasPrefix(#"MediaBrowser Client="Rivulet", Device="#), header)
        XCTAssertTrue(header.contains(#"DeviceId="\#(PlexAPI.clientIdentifier)""#), header)
        XCTAssertTrue(header.hasSuffix(#", Token="tok""#), header)
    }

    func test_authorization_omitsTokenWhenSignedOut() {
        XCTAssertFalse(client(token: nil).authorization.contains("Token="))
    }

    func test_get_sendsAuthorizationHeader() async throws {
        server.respond("/UserViews", body: #"{"Items":[],"TotalRecordCount":0}"#)
        let c = client()
        let _: JFQueryResult = try await c.get("UserViews")
        XCTAssertEqual(server.requests.first?.value(forHTTPHeaderField: "Authorization"), c.authorization)
    }

    func test_401_mapsToUnauthorized() async {
        server.respond("/UserViews", status: 401)
        do {
            let _: JFQueryResult = try await client().get("UserViews")
            XCTFail("expected a throw")
        } catch MediaProviderError.unauthorized {
        } catch { XCTFail("got \(error)") }
    }

    func test_404_mapsToNotFound() async {
        server.respond("/Items/x", status: 404)
        do {
            let _: JFItem = try await client().get("Items/x")
            XCTFail("expected a throw")
        } catch MediaProviderError.notFound {
        } catch { XCTFail("got \(error)") }
    }

    func test_networkFailure_mapsToUnreachable() async {
        do {
            let _: JFQueryResult = try await client().get("UserViews")   // no route registered
            XCTFail("expected a throw")
        } catch MediaProviderError.unreachable {
        } catch { XCTFail("got \(error)") }
    }

    func test_post_acceptsEmpty204() async throws {
        server.respond("/Sessions/Playing", status: 204)
        try await client().post("Sessions/Playing")
    }
}
