// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryShuffleTests.swift
//  RivuletTests
//
//  Shuffle (#543): which libraries offer it, what each server is asked for,
//  and the queue a show or library shuffle plays.
//

import XCTest
@testable import Rivulet

@MainActor
final class LibraryShuffleTests: XCTestCase {

    private func library(_ kind: MediaLibrary.LibraryKind, id: String = "7", providerID: String = "plex:test") -> MediaLibrary {
        MediaLibrary(id: id, providerID: providerID, title: "L", kind: kind)
    }

    private func queryDict(_ url: URL?) -> [String: String] {
        let pairs = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems } ?? []
        return Dictionary(pairs.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Which libraries

    func test_onlyVideoLibrariesShuffle() {
        XCTAssertTrue(library(.movies).canShuffle)
        XCTAssertTrue(library(.shows).canShuffle)
        XCTAssertTrue(library(.mixed).canShuffle)
        XCTAssertFalse(library(.music).canShuffle)
        XCTAssertFalse(library(.photos).canShuffle)
        XCTAssertFalse(library(.liveTV).canShuffle)
    }

    // MARK: - Folder page

    private struct NoFolders: FolderProvider {
        func folderPage(in library: MediaLibrary, folder: MediaItemRef?, page: Page) async throws -> FolderPage {
            FolderPage(entries: [], nextPage: nil)
        }
    }

    func test_folderPage_shufflesItsWholeVideoLibrary() {
        let misc = library(.mixed, id: "misc")
        XCTAssertEqual(FolderLibraryViewController.shuffleLibrary(from: { (NoFolders(), misc) }), misc)
        XCTAssertNil(FolderLibraryViewController.shuffleLibrary(from: { (NoFolders(), self.library(.photos)) }))
        XCTAssertNil(FolderLibraryViewController.shuffleLibrary(from: { nil }), "no provider registered yet")
    }

    // MARK: - Plex

    private final class StubNetwork: PlexNetworkManager, @unchecked Sendable {
        var calls: [(section: String, start: Int, size: Int, sort: String?, type: Int?, filters: [URLQueryItem])] = []
        var reply: [PlexMetadata] = []

        override func getLibraryItemsWithTotal(
            serverURL: String, authToken: String, sectionId: String, start: Int, size: Int, sort: String?,
            type: Int?, includeGuids: Bool, followCollectionMode: Bool, filters: [URLQueryItem]
        ) async throws -> (items: [PlexMetadata], totalSize: Int?) {
            calls.append((sectionId, start, size, sort, type, filters))
            return (reply, reply.count)
        }
    }

    private func plex(_ network: StubNetwork) -> PlexProvider {
        PlexProvider(machineIdentifier: "test", displayName: "Test", serverURL: "http://plex.test", authToken: "t",
                     networkManager: network)
    }

    func test_plex_tvLibraryAsksForRandomEpisodesFromTheTop() async throws {
        let network = StubNetwork()
        var episode = PlexMetadata()
        episode.ratingKey = "e1"
        episode.type = "episode"
        network.reply = [episode]
        let items = try await plex(network).shuffledItems(in: library(.shows), unwatchedOnly: false, limit: 200)
        XCTAssertEqual(items.map(\.ref.itemID), ["e1"])
        let call = try XCTUnwrap(network.calls.first)
        XCTAssertEqual(call.section, "7")
        XCTAssertEqual(call.sort, "random")
        XCTAssertEqual(call.type, 4)
        XCTAssertEqual(call.start, 0)
        XCTAssertEqual(call.size, 200)
        XCTAssertTrue(call.filters.isEmpty)
    }

    func test_plex_movieLibraryAsksForMoviesAndTheUnwatchedFilter() async throws {
        let network = StubNetwork()
        _ = try await plex(network).shuffledItems(in: library(.movies), unwatchedOnly: true, limit: 200)
        let call = try XCTUnwrap(network.calls.first)
        XCTAssertEqual(call.type, 1)
        XCTAssertEqual(call.filters.map { "\($0.name)=\($0.value ?? "")" }, ["unwatched=1"])
    }

    func test_plex_typePerLibraryKind() {
        XCTAssertEqual(PlexProvider.shuffleType(for: .movies), 1)
        XCTAssertEqual(PlexProvider.shuffleType(for: .shows), 4)
        XCTAssertNil(PlexProvider.shuffleType(for: .mixed))
    }

    /// Plex ignores X-Plex-Container-Size unless X-Plex-Container-Start rides with it.
    func test_plex_shuffleURLSendsStartWithSize() {
        let url = PlexNetworkManager.libraryItemsURL(
            serverURL: "http://plex.test", sectionId: "7", start: 0, size: 200, sort: "random", type: 4,
            filters: [URLQueryItem(name: "unwatched", value: "1")])
        let q = queryDict(url)
        XCTAssertEqual(url?.path, "/library/sections/7/all")
        XCTAssertEqual(q["X-Plex-Container-Start"], "0")
        XCTAssertEqual(q["X-Plex-Container-Size"], "200")
        XCTAssertEqual(q["sort"], "random")
        XCTAssertEqual(q["type"], "4")
        XCTAssertEqual(q["unwatched"], "1")
        XCTAssertNil(q["includeCollections"])
    }

    // MARK: - Jellyfin

    private let jellyfinServer = FakeJellyfinServer()

    private func jellyfin() -> JellyfinProvider {
        JellyfinProvider(serverID: "srv", displayName: "NAS", userID: "user-1",
                         client: JellyfinClient(baseURL: JellyfinFixtures.baseURL, token: "tok",
                                                transport: jellyfinServer.transport))
    }

    func test_jellyfin_tvLibraryAsksForRandomEpisodesRecursively() async throws {
        jellyfinServer.respond("/Items", body: #"{"Items":[{"Id":"e1","Name":"Pilot","Type":"Episode"}],"TotalRecordCount":98}"#)
        let items = try await jellyfin().shuffledItems(in: library(.shows, id: "lib-tv", providerID: "jellyfin:srv"),
                                                       unwatchedOnly: false, limit: 200)
        XCTAssertEqual(items.map(\.ref.itemID), ["e1"])
        let request = try XCTUnwrap(jellyfinServer.requests.first)
        let q = queryDict(request.url)
        XCTAssertEqual(request.url?.path, "/Items")
        XCTAssertEqual(q["parentId"], "lib-tv")
        XCTAssertEqual(q["recursive"], "true")
        XCTAssertEqual(q["includeItemTypes"], "Episode")
        XCTAssertEqual(q["sortBy"], "Random")
        XCTAssertEqual(q["limit"], "200")
        XCTAssertEqual(q["isMissing"], "false", "no unaired placeholder episodes")
        XCTAssertNil(q["filters"])
    }

    func test_jellyfin_unwatchedSendsIsUnplayed() async throws {
        jellyfinServer.respond("/Items", body: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await jellyfin().shuffledItems(in: library(.movies, id: "lib-m", providerID: "jellyfin:srv"),
                                               unwatchedOnly: true, limit: 200)
        let q = queryDict(jellyfinServer.requests.first?.url)
        XCTAssertEqual(q["includeItemTypes"], "Movie")
        XCTAssertEqual(q["filters"], "IsUnplayed")
    }

    func test_jellyfin_typesPerLibraryKind() {
        XCTAssertEqual(JellyfinProvider.shuffleItemTypes(for: .movies), "Movie")
        XCTAssertEqual(JellyfinProvider.shuffleItemTypes(for: .shows), "Episode")
        XCTAssertEqual(JellyfinProvider.shuffleItemTypes(for: .mixed), "Movie,Video,MusicVideo,Episode")
    }

    // MARK: - Emby

    private let embyServer = FakeEmbyServer()
    private var embyItems: String { "/Users/\(EmbyLiveFixtures.userID)/Items" }

    private func emby() -> EmbyProvider {
        EmbyProvider(serverID: "srv", displayName: "Emby", userID: EmbyLiveFixtures.userID, policy: EmbySession.Policy(),
                     client: EmbyClient(baseURL: EmbyBrowseFixtures.baseURL, token: "tok", transport: embyServer.transport))
    }

    override func tearDown() async throws {
        XCTAssertEqual(embyServer.headerProblems, [])
        try await super.tearDown()
    }

    func test_emby_mixedLibraryAsksForRandomVideosOfEveryKind() async throws {
        embyServer.respond(embyItems, body: #"{"Items":[{"Id":"333","Name":"Clip","Type":"Video"}],"TotalRecordCount":623}"#)
        let items = try await emby().shuffledItems(in: library(.mixed, id: "11", providerID: "emby:srv"),
                                                   unwatchedOnly: false, limit: 200)
        XCTAssertEqual(items.map(\.ref.itemID), ["333"])
        let request = try XCTUnwrap(embyServer.requests.first)
        let q = queryDict(request.url)
        XCTAssertEqual(request.url?.path, embyItems)
        XCTAssertEqual(q["ParentId"], "11")
        XCTAssertEqual(q["Recursive"], "true")
        XCTAssertEqual(q["IncludeItemTypes"], "Movie,Video,MusicVideo,Episode")
        XCTAssertEqual(q["SortBy"], "Random")
        XCTAssertEqual(q["Limit"], "200")
        XCTAssertEqual(q["ExcludeLocationTypes"], "Virtual", "no unaired placeholder episodes")
        XCTAssertNil(q["Filters"])
    }

    func test_emby_dropsAVirtualEpisodeTheServerSendsAnyway() async throws {
        embyServer.respond(embyItems, body: """
            {"Items":[{"Id":"1","Name":"Aired","Type":"Episode","LocationType":"FileSystem"},
                      {"Id":"2","Name":"Unaired","Type":"Episode","LocationType":"Virtual"}],"TotalRecordCount":2}
            """)
        let items = try await emby().shuffledItems(in: library(.shows, id: "5", providerID: "emby:srv"),
                                                   unwatchedOnly: false, limit: 200)
        XCTAssertEqual(items.map(\.ref.itemID), ["1"])
    }

    func test_emby_unwatchedSendsIsUnplayed() async throws {
        embyServer.respond(embyItems, body: #"{"Items":[],"TotalRecordCount":0}"#)
        _ = try await emby().shuffledItems(in: library(.shows, id: "5", providerID: "emby:srv"),
                                           unwatchedOnly: true, limit: 200)
        let q = queryDict(embyServer.requests.first?.url)
        XCTAssertEqual(q["IncludeItemTypes"], "Episode")
        XCTAssertEqual(q["Filters"], "IsUnplayed")
    }

    // MARK: - Queues

    private func episode(_ id: String) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "stub", itemID: id),
            kind: .episode, title: id, sortTitle: nil, overview: nil,
            year: nil, runtime: nil, parentRef: nil, grandparentRef: nil,
            episodeNumber: nil, seasonNumber: nil, childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil, grandparentArtwork: nil
        )
    }

    func test_showQueue_holdsEveryEpisodeOnceFromTheTop() async throws {
        let stub = StubMediaProvider()
        stub.episodesByShow["show"] = (1...20).map { episode("e\($0)") }
        let queue = try await stub.shuffleQueue(forShow: MediaItemRef(providerID: "stub", itemID: "show"))
        let entries = try XCTUnwrap(queue).entries
        XCTAssertEqual(queue?.index, 0)
        XCTAssertEqual(Set(entries.map(\.ref.itemID)), Set((1...20).map { "e\($0)" }))
        XCTAssertEqual(entries.count, 20)
    }

    func test_showQueue_isNilForAShowWithNoEpisodes() async throws {
        let queue = try await StubMediaProvider().shuffleQueue(forShow: MediaItemRef(providerID: "stub", itemID: "none"))
        XCTAssertNil(queue)
    }

    func test_libraryQueue_asksForTheCapAndPlaysWhatCameBack() async throws {
        jellyfinServer.respond("/Items", body: """
            {"Items":[{"Id":"a","Name":"A","Type":"Movie"},{"Id":"b","Name":"B","Type":"Movie"}],"TotalRecordCount":2}
            """)
        let queue = try await jellyfin().shuffleQueue(for: library(.movies, id: "lib-m", providerID: "jellyfin:srv"))
        XCTAssertEqual(Set(try XCTUnwrap(queue).entries.map(\.ref.itemID)), ["a", "b"])
        XCTAssertEqual(queryDict(jellyfinServer.requests.first?.url)["limit"], String(MediaLibrary.shuffleLimit))
        XCTAssertEqual(MediaLibrary.shuffleLimit, 200)
    }

    func test_libraryQueue_isNilForAnEmptyLibrary() async throws {
        jellyfinServer.respond("/Items", body: #"{"Items":[],"TotalRecordCount":0}"#)
        let queue = try await jellyfin().shuffleQueue(for: library(.movies, id: "lib-m", providerID: "jellyfin:srv"),
                                                      unwatchedOnly: true)
        XCTAssertNil(queue)
        XCTAssertEqual(queryDict(jellyfinServer.requests.first?.url)["filters"], "IsUnplayed")
    }

    func test_defaultProviderRefusesALibraryShuffle() async {
        do {
            _ = try await StubMediaProvider().shuffledItems(in: library(.movies), unwatchedOnly: false, limit: 200)
            XCTFail("a provider must not pretend to shuffle")
        } catch {}
    }
}
