// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexAuthManagerTests.swift
//  RivuletTests
//
//  Unit tests for PlexAuthManager connection scoring and address filtering
//

import XCTest
@testable import Rivulet

final class PlexAuthManagerTests: XCTestCase {

    // Note: These tests use reflection to test private methods
    // In a production setting, you might refactor to make these testable

    // MARK: - Docker Address Filtering Tests

    func testFiltersDockerBridgeAddresses() {
        // Docker bridge network ranges that should be filtered
        let dockerAddresses = [
            "172.17.0.1",
            "172.18.0.2",
            "172.19.0.3",
            "172.20.0.4",
            "172.21.0.5",
            "172.22.0.6",
            "172.23.0.7",
            "172.24.0.8",
            "172.25.0.9",
            "172.26.0.10",
            "172.27.0.11",
            "172.28.0.12",
            "172.29.0.13",
            "172.30.0.14",
            "172.31.0.15"
        ]

        for address in dockerAddresses {
            XCTAssertTrue(
                isDockerOrInternalAddress(address),
                "Address \(address) should be filtered as Docker address"
            )
        }
    }

    /// #510: 172.16/12 is also a LAN range, so it is probed, ahead of the WAN address.
    func testDockerRangeRanksBetweenLocalAndRemote() {
        func score(_ address: String, local: Bool) -> Int {
            PlexAuthManager.connectionScore(Rivulet.PlexConnection(
                protocolType: "https", address: address, port: 32400, uri: "https://\(address):32400",
                local: local, relay: false, IPv6: false))
        }
        XCTAssertFalse(PlexAuthManager.isLoopbackAddress("172.18.0.2"))
        XCTAssertGreaterThan(score("192.168.1.10", local: true), score("172.18.0.2", local: true))
        XCTAssertGreaterThan(score("172.18.0.2", local: true), score("203.0.113.50", local: false))
        XCTAssertGreaterThan(score("172.18.0.2", local: true), score("1-2-3-4.abc.plex.direct", local: false))
    }

    func testAllows10xAddresses() {
        // 10.x.x.x is a common home network range and should NOT be filtered
        let validAddresses = [
            "10.0.0.1",
            "10.0.1.100",
            "10.1.2.3",
            "10.255.255.254"
        ]

        for address in validAddresses {
            XCTAssertFalse(
                isDockerOrInternalAddress(address),
                "Address \(address) should NOT be filtered (valid home network)"
            )
        }
    }

    func testAllows192168Addresses() {
        // 192.168.x.x is a common home network range
        let validAddresses = [
            "192.168.0.1",
            "192.168.1.100",
            "192.168.2.50"
        ]

        for address in validAddresses {
            XCTAssertFalse(
                isDockerOrInternalAddress(address),
                "Address \(address) should NOT be filtered (valid home network)"
            )
        }
    }

    func testFiltersLocalhostVariants() {
        let localhostAddresses = [
            "127.0.0.1",
            "localhost",
            "::1"
        ]

        for address in localhostAddresses {
            XCTAssertTrue(
                isDockerOrInternalAddress(address),
                "Address \(address) should be filtered as localhost"
            )
        }
    }

    func testAllowsPublicIPAddresses() {
        let publicAddresses = [
            "8.8.8.8",
            "1.1.1.1",
            "203.0.113.50"
        ]

        for address in publicAddresses {
            XCTAssertFalse(
                isDockerOrInternalAddress(address),
                "Address \(address) should NOT be filtered (public IP)"
            )
        }
    }

    func testAllowsPlexDirectDomains() {
        let plexDirectAddress = "192-168-1-100.abc123def456.plex.direct"

        XCTAssertFalse(
            isDockerOrInternalAddress(plexDirectAddress),
            "plex.direct domains should NOT be filtered"
        )
    }

    // MARK: - Connection Scoring Tests

