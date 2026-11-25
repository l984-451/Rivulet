// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  BoundedDownloadCredentialTests.swift
//  RivuletTests
//
//  A refused login comes back as its status, with or without a credential, so
//  callers can tell a wrong password from a dead server.
//

import XCTest
@testable import Rivulet

final class BoundedDownloadCredentialTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    override func tearDown() {
        MockURLProtocol.reset()
        super.tearDown()
    }

    func testServerCredentialMatchesOnlyItsHTTPOrigin() {
        let login = BoundedDownload.ServerCredential(origin: URL(string: "https://guide.test/path")!,
            value: URLCredential(user: "u", password: "p", persistence: .none))
        func space(_ host: String, _ port: Int, _ scheme: String) -> URLProtectionSpace {
            URLProtectionSpace(host: host, port: port, protocol: scheme, realm: nil,
                               authenticationMethod: NSURLAuthenticationMethodHTTPDigest)
        }
        XCTAssertTrue(login.matches(space("GUIDE.test", 443, "https")))
        XCTAssertTrue(login.matches(space("guide.test", 9981, "https")))
        XCTAssertFalse(login.matches(space("guide.test", 443, "http")))
        let plain = BoundedDownload.ServerCredential(origin: URL(string: "http://guide.test:9981")!,
            value: URLCredential(user: "u", password: "p", persistence: .none))
        XCTAssertTrue(plain.matches(space("guide.test", 443, "https")))
        XCTAssertFalse(plain.matches(space("guide.test", 80, "http")))
        XCTAssertFalse(login.matches(space("cdn.test", 443, "https")))
        XCTAssertFalse(login.matches(URLProtectionSpace(proxyHost: "guide.test", port: 443,
            type: NSURLProtectionSpaceHTTPSProxy, realm: nil, authenticationMethod: NSURLAuthenticationMethodHTTPBasic)))
    }

    func test_noCredential_401_returnsResponse() async throws {
        let url = URL(string: "http://tvh.test/api/serverinfo")!
        MockURLProtocol.mockResponses[url] = (Data(), HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil,
                                                                       headerFields: nil)!)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]

        let login = BoundedDownload.ServerCredential(origin: url, value: URLCredential(user: "u", password: "p", persistence: .none))
        for credential in [nil, login] {
            let (_, response) = try await BoundedDownload.data(for: URLRequest(url: url), limit: 1 << 20,
                                                               configuration: config, credential: credential)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        }
    }
}
