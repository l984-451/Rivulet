// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Synchronization
import XCTest
@testable import Rivulet

/// The key a download is filed under must not move when the registry re-ids the selected Plex server.
final class DownloadIdentityTests: XCTestCase {
    private var savedSelected: Set<String> = []
    private var savedExtra: Set<String> = []

    override func setUp() {
        super.setUp()
        savedSelected = MediaItemRef.selectedPlexIDs.withLock { $0 }
        savedExtra = MediaItemRef.extraPlexIDs.withLock { $0 }
        MediaItemRef.selectedPlexIDs.withLock { $0 = ["plex:abcd1234hash", "plex:MACHINE"] }
        MediaItemRef.extraPlexIDs.withLock { $0 = ["plex:OTHER"] }
    }

    override func tearDown() {
        MediaItemRef.selectedPlexIDs.withLock { $0 = savedSelected }
        MediaItemRef.extraPlexIDs.withLock { $0 = savedExtra }
        super.tearDown()
    }

    private func ref(_ provider: String) -> MediaItemRef { MediaItemRef(providerID: provider, itemID: "1") }

    func test_selectedServer_isKeyedByMachineIdWhateverIdTheRegistryMinted() {
        XCTAssertEqual(DownloadIdentity.providerID(for: ref("plex:abcd1234hash"), selectedPlexMachineID: "MACHINE"), "plex:MACHINE")
        XCTAssertEqual(DownloadIdentity.providerID(for: ref("plex:MACHINE"), selectedPlexMachineID: "MACHINE"), "plex:MACHINE")
    }

    func test_selectedServer_withNoKnownMachineIdUsesTheBareKey() {
        XCTAssertEqual(DownloadIdentity.providerID(for: ref("plex:abcd1234hash"), selectedPlexMachineID: nil), "plex:")
    }

    func test_extraServer_keepsItsOwnId() {
        XCTAssertEqual(DownloadIdentity.providerID(for: ref("plex:OTHER"), selectedPlexMachineID: "MACHINE"), "plex:OTHER")
    }

    func test_unknownPlexServer_hasNoKey() {
        XCTAssertNil(DownloadIdentity.providerID(for: ref("plex:GONE"), selectedPlexMachineID: "MACHINE"))
    }

    func test_otherKinds_keepTheProviderId() {
        XCTAssertEqual(DownloadIdentity.providerID(for: ref("jellyfin:srv"), selectedPlexMachineID: "MACHINE"), "jellyfin:srv")
        XCTAssertEqual(DownloadIdentity.providerID(for: ref("emby:srv"), selectedPlexMachineID: nil), "emby:srv")
    }

    func test_matches_exactOrBarePlexOnly() {
        XCTAssertTrue(DownloadIdentity.matches("plex:MACHINE", "plex:MACHINE"))
        XCTAssertFalse(DownloadIdentity.matches("plex:MACHINE", "plex:OTHER"))
        // A record made before the server was known belongs to whichever Plex server is asked.
        XCTAssertTrue(DownloadIdentity.matches("plex:", "plex:MACHINE"))
        XCTAssertTrue(DownloadIdentity.matches("plex:MACHINE", "plex:"))
        XCTAssertFalse(DownloadIdentity.matches("plex:", "jellyfin:srv"))
        XCTAssertTrue(DownloadIdentity.matches("jellyfin:srv", "jellyfin:srv"))
        XCTAssertFalse(DownloadIdentity.matches("jellyfin:srv", "jellyfin:other"))
        XCTAssertFalse(DownloadIdentity.matches("jellyfin:srv", "emby:srv"))
    }

    func test_machineIdAndKeyHelpers() {
        XCTAssertEqual(DownloadIdentity.plexProviderID(machineID: "M"), "plex:M")
        XCTAssertEqual(DownloadIdentity.plexProviderID(machineID: nil), "plex:")
        XCTAssertEqual(DownloadIdentity.plexMachineID(of: "plex:M"), "M")
        XCTAssertNil(DownloadIdentity.plexMachineID(of: "plex:"))
        XCTAssertNil(DownloadIdentity.plexMachineID(of: "emby:M"))
    }
}