    func testPrefersLocalNonRelayConnections() {
        let localDirect = PlexConnection(
            address: "192.168.1.100",
            port: 32400,
            local: true,
            relay: false,
            protocolType: "http"
        )

        let remoteConnection = PlexConnection(
            address: "example.com",
            port: 32400,
            local: false,
            relay: false,
            protocolType: "https"
        )

        let localScore = connectionScore(localDirect)
        let remoteScore = connectionScore(remoteConnection)

        XCTAssertGreaterThan(localScore, remoteScore, "Local non-relay should score higher than remote")
    }

    func testPrefersNonRelayOverRelay() {
        let directConnection = PlexConnection(
            address: "example.com",
            port: 32400,
            local: false,
            relay: false,
            protocolType: "https"
        )

        let relayConnection = PlexConnection(
            address: "relay.plex.tv",
            port: 32400,
            local: false,
            relay: true,
            protocolType: "https"
        )

        let directScore = connectionScore(directConnection)
        let relayScore = connectionScore(relayConnection)

        XCTAssertGreaterThan(directScore, relayScore, "Non-relay should score higher than relay")
    }

    func testPrefersHTTPForLocalConnections() {
        let httpLocal = PlexConnection(
            address: "192.168.1.100",
            port: 32400,
            local: true,
            relay: false,
            protocolType: "http"
        )

        let httpsLocal = PlexConnection(
            address: "192.168.1.100",
            port: 32400,
            local: true,
            relay: false,
            protocolType: "https"
        )

        let httpScore = connectionScore(httpLocal)
        let httpsScore = connectionScore(httpsLocal)

        XCTAssertGreaterThan(httpScore, httpsScore, "HTTP should score higher than HTTPS for local connections")
    }

    func testPrefersHTTPSForRemoteConnections() {
        let httpsRemote = PlexConnection(
            address: "example.com",
            port: 32400,
            local: false,
            relay: false,
            protocolType: "https"
        )

        let httpRemote = PlexConnection(
            address: "example.com",
            port: 32400,
            local: false,
            relay: false,
            protocolType: "http"
        )

        let httpsScore = connectionScore(httpsRemote)
        let httpScore = connectionScore(httpRemote)

        XCTAssertGreaterThan(httpsScore, httpScore, "HTTPS should score higher than HTTP for remote connections")
    }

    func testPrefersPlexDirectForRemote() {
        let plexDirect = PlexConnection(
            address: "192-168-1-100.abc123.plex.direct",
            port: 32400,
            local: false,
            relay: false,
            protocolType: "https"
        )

        let regularRemote = PlexConnection(
            address: "example.com",
            port: 32400,
            local: false,
            relay: false,
            protocolType: "https"
        )

        let plexDirectScore = connectionScore(plexDirect)
        let regularScore = connectionScore(regularRemote)

        XCTAssertGreaterThan(plexDirectScore, regularScore, "plex.direct should score higher than regular remote")
    }

    // MARK: - Plex Direct URL Building Tests

    func testBuildPlexDirectURLFormatsCorrectly() {
        let address = "192.168.1.100"
        let port = 32400
        let machineId = "abc123def456"

        let result = buildPlexDirectURL(address: address, port: port, machineIdentifier: machineId)

        let expected = "https://192-168-1-100.abc123def456.plex.direct:32400"
        XCTAssertEqual(result, expected)
    }

    func testBuildPlexDirectURLReplacesDotsWithDashes() {
        let address = "10.0.0.1"
        let result = buildPlexDirectURL(address: address, port: 32400, machineIdentifier: "test")

        XCTAssertTrue(result.contains("10-0-0-1"))
        XCTAssertFalse(result.contains("10.0.0.1"))
    }

    func testBuildPlexDirectURLIncludesCorrectPort() {
        let result = buildPlexDirectURL(address: "192.168.1.1", port: 12345, machineIdentifier: "test")

        XCTAssertTrue(result.hasSuffix(":12345"))
    }

    // MARK: - Helper Functions (Mirror PlexAuthManager's private methods for testing)

    private func isDockerOrInternalAddress(_ address: String) -> Bool {
        PlexAuthManager.looksLikeDockerBridge(address) || PlexAuthManager.isLoopbackAddress(address)
    }

