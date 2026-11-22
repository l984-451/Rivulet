// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class DiscoverOwnershipTests: XCTestCase {
    /// A Discover tile: a TMDB title.
    private func title(_ tmdb: Int, _ kind: MediaKind = .movie) -> MediaItem {
        JellyfinFixtures.mediaItem(TMDBMediaMapper.encodeItemID(tmdbId: tmdb, type: kind == .movie ? .movie : .tv),
                                   kind: kind, providerID: TMDBMediaMapper.providerID)
    }

    /// A server's copy carrying `ids`, in `library`.
    private func copy(_ id: String, on provider: String, _ kind: MediaKind = .movie, ids: [String: String],
                      library: String? = nil) -> MediaItem {
        let base = JellyfinFixtures.mediaItem(id, kind: kind, providerID: provider)
        return MediaItem(ref: base.ref, kind: kind, title: id, sortTitle: nil, overview: nil, year: nil, runtime: nil,
                         parentRef: nil, grandparentRef: nil, episodeNumber: nil, seasonNumber: nil, childProgress: nil,
                         userState: base.userState, artwork: base.artwork, parentArtwork: nil, grandparentArtwork: nil,
                         externalIDs: ids, libraryID: library)
    }

    private func check(_ ownership: DiscoverOwnership, _ rows: [[MediaItem]], _ providers: [any MediaProvider],
                       isShown: (MediaItem) -> Bool = { _ in true }) async {
        await ownership.check(rows, providers: providers, isShown: isShown)
    }

    func test_anOwnedTitleOpensTheCopy_andAnUnownedOneNothing() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        // Title 2 is a movie; the server's show with the same TMDB number is another title.
        plex.ownedItemsResult = [copy("p1", on: "plex:a", ids: ["tmdb": "1"]), copy("p2", on: "plex:a", .show, ids: ["tmdb": "2"])]
        let ownership = DiscoverOwnership()

        await check(ownership, [[title(1), title(2), title(3)]], [plex])

        XCTAssertEqual(ownership.copies[title(1).ref]?.ref.itemID, "p1")
        XCTAssertNil(ownership.copies[title(2).ref])
        XCTAssertNil(ownership.copies[title(3).ref])
        XCTAssertEqual(plex.ownedRequests.first, [1, 2, 3].map { TitleMatch(kind: .movie, externalIDs: ["tmdb": "\($0)"], plexGUID: nil) })
    }

    func test_twoServersOwningATitle_theFirstGivenWins() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.ownedItemsResult = [copy("p1", on: "plex:a", ids: ["tmdb": "1"])]
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jf.ownedItemsResult = [copy("j1", on: "jellyfin:s", ids: ["tmdb": "1", "imdb": "tt1"])]

        let jellyfinFirst = DiscoverOwnership()
        await check(jellyfinFirst, [[title(1)]], [jf, plex])
        XCTAssertEqual(jellyfinFirst.copies[title(1).ref]?.ref.providerID, "jellyfin:s")

        let plexFirst = DiscoverOwnership()
        await check(plexFirst, [[title(1)]], [plex, jf])
        XCTAssertEqual(plexFirst.copies[title(1).ref]?.ref.providerID, "plex:a")
    }

    func test_aCopyInAHiddenLibraryDoesNotCount() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.ownedItemsResult = [copy("p1", on: "plex:a", ids: ["tmdb": "1"], library: "hidden"),
                                 copy("p2", on: "plex:a", ids: ["tmdb": "2"], library: "hidden")]
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jf.ownedItemsResult = [copy("j1", on: "jellyfin:s", ids: ["tmdb": "1"], library: "shown")]
        let ownership = DiscoverOwnership()

        await check(ownership, [[title(1), title(2)]], [plex, jf], isShown: { $0.libraryID != "hidden" })

        XCTAssertEqual(ownership.copies[title(1).ref]?.ref.itemID, "j1", "the next server's shown copy")
        XCTAssertNil(ownership.copies[title(2).ref], "only in a hidden library")
    }

    /// A placeholder and the real file on one server: the server answers with both, so the refused one
    /// doesn't hide the other.
    func test_twoCopiesOnOneServer_theFirstRefused_theSecondOpens() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.ownedItemsResult = [copy("placeholder", on: "plex:a", ids: ["tmdb": "1"], library: "sugg"),
                                 copy("real", on: "plex:a", ids: ["tmdb": "1"], library: "movies")]
        let ownership = DiscoverOwnership()

        await check(ownership, [[title(1)]], [plex], isShown: { $0.libraryID != "sugg" })

        XCTAssertEqual(ownership.copies[title(1).ref]?.ref.itemID, "real")
    }

    /// Use in Discover turned off: an answer from that library is dropped before anything is asked.
    func test_aCopyNowRefusedIsDropped_evenForATitleNotAskedAgain() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.ownedItemsResult = [copy("p1", on: "plex:a", ids: ["tmdb": "1"], library: "sugg")]
        let ownership = DiscoverOwnership()
        await check(ownership, [[title(1)]], [plex])
        XCTAssertNotNil(ownership.copies[title(1).ref])

        await check(ownership, [], [plex], isShown: { $0.libraryID != "sugg" })
        XCTAssertNil(ownership.copies[title(1).ref])
    }

    func test_aFailingServerDoesNotSinkTheOthers() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.ownedItemsError = MediaProviderError.unreachable
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jf.ownedItemsResult = [copy("j1", on: "jellyfin:s", ids: ["tmdb": "1"])]
        let ownership = DiscoverOwnership()

        await check(ownership, [[title(1)]], [plex, jf])

        XCTAssertEqual(ownership.copies[title(1).ref]?.ref.itemID, "j1")
    }

    /// What Refresh is for: a title deleted from the server, or moved to a hidden library, stops opening it.
    func test_aRecheckDropsACopyThatIsGone() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.ownedItemsResult = [copy("p1", on: "plex:a", ids: ["tmdb": "1"])]
        let ownership = DiscoverOwnership()
        await check(ownership, [[title(1)]], [plex])
        XCTAssertNotNil(ownership.copies[title(1).ref])

        plex.ownedItemsResult = []
        await check(ownership, [[title(1)]], [plex])
        XCTAssertNil(ownership.copies[title(1).ref])
    }

    func test_answersAreDroppedWhenTheServersChange() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.ownedItemsResult = [copy("p1", on: "plex:a", ids: ["tmdb": "1"])]
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        let ownership = DiscoverOwnership()
        await check(ownership, [[title(1)]], [plex])
        XCTAssertNotNil(ownership.copies[title(1).ref])

        await check(ownership, [], [jf])
        XCTAssertTrue(ownership.copies.isEmpty, "dropped before any server answers")
    }

    /// Popular and Now Playing share titles: each is asked once, so a later row can't undo its answer.
    func test_aTitleInTwoRowsIsAskedOnce() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.ownedItemsResult = [copy("p1", on: "plex:a", ids: ["tmdb": "1"])]
        let ownership = DiscoverOwnership()

        await check(ownership, [[title(1)], [title(1), title(2)]], [plex])

        XCTAssertEqual(plex.ownedRequests.map { $0.map(\.externalIDs) }, [[["tmdb": "1"]], [["tmdb": "2"]]])
        XCTAssertEqual(ownership.copies[title(1).ref]?.ref.itemID, "p1")
    }

    func test_eachRowIsAskedOnItsOwn_inPageOrder() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.ownedItemsResult = [copy("p3", on: "plex:a", .show, ids: ["tmdb": "3"])]
        let ownership = DiscoverOwnership()

        await check(ownership, [[title(1), title(2)], [title(3, .show)]], [plex])

        XCTAssertEqual(plex.ownedRequests.map { $0.map(\.externalIDs) }, [[["tmdb": "1"], ["tmdb": "2"]], [["tmdb": "3"]]])
        XCTAssertEqual(ownership.copies[title(3, .show).ref]?.ref.itemID, "p3")
    }

    /// Plex is asked by plex:// guid; its copy is matched back by the TMDB id in its `Guid` array (what
    /// `includeGuids` on `findByGuids` brings). A copy naming only its plex:// guid can't be matched.
    func test_aPlexCopyIsMatchedByTheTMDBIdInItsGuids() async {
        var meta = PlexMetadata()
        meta.ratingKey = "42"
        meta.type = "movie"
        meta.guid = "plex://movie/abc"
        meta.Guid = [PlexGuid(id: "imdb://tt9"), PlexGuid(id: "tmdb://7")]
        var bare = meta
        bare.ratingKey = "43"
        bare.guid = "plex://movie/def"
        bare.Guid = nil
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.ownedItemsResult = [meta, bare].map { PlexMediaMapper.item($0, providerID: "plex:a", serverURL: "http://pms", authToken: "t") }
        let ownership = DiscoverOwnership()

        await check(ownership, [[title(7), title(8)]], [plex])

        XCTAssertEqual(ownership.copies[title(7).ref]?.ref.itemID, "42")
        XCTAssertNil(ownership.copies[title(8).ref])
    }
}
