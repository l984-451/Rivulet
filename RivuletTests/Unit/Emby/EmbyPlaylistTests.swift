// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyPlaylistTests.swift
//  RivuletTests
//
//  Video playlists against FakeEmbyServer: request shapes, the video and audio split, entry ids
//  and move indexes. Replies are trimmed 4.10.2 captures.
//

import XCTest
@testable import Rivulet

@MainActor
final class EmbyPlaylistTests: XCTestCase {
    private let server = FakeEmbyServer()
    private let uid = EmbyLiveFixtures.userID
    private typealias Fixtures = EmbyPlaylistFixtures

    private func provider() -> EmbyProvider {
        EmbyProvider(serverID: "srv", displayName: "Emby", userID: uid, policy: EmbySession.Policy(),
                     client: EmbyClient(baseURL: EmbyBrowseFixtures.baseURL, token: "tok", transport: server.transport))
    }

    private func ref(_ id: String) -> MediaItemRef { MediaItemRef(providerID: "emby:srv", itemID: id) }

    private func query(_ request: URLRequest) -> [String: String] {
        let pairs = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(pairs.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
    }

    override func tearDown() async throws {
        XCTAssertEqual(server.headerProblems, [])
        try await super.tearDown()
    }

    // MARK: - Listing

    func test_supportsPlaylists() {
        XCTAssertTrue(provider().supportsPlaylists)
    }

    /// The music library's list is the audio set; video is every playlist minus it, sorted by title.
    func test_videoPlaylists_dropsThePlaylistsAMusicLibraryLists() async throws {
        server.respond("/Users/\(uid)/Views", body: Fixtures.views)
        server.respond("/Users/\(uid)/Items", query: ["ParentId": "7"], body: Fixtures.musicPlaylists)
        server.respond("/Users/\(uid)/Items", body: Fixtures.allPlaylists)
        let lists = try await provider().videoPlaylists()
        XCTAssertEqual(lists.map(\.item.ref.itemID), ["1801", "1791"])
        XCTAssertEqual(lists.map(\.item.title), ["Aa-weekend", "zz-userdata-form"])
        XCTAssertTrue(lists.allSatisfy { $0.item.kind == .playlist && !$0.isSmart })
        let asked = server.requests("GET", "/Users/\(uid)/Items").map(query)
        XCTAssertEqual(asked.map { $0["ParentId"] }, [nil, "7"])
        XCTAssertTrue(asked.allSatisfy { $0["IncludeItemTypes"] == "Playlist" && $0["Recursive"] == "true" })
        XCTAssertFalse(asked.contains { $0["MediaTypes"] != nil }, "MediaTypes=Audio with Playlist returns unrelated items")
    }

    func test_videoPlaylists_withoutAMusicLibrary_asksOnce() async throws {
        server.respond("/Users/\(uid)/Views", body: Fixtures.views.replacingOccurrences(of: "music", with: "tvshows"))
        server.respond("/Users/\(uid)/Items", body: Fixtures.allPlaylists)
        let lists = try await provider().videoPlaylists()
        XCTAssertEqual(lists.count, 3)
        XCTAssertEqual(server.requests("GET", "/Users/\(uid)/Items").count, 1)
    }

    func test_videoPlaylists_aFailedListingThrows() async {
        server.respond("/Users/\(uid)/Views", body: Fixtures.views)
        server.respond("/Users/\(uid)/Items", status: 500, body: "boom")
        do {
            _ = try await provider().videoPlaylists()
            XCTFail("a failed read must not look like no playlists")
        } catch {}
    }

    // MARK: - Entries

    func test_entries_useThePlaylistItemIdNotTheMediaId() async throws {
        server.respond("/Playlists/P/Items", body: Fixtures.entries)
        let contents = try await provider().playlistEntries(ref("P"))
        XCTAssertEqual(contents.entries.map(\.entryID), ["21", "22"])
        XCTAssertEqual(contents.entries.map(\.item.ref.itemID), ["857", "873"])
        XCTAssertFalse(contents.isSmart)
        let sent = query(server.requests[0])
        XCTAssertEqual(sent["UserId"], uid)
        XCTAssertEqual(sent["StartIndex"], "0")
        XCTAssertEqual(sent["Limit"], "200")
    }

    func test_entries_aRowWithoutAPlaylistItemIdIsLeftOut() async throws {
        server.respond("/Playlists/P/Items", body: Fixtures.entryWithoutID)
        let contents = try await provider().playlistEntries(ref("P"))
        XCTAssertTrue(contents.entries.isEmpty)
    }

    func test_entries_followTheTotalAcrossPages() async throws {
        server.respond("/Playlists/P/Items", query: ["StartIndex": "0"],
                       body: #"{"Items":[{"Name":"A","Id":"1","PlaylistItemId":"10","Type":"Movie"}],"TotalRecordCount":2}"#)
        server.respond("/Playlists/P/Items", query: ["StartIndex": "1"],
                       body: #"{"Items":[{"Name":"B","Id":"2","PlaylistItemId":"11","Type":"Movie"}],"TotalRecordCount":2}"#)
        let contents = try await provider().playlistEntries(ref("P"))
        XCTAssertEqual(contents.entries.map(\.entryID), ["10", "11"])
        XCTAssertEqual(server.requests.count, 2)
    }

    /// Ids renumber after an add, so a refetch returns the new ones and nothing is carried over.
    func test_entryIDs_comeFromTheLatestRead() async throws {
        server.respond("/Playlists/P/Items", method: "GET", replies: [
            .init(body: Fixtures.entries), .init(body: Fixtures.entriesAfterAdd)
        ])
        server.respond("/Playlists/P/Items", method: "POST", body: #"{"Id":"P","ItemAddedCount":1}"#)
        let p = provider()
        let before = try await p.playlistEntries(ref("P")).entries
        try await p.addToPlaylist(ref("P"), items: [ref("858")])
        let after = try await p.playlistEntries(ref("P")).entries
        XCTAssertEqual(before.map(\.entryID), ["21", "22"])
        XCTAssertEqual(after.map(\.entryID), ["31", "32", "33"])
    }

    // MARK: - Writes

    func test_create_sendsAQueryWithACommaIdsAndReadsItBack() async throws {
        server.respond("/Playlists", method: "POST", body: Fixtures.created)
        server.respond("/Users/\(uid)/Items/1809", body: Fixtures.createdItem)
        let made = try await provider().createPlaylist(title: "Tom & Jerry + Co", seededWith: [ref("857"), ref("873")])
        XCTAssertEqual(made.item.ref.itemID, "1809")
        XCTAssertEqual(made.item.kind, .playlist)
        XCTAssertFalse(made.isSmart)
        let post = try XCTUnwrap(server.requests("POST", "/Playlists").first)
        let sent = query(post)
        XCTAssertEqual(sent["Name"], "Tom & Jerry + Co")
        XCTAssertEqual(sent["Ids"], "857,873")
        XCTAssertEqual(sent["MediaType"], "Video")
        XCTAssertEqual(sent["UserId"], uid)
        XCTAssertNil(post.httpBody, "Ids as a JSON array is a 500, so it rides in the query")
    }

    func test_create_withNoItemsOmitsIds() async throws {
        server.respond("/Playlists", method: "POST", body: #"{"Id":"1809","Name":"x","ItemAddedCount":0}"#)
        server.respond("/Users/\(uid)/Items/1809", body: Fixtures.createdItem)
        _ = try await provider().createPlaylist(title: "x", seededWith: [])
        XCTAssertNil(query(server.requests[0])["Ids"])
    }

    func test_add_sendsCommaIdsAndTheUser() async throws {
        server.respond("/Playlists/P/Items", method: "POST", body: #"{"Id":"P","ItemAddedCount":2}"#)
        try await provider().addToPlaylist(ref("P"), items: [ref("857"), ref("873")])
        let sent = query(server.requests[0])
        XCTAssertEqual(sent["Ids"], "857,873")
        XCTAssertEqual(sent["UserId"], uid)
    }

    func test_add_withNoItemsSendsNothing() async throws {
        try await provider().addToPlaylist(ref("P"), items: [])
        XCTAssertTrue(server.requests.isEmpty)
    }

    func test_remove_namesTheEntryNotTheMedia() async throws {
        server.respond("/Playlists/P/Items", method: "DELETE", status: 204)
        server.respond("/Playlists/P/Items", body: Fixtures.entries)
        let p = provider()
        let entry = try await p.playlistEntries(ref("P")).entries[0]
        try await p.removeFromPlaylist(ref("P"), entryID: entry.entryID)
        let delete = try XCTUnwrap(server.requests("DELETE", "/Playlists/P/Items").first)
        XCTAssertEqual(query(delete)["EntryIds"], "21")
        XCTAssertNotEqual(query(delete)["EntryIds"], entry.item.ref.itemID)
    }

    func test_move_isTheFinalIndex() async throws {
        server.respond("/Playlists/P/Items/21/Move/1", method: "POST", status: 204)
        let entries = [PlaylistEntry(entryID: "21", item: JellyfinFixtures.mediaItem("857", kind: .movie, providerID: "emby:srv")),
                       PlaylistEntry(entryID: "22", item: JellyfinFixtures.mediaItem("873", kind: .movie, providerID: "emby:srv")),
                       PlaylistEntry(entryID: "23", item: JellyfinFixtures.mediaItem("858", kind: .movie, providerID: "emby:srv"))]
        try await provider().movePlaylistEntry(ref("P"), entryID: "21", toIndex: 1, in: entries)
        XCTAssertEqual(server.requests.last?.httpMethod, "POST")
        XCTAssertEqual(server.requests.last?.url?.path, "/Playlists/P/Items/21/Move/1")
    }

    func test_move_staysInsideTheList() async throws {
        server.respond("/Playlists/P/Items/21/Move/2", method: "POST", status: 204)
        server.respond("/Playlists/P/Items/21/Move/0", method: "POST", status: 204)
        let item = JellyfinFixtures.mediaItem("857", kind: .movie, providerID: "emby:srv")
        let entries = ["21", "22", "23"].map { PlaylistEntry(entryID: $0, item: item) }
        let p = provider()
        try await p.movePlaylistEntry(ref("P"), entryID: "21", toIndex: 99, in: entries)
        try await p.movePlaylistEntry(ref("P"), entryID: "21", toIndex: -1, in: entries)
        XCTAssertEqual(server.requests.map { $0.url!.path }, ["/Playlists/P/Items/21/Move/2", "/Playlists/P/Items/21/Move/0"])
    }

    func test_rename_postsNameAndEmptyProviderIds() async throws {
        server.respond("/Items/P", method: "POST", status: 204)
        try await provider().renamePlaylist(ref("P"), title: "Weekend")
        let body = server.jsonBody(0)
        XCTAssertEqual(body["Name"] as? String, "Weekend")
        XCTAssertEqual((body["ProviderIds"] as? [String: String])?.isEmpty, true, "omitting ProviderIds is a 400")
    }

    func test_delete_isNotGatedOnCanDelete() async throws {
        server.respond("/Items/P", method: "DELETE", status: 204)
        try await provider().deletePlaylist(ref("P"))
        XCTAssertEqual(server.requests.map { "\($0.httpMethod ?? "") \($0.url!.path)" }, ["DELETE /Items/P"])
    }
}
