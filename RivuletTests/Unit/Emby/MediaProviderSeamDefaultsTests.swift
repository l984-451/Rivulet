// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaProviderSeamDefaultsTests.swift
//  RivuletTests
//
//  The seam members Emby needed (remove from Continue Watching, refresh gate, star rating),
//  pinned for the providers that keep the defaults, so Plex and Jellyfin do not change.
//

import XCTest
@testable import Rivulet

@MainActor
final class MediaProviderSeamDefaultsTests: XCTestCase {
    private func jellyfin(_ server: FakeJellyfinServer) -> JellyfinProvider {
        JellyfinProvider(serverID: "srv", displayName: "NAS", userID: "user-1",
                         client: JellyfinClient(baseURL: JellyfinFixtures.baseURL, token: "tok", transport: server.transport))
    }

    private final class RecordingNetwork: PlexNetworkManager, @unchecked Sendable {
        var removed: [String] = []
        override func removeFromContinueWatching(serverURL: String, authToken: String, ratingKey: String) async throws {
            removed.append(ratingKey)
        }
    }

    private func plex(_ network: RecordingNetwork) -> PlexProvider {
        PlexProvider(machineIdentifier: "test", displayName: "Test", serverURL: "http://plex.test", authToken: "t",
                     networkManager: network)
    }

    private func item(_ id: String, _ kind: MediaKind, provider: String) -> MediaItem {
        JellyfinFixtures.mediaItem(id, kind: kind, providerID: provider)
    }

    // MARK: - Jellyfin keeps today's behavior

    func test_jellyfin_removeFromContinueWatching_clearsAMoviesPosition() async throws {
        let server = FakeJellyfinServer()
        server.respond("/UserItems/m1/UserData", status: 204)
        try await jellyfin(server).removeFromContinueWatching(item("m1", .movie, provider: "jellyfin:srv"))
        XCTAssertEqual(server.requests.count, 1)
        XCTAssertEqual(server.requests[0].url?.path, "/UserItems/m1/UserData")
        XCTAssertEqual(server.jsonBody(0)["PlaybackPositionTicks"] as? Int, 0)
    }

    func test_jellyfin_removeFromContinueWatching_leavesAnEpisodeAlone() async throws {
        let server = FakeJellyfinServer()
        let provider = jellyfin(server)
        let episode = item("e1", .episode, provider: "jellyfin:srv")
        try await provider.removeFromContinueWatching(episode)
        XCTAssertTrue(server.requests.isEmpty, "clearing an episode's position only moves it to Next Up")
        XCTAssertFalse(provider.canRemoveFromContinueWatching(episode))
        XCTAssertTrue(provider.canRemoveFromContinueWatching(item("m1", .movie, provider: "jellyfin:srv")))
    }

    func test_jellyfin_canRefreshMetadata_isStillOffered() async {
        let canRefresh = await jellyfin(FakeJellyfinServer()).canRefreshMetadata()
        XCTAssertTrue(canRefresh)
    }

    // MARK: - Plex keeps its own removal

    func test_plex_removeFromContinueWatching_usesPlexsOwnCall() async throws {
        let network = RecordingNetwork()
        let provider = plex(network)
        try await provider.removeFromContinueWatching(item("10", .movie, provider: "plex:test"))
        try await provider.removeFromContinueWatching(item("11", .episode, provider: "plex:test"))
        XCTAssertEqual(network.removed, ["10", "11"])
    }

    func test_plex_menuGates_keepTheirDefaults() async {
        let provider = plex(RecordingNetwork())
        let canRefresh = await provider.canRefreshMetadata()
        XCTAssertTrue(canRefresh)
        XCTAssertTrue(provider.canRemoveFromContinueWatching(item("10", .movie, provider: "plex:test")))
        XCTAssertFalse(provider.canRemoveFromContinueWatching(item("11", .episode, provider: "plex:test")))
    }
}
