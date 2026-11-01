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

    func test_noCredential_401_returnsResponse() async throws {
        let url = URL(string: "http://tvh.test/api/serverinfo")!
        MockURLProtocol.mockResponses[url] = (Data(), HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil,
                                                                       headerFields: nil)!)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]

        for credential in [nil, URLCredential(user: "u", password: "p", persistence: .forSession)] {
            let (_, response) = try await BoundedDownload.data(for: URLRequest(url: url), limit: 1 << 20,
                                                               configuration: config, credential: credential)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        }
    }
}
