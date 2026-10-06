// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class ServerLocationTests: XCTestCase {
    private func loc(_ s: String) -> ServerLocation { ServerLocation.classify(s) }

    func test_privateIPv4Literals_areLocal() {
        XCTAssertEqual(loc("http://192.168.1.140:32400"), .local)
        XCTAssertEqual(loc("http://10.0.0.5:32400"), .local)
        XCTAssertEqual(loc("http://172.16.0.1:32400"), .local)
        XCTAssertEqual(loc("http://172.31.255.1:32400"), .local)
        XCTAssertEqual(loc("http://100.64.1.2:32400"), .local)    // CGNAT / Tailscale
        XCTAssertEqual(loc("http://169.254.3.4:32400"), .local)
        XCTAssertEqual(loc("http://127.0.0.1:32400"), .local)
    }

    func test_publicAndEdgeIPv4_areRemote() {
        XCTAssertEqual(loc("http://172.15.0.1:32400"), .remote)
        XCTAssertEqual(loc("http://172.32.0.1:32400"), .remote)
        XCTAssertEqual(loc("http://172.200.1.1:32400"), .remote)
        XCTAssertEqual(loc("http://100.128.0.1:32400"), .remote)
        XCTAssertEqual(loc("https://73.12.44.5:32400"), .remote)
        XCTAssertEqual(loc("https://plex.example.com"), .remote)
    }

    func test_plexDirect_decodesEmbeddedAddress() {
        XCTAssertEqual(loc("https://192-168-1-140.abcdef0123456789.plex.direct:32400"), .local)
        XCTAssertEqual(loc("https://73-12-44-5.abcdef0123456789.plex.direct:32400"), .remote)
        XCTAssertEqual(loc("https://73-12-44-5.abcdef0123456789.plex.direct:8443"), .relay)
        XCTAssertEqual(ServerLocation.plexDirectAddress("fd00--1.abc.plex.direct"), "fd00::1")
    }

    func test_ipv6AndNames() {
        XCTAssertEqual(loc("http://[fd12:3456::1]:32400"), .local)
        XCTAssertEqual(loc("http://[fe80::1]:32400"), .local)
        XCTAssertEqual(loc("http://[::1]:32400"), .local)
        XCTAssertEqual(loc("http://[2001:db8::1]:32400"), .remote)
        XCTAssertEqual(loc("http://nas.local:32400"), .local)
        XCTAssertEqual(loc("http://localhost:32400"), .local)
        XCTAssertEqual(loc("not a url"), .remote)
    }
}
