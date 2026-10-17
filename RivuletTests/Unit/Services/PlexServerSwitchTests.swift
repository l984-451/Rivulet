// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexServerSwitchTests.swift
//  RivuletTests
//
//  Tests for the server switch in Settings → Plex Server → Server.
//  A failed switch must keep the current server. The app must not mark that server as unreachable.
//

import XCTest
@testable import Rivulet

@MainActor
final class PlexServerSwitchTests: XCTestCase {

    private var auth: PlexAuthManager { .shared }
    private var saved: (state: PlexAuthState, server: PlexDevice?, url: String?, connected: Bool, error: String?)!

    override func setUp() async throws {
        saved = (auth.state, auth.selectedServer, auth.selectedServerURL, auth.isConnected, auth.connectionError)
    }

    override func tearDown() async throws {
        auth.state = saved.state
        auth.selectedServer = saved.server
        auth.selectedServerURL = saved.url
        auth.isConnected = saved.connected
        auth.connectionError = saved.error
    }

    private func device(_ id: String, name: String, uri: String? = nil) throws -> PlexDevice {
        var json: [String: Any] = [
            "name": name, "product": "Plex Media Server", "productVersion": "1.43.4",
            "clientIdentifier": id, "createdAt": "", "lastSeenAt": "", "provides": "server"
        ]
        if let uri, let url = URL(string: uri) {
            json["connections"] = [[
                "protocol": url.scheme ?? "http", "address": url.host ?? "", "port": url.port ?? 32400,
                "uri": uri, "local": true, "relay": false, "IPv6": false
            ]]
        }
        return try JSONDecoder().decode(PlexDevice.self, from: JSONSerialization.data(withJSONObject: json))
    }

    // MARK: Current server

    func test_isCurrentServer_matchesSelectedServerByIdentity() throws {
        let home = try device("aaa", name: "Home")
        let shared = try device("bbb", name: "Home")
        auth.selectedServer = home
        XCTAssertTrue(auth.isCurrentServer(home))
        XCTAssertFalse(auth.isCurrentServer(shared), "a server with the same name is not the current server")
    }

    /// After a relaunch, `selectedServer` is nil. Only the saved URL identifies the current server.
    func test_isCurrentServer_afterRelaunch_matchesSavedURL() throws {
        let home = try device("aaa", name: "Home", uri: "http://192.168.0.5:32400")
        let friend = try device("bbb", name: "Friend", uri: "http://10.0.0.9:32400")
        auth.selectedServer = nil
        auth.selectedServerURL = "http://192.168.0.5:32400"
        XCTAssertTrue(auth.isCurrentServer(home))
        XCTAssertFalse(auth.isCurrentServer(friend))
    }

    // MARK: Failed switch

    /// The server has no connections, so the probe fails without network access.
    func test_failedSwitch_keepsCurrentServerReachable() async throws {
        let current = try device("aaa", name: "Home", uri: "http://192.168.0.5:32400")
        auth.selectedServer = current
        auth.selectedServerURL = "http://192.168.0.5:32400"
        auth.isConnected = true
        auth.connectionError = nil
        auth.state = .authenticated

        let switched = await auth.selectServer(try device("bbb", name: "Unreachable"))

        XCTAssertFalse(switched)
        XCTAssertEqual(auth.selectedServer?.clientIdentifier, "aaa")
        XCTAssertEqual(auth.selectedServerURL, "http://192.168.0.5:32400")
        XCTAssertTrue(auth.isConnected, "the app did not test the current server again, so it is not offline")
        XCTAssertNil(auth.connectionError)
        XCTAssertEqual(auth.state, .authenticated)
    }

    /// During sign-in, no server is selected yet. A failure must show an error.
    func test_failedFirstSelection_reportsError() async throws {
        auth.selectedServer = nil
        auth.selectedServerURL = nil
        auth.isConnected = true

        let selected = await auth.selectServer(try device("bbb", name: "Unreachable"))

        XCTAssertFalse(selected)
        XCTAssertFalse(auth.isConnected)
        guard case .error = auth.state else { return XCTFail("expected an error state, got \(auth.state)") }
    }

    // MARK: Settings wiring

    func test_pickerRows_haveDescriptors() {
        for id in ["plexServerPicker", "plexServer_abc123", "plexServersLoading", "plexServersRetry"] {
            XCTAssertNotNil(SettingsDescriptorStore.descriptor(for: id), "\(id) has no description panel entry")
        }
    }
}
