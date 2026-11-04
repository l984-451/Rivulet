// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyWatchStateAndDeleteTests.swift
//  RivuletTests
//
//  Marking a series or season played goes to the server as one native call (measured live: every
//  episode under it flips), and the delete confirmation: Emby names a movie's folder, the other
//  providers keep the standard text.
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbyWatchStateAndDeleteTests: XCTestCase {
    private let server = FakeEmbyServer()
    private let uid = EmbyLiveFixtures.userID
    private typealias Fixtures = EmbyPlaylistFixtures

    private func provider() -> EmbyProvider {
        EmbyProvider(serverID: "srv", displayName: "Emby", userID: uid, policy: EmbySession.Policy(),
                     client: EmbyClient(baseURL: EmbyBrowseFixtures.baseURL, token: "tok", transport: server.transport))
    }

    private func ref(_ id: String) -> MediaItemRef { MediaItemRef(providerID: "emby:srv", itemID: id) }

    private func item(_ id: String, _ kind: MediaKind) -> MediaItem {
        JellyfinFixtures.mediaItem(id, kind: kind, providerID: "emby:srv")
    }

    override func tearDown() async throws {
        XCTAssertEqual(server.headerProblems, [])
        try await super.tearDown()
    }

    // MARK: - Mark played

    func test_markPlayed_onASeriesIsOneNativeCall() async throws {
        server.respond("/Users/\(uid)/PlayedItems/1661", method: "POST", body: Fixtures.seriesPlayed)
        try await provider().markPlayed(ref("1661"))
        XCTAssertEqual(server.requests.map { "\($0.httpMethod ?? "") \($0.url!.path)" }, ["POST /Users/\(uid)/PlayedItems/1661"])
    }

    func test_markUnplayed_onASeasonIsOneNativeCall() async throws {
        server.respond("/Users/\(uid)/PlayedItems/1663", method: "DELETE", body: Fixtures.seriesPlayed)
        try await provider().markUnplayed(ref("1663"))
        XCTAssertEqual(server.requests.map { "\($0.httpMethod ?? "") \($0.url!.path)" }, ["DELETE /Users/\(uid)/PlayedItems/1663"])
    }

    // MARK: - Delete confirmation

    private func standard(_ item: MediaItem, _ name: String) -> String {
        item.kind == .show || item.kind == .season
            ? String(localized: "Every episode's files will be deleted from \(name). This cannot be undone.")
            : String(localized: "The files will be deleted from \(name). This cannot be undone.")
    }

    func test_emby_movie_namesTheFolder() async {
        server.respond("/Items/858/DeleteInfo", body: Fixtures.movieDeleteInfo)
        let text = await provider().deleteConfirmation(for: item("858", .movie))
        XCTAssertEqual(text, String(localized: "The folder \u{201C}Up (2009)\u{201D} and everything in it will be deleted from Emby. This cannot be undone."))
    }

    func test_emby_movieThatIsALooseFile_keepsTheStandardText() async {
        server.respond("/Items/858/DeleteInfo", body: Fixtures.fileDeleteInfo)
        let movie = item("858", .movie)
        let text = await provider().deleteConfirmation(for: movie)
        XCTAssertEqual(text, standard(movie, "Emby"))
    }

    func test_emby_windowsFolderPath_namesOnlyTheFolder() async {
        server.respond("/Items/858/DeleteInfo", body: #"{"Paths":["C:\\Movies\\Up (2009)"]}"#)
        let text = await provider().deleteConfirmation(for: item("858", .movie))
        XCTAssertEqual(text, String(localized: "The folder \u{201C}Up (2009)\u{201D} and everything in it will be deleted from Emby. This cannot be undone."))
    }

    func test_emby_looseFileWithAnUncommonExtension_keepsTheStandardText() async {
        server.respond("/Items/858/DeleteInfo", body: #"{"Paths":["D:/Movies/Clip.flv"]}"#)
        let movie = item("858", .movie)
        let text = await provider().deleteConfirmation(for: movie)
        XCTAssertEqual(text, standard(movie, "Emby"))
    }

    func test_emby_failedRead_keepsTheStandardText() async {
        server.respond("/Items/858/DeleteInfo", status: 500, body: "boom")
        let movie = item("858", .movie)
        let text = await provider().deleteConfirmation(for: movie)
        XCTAssertEqual(text, standard(movie, "Emby"))
    }

    func test_emby_episodeAndShow_keepTheStandardTextWithoutARequest() async {
        let p = provider()
        for kind in [MediaKind.episode, .show, .season] {
            let subject = item("1", kind)
            let text = await p.deleteConfirmation(for: subject)
            XCTAssertEqual(text, standard(subject, "Emby"))
        }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func test_jellyfin_keepsTheStandardText() async {
        let jellyfin = JellyfinProvider(serverID: "srv", displayName: "NAS", userID: "user-1",
                                        client: JellyfinClient(baseURL: JellyfinFixtures.baseURL, token: "tok",
                                                               transport: FakeJellyfinServer().transport))
        for kind in [MediaKind.movie, .episode, .show, .season] {
            let subject = JellyfinFixtures.mediaItem("m1", kind: kind)
            let text = await jellyfin.deleteConfirmation(for: subject)
            XCTAssertEqual(text, standard(subject, "NAS"))
        }
    }

    func test_plex_keepsTheStandardText() async {
        let plex = PlexProvider(machineIdentifier: "test", displayName: "Test", serverURL: "http://plex.test", authToken: "t",
                                networkManager: PlexNetworkManager.shared)
        for kind in [MediaKind.movie, .show] {
            let subject = JellyfinFixtures.mediaItem("m1", kind: kind, providerID: "plex:test")
            let text = await plex.deleteConfirmation(for: subject)
            XCTAssertEqual(text, standard(subject, "Test"))
        }
    }
}