    /// Test implementation that mirrors PlexAuthManager's private connectionScore
    private func connectionScore(_ connection: PlexConnection) -> Int {
        var score = 0

        // Prefer non-relay (direct connections)
        if !connection.relay { score += 1000 }

        // Prefer local connections
        if connection.local {
            score += 500
            // For local: prefer HTTP (avoids certificate issues)
            if connection.protocolType == "http" { score += 50 }
        } else {
            // For remote: prefer HTTPS (required by ATS)
            if connection.protocolType == "https" { score += 100 }
            // plex.direct domains are reliable for remote access
            if connection.address.contains(".plex.direct") { score += 50 }
        }

        return score
    }

    /// Test implementation that mirrors PlexAuthManager's private buildPlexDirectURL
    private func buildPlexDirectURL(address: String, port: Int, machineIdentifier: String) -> String {
        let ipWithDashes = address.replacingOccurrences(of: ".", with: "-")
        return "https://\(ipWithDashes).\(machineIdentifier).plex.direct:\(port)"
    }

    // MARK: - Playable connection tier (#314)

    @MainActor
    func testIsPlayableDirectURL() {
        let playable = PlexAuthManager.isPlayableDirectURL
        XCTAssertTrue(playable("http://192.168.50.5:32400"))
        XCTAssertTrue(playable("http://[fd00::1]:32400"))
        XCTAssertTrue(playable("https://192-168-50-5.abc123.plex.direct:32400"))
        XCTAssertTrue(playable("https://plex.example.com"))
        XCTAssertFalse(playable("https://192.168.50.5:32400"))
        XCTAssertFalse(playable("https://8.8.8.8:32400"))
        XCTAssertFalse(playable("https://[fd00::1]:32400"))
        XCTAssertFalse(playable("https://1-2-3-4.abc123.plex.direct:8443"))
        XCTAssertFalse(playable("not a url"))
    }

    // The trust rule shared by the API session and the player (#337)
    func testTrustsServer_neverWithoutAServerTrust() {
        // The old rule passed these on host or port alone.
        for (host, port) in [("192.168.50.5", 32400), ("1-2-3-4.abc123.plex.direct", 8443), ("plex.example.com", 32400)] {
            XCTAssertFalse(PlexCertificateDelegate.trustsServer(
                URLProtectionSpace(host: host, port: port, protocol: "https", realm: nil,
                                   authenticationMethod: NSURLAuthenticationMethodServerTrust)), host)
        }
    }

    func testPlexDirectHash_onlyFromPlexDirectURIs() {
        let hash = "0123456789abcdef0123456789abcdef"
        XCTAssertEqual(PlexCertificateDelegate.plexDirectHash(in: "https://192-168-1-2.\(hash).plex.direct:32400"), hash)
        XCTAssertEqual(PlexCertificateDelegate.plexDirectHash(in: "https://192-168-1-2.\(hash.uppercased()).plex.direct"), hash)
        XCTAssertNil(PlexCertificateDelegate.plexDirectHash(in: "https://192-168-1-2.\(hash).plex.direct.evil.com"))
        XCTAssertNil(PlexCertificateDelegate.plexDirectHash(in: "https://192-168-1-2.abc123.plex.direct"))
        XCTAssertNil(PlexCertificateDelegate.plexDirectHash(in: "http://192.168.1.2:32400"))
    }

    private func device(owned: Bool, address: String, hash: String) throws -> PlexDevice {
        let json = """
        {"name":"S","product":"Plex Media Server","productVersion":"1","clientIdentifier":"id","createdAt":"0",
         "lastSeenAt":"0","provides":"server","owned":\(owned),
         "connections":[{"protocol":"https","address":"\(address)","port":32400,
           "uri":"https://\(address.replacingOccurrences(of: ".", with: "-")).\(hash).plex.direct:32400",
           "local":true,"relay":false,"IPv6":false}]}
        """
        return try JSONDecoder().decode(PlexDevice.self, from: Data(json.utf8))
    }

