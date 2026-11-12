// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexDeviceDecodingTests.swift
//  RivuletTests
//
//  Tests for PlexDevice JSON decoding edge cases
//

import XCTest
@testable import Rivulet

final class PlexDeviceDecodingTests: XCTestCase {

    /// Test that PlexDevice can be decoded when `device` field is null
    /// Regression test for RIVULET-6 / GitHub Issue #4
    func testDecodesWithNullDeviceField() throws {
        let json = """
        {
            "name": "Test Server",
            "product": "Plex Media Server",
            "productVersion": "1.40.0",
            "platform": "Linux",
            "platformVersion": "22.04",
            "device": null,
            "clientIdentifier": "abc123",
            "createdAt": "2024-01-01T00:00:00Z",
            "lastSeenAt": "2024-01-01T00:00:00Z",
            "provides": "server",
            "connections": []
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()

        // `device` is optional, so this must not throw.
        let device = try decoder.decode(PlexDevice.self, from: json)

        XCTAssertEqual(device.name, "Test Server")
        XCTAssertEqual(device.provides, "server")
        XCTAssertNil(device.device)
    }

    /// Test that PlexDevice still decodes correctly when `device` field is present
    func testDecodesWithDeviceFieldPresent() throws {
        let json = """
        {
            "name": "Test Server",
            "product": "Plex Media Server",
            "productVersion": "1.40.0",
            "platform": "Linux",
            "platformVersion": "22.04",
            "device": "PC",
            "clientIdentifier": "abc123",
            "createdAt": "2024-01-01T00:00:00Z",
            "lastSeenAt": "2024-01-01T00:00:00Z",
            "provides": "server",
            "connections": []
        }
        """.data(using: .utf8)!

        let decoder = JSONDecoder()
        let device = try decoder.decode(PlexDevice.self, from: json)

        XCTAssertEqual(device.name, "Test Server")
        XCTAssertEqual(device.device, "PC")
    }

    /// Test that an array of PlexDevices decodes when one has null device
    /// This matches the actual failure scenario from Sentry
    func testDecodesArrayWithMixedDeviceFields() throws {
        let json = """
        [
            {
                "name": "Server 1",
                "product": "Plex Media Server",
                "productVersion": "1.40.0",
                "platform": "Linux",
                "platformVersion": "22.04",
                "device": "NAS",
                "clientIdentifier": "server1",
                "createdAt": "2024-01-01T00:00:00Z",
                "lastSeenAt": "2024-01-01T00:00:00Z",
                "provides": "server",
                "connections": []
            },
            {
                "name": "Orphaned Device",
                "product": "Plex Web",
                "productVersion": "4.0.0",
                "platform": null,
                "platformVersion": null,
                "device": null,
                "clientIdentifier": "orphan",
                "createdAt": "2024-01-01T00:00:00Z",
                "lastSeenAt": "2024-01-01T00:00:00Z",
                "provides": "player",
                "connections": []
            }
        ]
        """.data(using: .utf8)!

        let decoder = JSONDecoder()

        // Index 1 has a null `device`.
        let devices = try decoder.decode([PlexDevice].self, from: json)

        XCTAssertEqual(devices.count, 2)
        XCTAssertEqual(devices[0].device, "NAS")
        XCTAssertNil(devices[1].device)
    }

    // #619: a server that is also a player lists more than one role.
    func testIsServerReadsCommaList() throws {
        func device(_ provides: String) throws -> PlexDevice {
            let json = """
            {"name":"S","product":"Plex Media Server","productVersion":"1","clientIdentifier":"s",
             "createdAt":"","lastSeenAt":"","provides":"\(provides)"}
            """
            return try JSONDecoder().decode(PlexDevice.self, from: Data(json.utf8))
        }
        XCTAssertTrue(try device("server").isServer)
        XCTAssertTrue(try device("server,client,player,pubsub-player").isServer)
        XCTAssertTrue(try device("client, server").isServer)
        XCTAssertFalse(try device("client,player,pubsub-player").isServer)
        XCTAssertFalse(try device("").isServer)
    }
}
