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

    private func device(_ id: String, name: String, uri: String? = nil, token: String? = nil) throws -> PlexDevice {
        var json: [String: Any] = [
            "name": name, "product": "Plex Media Server", "productVersion": "1.43.4",
            "clientIdentifier": id, "createdAt": "", "lastSeenAt": "", "provides": "server"
        ]
        if let token { json["accessToken"] = token }
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

    /// A Plex Live TV source from another server must not get this server's token.
    func test_isCurrentServerURL_rejectsOtherServer() throws {
        auth.selectedServer = try device("aaa", name: "Home", uri: "http://192.168.0.5:32400")
        auth.selectedServerURL = "http://192.168.0.5:32400"
        XCTAssertTrue(auth.isCurrentServerURL("http://192.168.0.5:32400"))
        XCTAssertFalse(auth.isCurrentServerURL("http://10.0.0.9:32400"))

        auth.selectedServer = nil
        XCTAssertTrue(auth.isCurrentServerURL("http://192.168.0.5:32400/"))
        XCTAssertFalse(auth.isCurrentServerURL("http://10.0.0.9:32400"))
    }

    // MARK: Re-finding the saved server

    /// A friend's shared server named like ours ("Tower") is listed first and our address changed.
    func test_savedServer_sameName_savedIDPicksOurs() throws {
        let friend = try device("friend", name: "Tower", uri: "http://10.0.0.9:32400")
        let ours = try device("ours", name: "Tower", uri: "http://192.168.1.10:32400")
        let picked = PlexAuthManager.savedServer(
            in: [friend, ours], machineID: "ours", url: "http://203.0.113.5:32400", name: "Tower")
        XCTAssertEqual(picked?.machineIdentifier, "ours")
    }

    /// A saved id that is not listed matches nothing, never a server by name or address.
    func test_savedServer_savedIDMissing_matchesNothing() throws {
        let friend = try device("friend", name: "Tower", uri: "http://192.168.1.10:32400")
        XCTAssertNil(PlexAuthManager.savedServer(
            in: [friend], machineID: "ours", url: "http://192.168.1.10:32400", name: "Tower"))
    }

    /// An install that saved no id still falls back to the URL, then the name.
    func test_savedServer_noSavedID_fallsBackToURLThenName() throws {
        let other = try device("other", name: "Other", uri: "http://10.0.0.9:32400")
        let ours = try device("ours", name: "Tower", uri: "http://192.168.1.10:32400")
        XCTAssertEqual(PlexAuthManager.savedServer(
            in: [other, ours], machineID: nil, url: "http://192.168.1.10:32400", name: nil)?.machineIdentifier, "ours")
        XCTAssertEqual(PlexAuthManager.savedServer(
            in: [other, ours], machineID: nil, url: "http://203.0.113.5:32400", name: "Tower")?.machineIdentifier, "ours")
    }

    /// A friend's shared server with our private address is listed first.
    func test_serverForAccessToken_sharedPrivateAddress_savedIDReturnsOurToken() throws {
        let friend = try device("friend", name: "Tower", uri: "http://192.168.1.10:32400", token: "friend-token")
        let ours = try device("ours", name: "Tower", uri: "http://192.168.1.10:32400", token: "our-token")
        let server = PlexNetworkManager.serverForAccessToken(
            in: [friend, ours], serverURL: "http://192.168.1.10:32400", machineID: "ours", serverName: "Tower")
        XCTAssertEqual(server?.accessToken, "our-token")
    }

    /// With no saved id, a shared private address is ambiguous and returns no token.
    func test_serverForAccessToken_noSavedID_sharedAddressIsAmbiguous() throws {
        let friend = try device("friend", name: "Tower", uri: "http://192.168.1.10:32400", token: "friend-token")
        let ours = try device("ours", name: "Tower", uri: "http://192.168.1.10:32400", token: "our-token")
        XCTAssertNil(PlexNetworkManager.serverForAccessToken(
            in: [friend, ours], serverURL: "http://192.168.1.10:32400", machineID: nil, serverName: "Tower"))
    }

    /// With no saved id, one server at the address and port with the saved name still matches.
    func test_serverForAccessToken_noSavedID_fallsBackToAddressAndName() throws {
        let other = try device("other", name: "Other", uri: "http://10.0.0.9:32400", token: "other-token")
        let ours = try device("ours", name: "Tower", uri: "https://192-168-1-10.abc.plex.direct:32400", token: "our-token")
        let rawAddress = try device("ours2", name: "Tower", uri: "http://192.168.1.20:32400", token: "raw-token")
        XCTAssertEqual(PlexNetworkManager.serverForAccessToken(
            in: [other, ours], serverURL: "https://192-168-1-10.abc.plex.direct:32400",
            machineID: nil, serverName: "Tower")?.accessToken, "our-token")
        XCTAssertEqual(PlexNetworkManager.serverForAccessToken(
            in: [other, rawAddress], serverURL: "http://192.168.1.20:32400/",
            machineID: nil, serverName: "Tower")?.accessToken, "raw-token")
        XCTAssertNil(PlexNetworkManager.serverForAccessToken(
            in: [other, rawAddress], serverURL: "http://192.168.1.20:32400",
            machineID: nil, serverName: "Elsewhere"), "the name must match too")
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
        for id in ["plexServer", "plexServer_abc123", "plexServersLoading", "plexServersRetry"] {
            XCTAssertNotNil(SettingsDescriptorStore.descriptor(for: id), "\(id) has no description panel entry")
        }
    }
}