    func testCertificateHashes_boundToOwnServersAddresses() throws {
        let own = "fedcba9876543210fedcba9876543210", shared = "0123456789abcdef0123456789abcdef"
        PlexCertificateDelegate.forgetCertificateHashes()
        defer { PlexCertificateDelegate.forgetCertificateHashes() }
        PlexCertificateDelegate.registerCertificateHashes(from: [
            try device(owned: true, address: "10.0.0.2", hash: own),
            try device(owned: false, address: "10.0.0.3", hash: shared),
        ])
        XCTAssertTrue(PlexCertificateDelegate.isKnownCertificateHash(own, forAddress: "10.0.0.2"))
        // Another address, or a server someone else owns (and holds the key for), never counts.
        XCTAssertFalse(PlexCertificateDelegate.isKnownCertificateHash(own, forAddress: "10.0.0.9"))
        XCTAssertFalse(PlexCertificateDelegate.isKnownCertificateHash(shared, forAddress: "10.0.0.3"))
        PlexCertificateDelegate.forgetCertificateHashes()
        XCTAssertFalse(PlexCertificateDelegate.isKnownCertificateHash(own, forAddress: "10.0.0.2"))
    }

    func testCertificateHash_coversEveryAddressOfTheServer() throws {
        let hash = "00112233445566778899aabbccddeeff"
        let json = """
        {"name":"S","product":"Plex Media Server","productVersion":"1","clientIdentifier":"id","createdAt":"0",
         "lastSeenAt":"0","provides":"server","owned":true,"connections":[
          {"protocol":"https","address":"172.17.0.2","port":32400,"uri":"https://172-17-0-2.\(hash).plex.direct:32400","local":true,"relay":false,"IPv6":false},
          {"protocol":"https","address":"192.168.1.5","port":32400,"uri":"https://192.168.1.5:32400","local":true,"relay":false,"IPv6":false}]}
        """
        PlexCertificateDelegate.forgetCertificateHashes()
        defer { PlexCertificateDelegate.forgetCertificateHashes() }
        PlexCertificateDelegate.registerCertificateHashes(from: [try JSONDecoder().decode(PlexDevice.self, from: Data(json.utf8))])
        // A custom LAN address (Docker host) serves the same certificate as the bridge address.
        XCTAssertTrue(PlexCertificateDelegate.isKnownCertificateHash(hash, forAddress: "192.168.1.5"))
    }

    func testIPLiteral() {
        XCTAssertTrue(PlexCertificateDelegate.isIPLiteral("192.168.1.2"))
        XCTAssertTrue(PlexCertificateDelegate.isIPLiteral("fd00::1"))
        XCTAssertFalse(PlexCertificateDelegate.isIPLiteral("plex.tv"))
        XCTAssertFalse(PlexCertificateDelegate.isIPLiteral("1-2-3-4.abc.plex.direct"))
        XCTAssertFalse(PlexCertificateDelegate.isIPLiteral("999.1.1.1"))
    }

    func testMachineIdentifier_fromIdentityJSONAndXML() {
        let json = Data(#"{"MediaContainer":{"size":0,"claimed":true,"machineIdentifier":"48eb","version":"1.43.4"}}"#.utf8)
        XCTAssertEqual(PlexAuthManager.machineIdentifier(fromIdentity: json), "48eb")
        let xml = Data(#"<MediaContainer size="0" machineIdentifier="48eb" version="1.43"/>"#.utf8)
        XCTAssertEqual(PlexAuthManager.machineIdentifier(fromIdentity: xml), "48eb")
        XCTAssertNil(PlexAuthManager.machineIdentifier(fromIdentity: Data("<html>captive portal</html>".utf8)))
    }
}

// MARK: - Test Helpers

/// Minimal PlexConnection for testing
struct PlexConnection {
    let address: String
    let port: Int
    let local: Bool
    let relay: Bool
    let protocolType: String
}
