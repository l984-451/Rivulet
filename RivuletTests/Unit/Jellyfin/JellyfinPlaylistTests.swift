// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinPlaylistTests.swift
//  RivuletTests
//
//  Fixtures trimmed from a Jellyfin 12.1 server's real answers.
//

import XCTest
@testable import Rivulet

@MainActor
final class JellyfinPlaylistTests: XCTestCase {
    private let server = FakeJellyfinServer()
    private let pid = "jellyfin:srv"

    private func provider() -> JellyfinProvider {
        JellyfinProvider(
            serverID: "srv", displayName: "NAS", userID: "user-1",
            client: JellyfinClient(baseURL: JellyfinFixtures.baseURL, token: "tok", transport: server.transport)
        )
    }

    private func ref(_ id: String) -> MediaItemRef { MediaItemRef(providerID: pid, itemID: id) }

    func test_videoPlaylists_dropsAudio() async throws {
        server.respond("/Items", body: """
        {"Items":[{"Name":"Songs","Id":"a1","Type":"Playlist","MediaType":"Audio","ChildCount":3},
                  {"Name":"Movie night","Id":"v1","Type":"Playlist","MediaType":"Video","ChildCount":2}],
         "TotalRecordCount":2}
        """)
        let lists = try await provider().videoPlaylists()
        XCTAssertEqual(lists.map(\.item.title), ["Movie night"])
        XCTAssertFalse(lists[0].isSmart)
    }

    func test_playlistKind_maps() {
        XCTAssertEqual(JellyfinMediaMapper.kind("Playlist"), .playlist)
    }

    func test_entries_carryPlaylistItemId() async throws {
        server.respond("/Playlists/P/Items", body: """
        {"Items":[{"Name":"Pilot","Id":"ep1","Type":"Episode","PlaylistItemId":"pi-1"},
                  {"Name":"Heat","Id":"m1","Type":"Movie"}],"TotalRecordCount":2}
        """)
        let entries = try await provider().playlistEntries(ref("P")).entries
        XCTAssertEqual(entries.map(\.entryID), ["pi-1", "m1"])
        XCTAssertEqual(entries.map(\.item.title), ["Pilot", "Heat"])
    }

    func test_move_sendsAbsoluteIndex() async throws {
        XCTAssertEqual(JellyfinProvider.movePath(playlist: "P", entryID: "E", toIndex: 1), "Playlists/P/Items/E/Move/1")
        server.respond("/Move/1", status: 204)
        try await provider().movePlaylistEntry(ref("P"), entryID: "E", toIndex: 1, in: [])
        XCTAssertEqual(server.requests.last?.httpMethod, "POST")
        XCTAssertEqual(server.requests.last?.url?.path, "/Playlists/P/Items/E/Move/1")
    }

    func test_create_sendsVideoBody() async throws {
        server.respond("/Playlists", body: #"{"Id":"new1"}"#)
        server.respond("/Items/new1", body: #"{"Name":"Fresh","Id":"new1","Type":"Playlist","MediaType":"Video"}"#)
        let made = try await provider().createPlaylist(title: "Fresh", seededWith: [ref("m1")])
        XCTAssertEqual(made.item.ref.itemID, "new1")
        XCTAssertEqual(made.item.kind, .playlist)
        let body = server.jsonBody(0)
        XCTAssertEqual(body["Name"] as? String, "Fresh")
        XCTAssertEqual(body["Ids"] as? [String], ["m1"])
        XCTAssertEqual(body["UserId"] as? String, "user-1")
        XCTAssertEqual(body["MediaType"] as? String, "Video")
    }

    func test_remove_rename_delete() async throws {
        server.respond("/Playlists/P/Items", status: 204)
        server.respond("/Playlists/P", status: 204)
        server.respond("/Items/P", status: 204)
        let p = provider()
        try await p.removeFromPlaylist(ref("P"), entryID: "E")
        XCTAssertEqual(server.requests[0].httpMethod, "DELETE")
        XCTAssertEqual(server.query(0).first { $0.name == "entryIds" }?.value, "E")
        try await p.renamePlaylist(ref("P"), title: "New")
        XCTAssertEqual(server.jsonBody(1)["Name"] as? String, "New")
        try await p.deletePlaylist(ref("P"))
        XCTAssertEqual(server.requests[2].httpMethod, "DELETE")
        XCTAssertEqual(server.requests[2].url?.path, "/Items/P")
    }
}
