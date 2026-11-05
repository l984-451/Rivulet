// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexProviderSeamTests.swift
//  RivuletTests
//
//  The seam members iOS needed on Plex (stage 3a): hub paging, the unwatched
//  filter, trending, owned-by-id lookup, sized images, show logos, promoted
//  hubs and the list item's genres and external ids.
//

import XCTest
@testable import Rivulet

@MainActor
final class PlexProviderSeamTests: XCTestCase {

    private final class StubNetwork: PlexNetworkManager, @unchecked Sendable {
        var hubCalls: [(key: String, identifier: String?, start: Int, count: Int)] = []
        var hubReply: (items: [PlexMetadata], totalSize: Int?) = ([], nil)
        var libraryCalls: [(section: String, start: Int, size: Int, sort: String?, collections: Bool, filters: [URLQueryItem])] = []
        var libraryReply: (items: [PlexMetadata], totalSize: Int?) = ([], nil)
        var guidCalls: [[String]] = []
        var owned: [PlexMetadata] = []
        var metadataCalls: [String] = []
        var metadata: [String: PlexMetadata] = [:]

        override func getHubItems(serverURL: String, authToken: String, hubKey: String, hubIdentifier: String?,
                                  start: Int, count: Int) async throws -> (items: [PlexMetadata], totalSize: Int?) {
            hubCalls.append((hubKey, hubIdentifier, start, count))
            return hubReply
        }

        override func getLibraryItemsWithTotal(
            serverURL: String, authToken: String, sectionId: String, start: Int, size: Int, sort: String?,
            type: Int?, includeGuids: Bool, followCollectionMode: Bool, filters: [URLQueryItem]
        ) async throws -> (items: [PlexMetadata], totalSize: Int?) {
            libraryCalls.append((sectionId, start, size, sort, followCollectionMode, filters))
            return libraryReply
        }

        override func findByGuids(serverURL: String, authToken: String, guids: [String]) async throws -> [PlexMetadata] {
            guidCalls.append(guids)
            return owned
        }

        override func getMetadata(serverURL: String, authToken: String, ratingKey: String,
                                  includeGuids: Bool) async throws -> PlexMetadata {
            metadataCalls.append(ratingKey)
            guard let meta = metadata[ratingKey] else { throw PlexAPIError.invalidURL }
            return meta
        }
    }

    private func provider(
        _ network: StubNetwork,
        lookup: @escaping @Sendable (TitleMatch, String) async -> String? = { _, _ in nil }
    ) -> PlexProvider {
        PlexProvider(machineIdentifier: "test", displayName: "Test", serverURL: "http://plex.test", authToken: "t",
                     networkManager: network, accountToken: { "acct" }, guidLookup: lookup)
    }

    private func meta(_ key: String, type: String = "movie", guid: String? = nil, section: Int? = nil,
                      art: String? = "/art") -> PlexMetadata {
        var m = PlexMetadata()
        m.ratingKey = key
        m.type = type
        m.title = "T\(key)"
        m.guid = guid
        m.librarySectionID = section
        m.art = art
        return m
    }

    private func mapped(_ m: PlexMetadata) -> MediaItem {
        PlexMediaMapper.item(m, providerID: "plex:test", serverURL: "http://plex.test", authToken: "t")
    }

    private func queryDict(_ url: URL) -> [String: String] {
        let pairs = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(pairs.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: - Hub paging

    func test_hub_mapsPagingKeyAndPromotion() {
        let hub = PlexHub(hubIdentifier: "movie.recentlyadded.1", title: "Recently Added", type: "movie",
                          key: "/hubs/sections/1/recentlyAdded?type=1", promoted: true, Metadata: [meta("1")])
        let mappedHub = PlexMediaMapper.hub(hub, providerID: "plex:test", serverURL: "http://plex.test", authToken: "t")
        XCTAssertEqual(mappedHub.pagingKey, "/hubs/sections/1/recentlyAdded?type=1")
        XCTAssertTrue(mappedHub.isPromoted)
    }

    func test_hub_hubKeyIsTheFallbackAndPromotionDefaultsOff() {
        let hub = PlexHub(hubIdentifier: "x", title: "X", hubKey: "/hubs/sections/1/x", Metadata: [])
        let mappedHub = PlexMediaMapper.hub(hub, providerID: "plex:test", serverURL: "http://plex.test", authToken: "t")
        XCTAssertEqual(mappedHub.pagingKey, "/hubs/sections/1/x")
        XCTAssertFalse(mappedHub.isPromoted)
    }

    func test_hub_continueWatchingAndLiteralIdListsDoNotPage() {
        let cw = PlexHub(hubIdentifier: "home.continue", title: "Continue Watching", key: "/hubs/continueWatching/items")
        let ids = PlexHub(hubIdentifier: "x", title: "X", key: "/library/metadata/1,2,3")
        for hub in [cw, ids] {
            XCTAssertNil(PlexMediaMapper.hub(hub, providerID: "plex:test", serverURL: "u", authToken: "t").pagingKey)
        }
    }

    /// `/hubs/items` answers 404 without `identifier`, so the key carries it.
    func test_hub_hubsItemsKeyCarriesTheIdentifier() throws {
        let hub = PlexHub(hubIdentifier: "home.movies.recent", title: "R", key: "/hubs/items")
        let key = try XCTUnwrap(PlexMediaMapper.hub(hub, providerID: "plex:test", serverURL: "u", authToken: "t").pagingKey)
        XCTAssertEqual(key, "/hubs/items?identifier=home.movies.recent")
        let url = try XCTUnwrap(PlexNetworkManager.hubItemsURL(serverURL: "http://plex.test", hubKey: key,
                                                               hubIdentifier: nil, start: 24, count: 24))
        XCTAssertEqual(url.path, "/hubs/items")
        XCTAssertEqual(queryDict(url), ["identifier": "home.movies.recent",
                                        "X-Plex-Container-Start": "24", "X-Plex-Container-Size": "24"])
    }

    func test_hubPage_asksTheKeyAndReportsTheNextPage() async throws {
        let network = StubNetwork()
        network.hubReply = ([meta("1"), meta("2")], 5)
        let hub = MediaHub(id: "h", providerID: "plex:test", title: "H", style: .shelf, items: [],
                           pagingKey: "/hubs/sections/1/recentlyAdded?type=1")
        let page = try await provider(network).hubPage(hub, page: Page(offset: 2, limit: 2))
        XCTAssertEqual(network.hubCalls.map(\.key), ["/hubs/sections/1/recentlyAdded?type=1"])
        XCTAssertEqual(network.hubCalls.map(\.start), [2])
        XCTAssertEqual(network.hubCalls.map(\.count), [2])
        XCTAssertEqual(page.items.map(\.ref.itemID), ["1", "2"])
        XCTAssertEqual(page.total, 5)
        XCTAssertEqual(page.nextPage, Page(offset: 4, limit: 2))
    }

    func test_hubPage_lastPageHasNoNext() async throws {
        let network = StubNetwork()
        network.hubReply = ([meta("5")], 5)
        let hub = MediaHub(id: "h", providerID: "plex:test", title: "H", style: .shelf, items: [], pagingKey: "/k")
        let page = try await provider(network).hubPage(hub, page: Page(offset: 4, limit: 2))
        XCTAssertNil(page.nextPage)
    }

    func test_hubPage_withoutAKeyIsTheRowItself() async throws {
        let network = StubNetwork()
        let row = MediaHub(id: "h", providerID: "plex:test", title: "H", style: .shelf, items: [mapped(meta("1"))])
        let first = try await provider(network).hubPage(row, page: Page(offset: 0, limit: 24))
        XCTAssertEqual(first.items.map(\.ref.itemID), ["1"])
        XCTAssertEqual(first.total, 1)
        XCTAssertNil(first.nextPage)
        let second = try await provider(network).hubPage(row, page: Page(offset: 24, limit: 24))
        XCTAssertTrue(second.items.isEmpty)
        XCTAssertTrue(network.hubCalls.isEmpty)
    }

    // MARK: - Unwatched filter

    func test_items_unwatchedOnlySendsTheFilter() async throws {
        let network = StubNetwork()
        network.libraryReply = ([meta("1")], 1)
        let library = MediaLibrary(id: "7", providerID: "plex:test", title: "Movies", kind: .movies)
        _ = try await provider(network).items(in: library, sort: .titleAsc, unwatchedOnly: true, page: Page(offset: 0, limit: 50))
        let call = try XCTUnwrap(network.libraryCalls.first)
        XCTAssertEqual(call.section, "7")
        XCTAssertEqual(call.filters.map { "\($0.name)=\($0.value ?? "")" }, ["unwatched=1"])
        XCTAssertEqual(call.sort, "titleSort:asc")
    }

    func test_items_aProviderThatExcludesCollectionsAsksForTitlesOnly() async throws {
        let network = StubNetwork()
        let library = MediaLibrary(id: "7", providerID: "plex:test", title: "Movies", kind: .movies)
        let titlesOnly = PlexProvider(machineIdentifier: "test", displayName: "Test", serverURL: "http://plex.test",
                                      authToken: "t", includesCollections: false, networkManager: network)
        _ = try await titlesOnly.items(in: library, sort: .titleAsc, unwatchedOnly: false, page: Page(offset: 0, limit: 50))
        XCTAssertEqual(network.libraryCalls.first?.collections, false)
    }

    func test_registry_hostCanTurnCollectionsOffForEveryPlexProvider() {
        let registry = MediaProviderRegistry()
        MediaProviderRegistry.plexIncludesCollections = false
        defer { MediaProviderRegistry.plexIncludesCollections = true }
        registry.populate(plexServerURL: "http://plex.test", plexToken: "t", plexMachineID: "m", plexName: "P")
        XCTAssertEqual((registry.plexProvider as? PlexProvider)?.includesCollections, false)
    }

    func test_mappedEpisodeAndSeason_carryTheShowsPlexGuid() {
        var episode = meta("e", type: "episode", guid: "plex://episode/1")
        episode.grandparentGuid = "plex://show/abc"
        var season = meta("s", type: "season", guid: "plex://season/1")
        season.parentGuid = "plex://show/abc"
        XCTAssertEqual(mapped(episode).externalIDs?["showPlex"], "plex://show/abc")
        XCTAssertEqual(mapped(season).externalIDs?["showPlex"], "plex://show/abc")
        XCTAssertNil(mapped(meta("m", guid: "plex://movie/2")).externalIDs?["showPlex"])
    }

    func test_mappedItem_namesItsLibrary() {
        XCTAssertEqual(mapped(meta("1", section: 12)).libraryID, "12")
        XCTAssertNil(mapped(meta("2")).libraryID)
    }

    func test_items_threeArgumentFormSendsNoFilter() async throws {
        let network = StubNetwork()
        let library = MediaLibrary(id: "7", providerID: "plex:test", title: "Movies", kind: .movies)
        _ = try await provider(network).items(in: library, sort: .addedAtDesc, page: Page(offset: 0, limit: 50))
        XCTAssertEqual(network.libraryCalls.first?.filters.count, 0)
        XCTAssertEqual(network.libraryCalls.first?.collections, true)
    }

    func test_libraryItemsURL_putsStartWithSizeAndTheFilter() throws {
        let url = try XCTUnwrap(PlexNetworkManager.libraryItemsURL(
            serverURL: "http://plex.test", sectionId: "7", start: 50, size: 25, sort: "addedAt:desc",
            filters: [URLQueryItem(name: "unwatched", value: "1")]))
        XCTAssertEqual(url.path, "/library/sections/7/all")
        XCTAssertEqual(queryDict(url), ["X-Plex-Container-Start": "50", "X-Plex-Container-Size": "25",
                                        "sort": "addedAt:desc", "unwatched": "1"])
    }

    // MARK: - Trending and owned-by-id

    private func trending(_ id: Int, _ type: TMDBMediaType) -> TMDBListItem {
        TMDBListItem(id: id, title: "", overview: nil, posterPath: nil, backdropPath: nil,
                     releaseDate: nil, voteAverage: nil, mediaType: type)
    }

    func test_trending_resolvesGuidsThenKeepsTrendingOrderInTheLibrary() async throws {
        let network = StubNetwork()
        network.owned = [meta("b", guid: "plex://movie/b", section: 1), meta("a", guid: "plex://movie/a", section: 1),
                         meta("other", guid: "plex://movie/o", section: 2)]
        let guids = ["101": "plex://movie/a", "102": "plex://movie/b", "103": "plex://movie/o"]
        let p = provider(network, lookup: { title, _ in guids[title.externalIDs["tmdb"] ?? ""] })
        let library = MediaLibrary(id: "1", providerID: "plex:test", title: "Movies", kind: .movies)
        let items = try await p.trending(in: library, from: [trending(101, .movie), trending(102, .movie), trending(103, .movie)], limit: 10)
        XCTAssertEqual(items.map(\.ref.itemID), ["a", "b"], "trending order, this library only")
        XCTAssertEqual(network.guidCalls, [["plex://movie/a", "plex://movie/b", "plex://movie/o"]])
    }

    func test_trending_moviesLibraryDropsShows() async throws {
        let network = StubNetwork()
        network.owned = [meta("m", type: "movie", guid: "plex://movie/m"), meta("s", type: "show", guid: "plex://show/s")]
        let guids = ["111": "plex://movie/m", "112": "plex://show/s"]
        let p = provider(network, lookup: { title, _ in guids[title.externalIDs["tmdb"] ?? ""] })
        let library = MediaLibrary(id: "1", providerID: "plex:test", title: "Movies", kind: .movies)
        let items = try await p.trending(in: library, from: [trending(111, .movie), trending(112, .tv)], limit: 10)
        XCTAssertEqual(items.map(\.ref.itemID), ["m"])
    }

    func test_ownedItems_usesAGivenPlexGuidWithoutALookup() async throws {
        let network = StubNetwork()
        network.owned = [meta("a", guid: "plex://movie/a"), meta("b", type: "show", guid: "plex://show/b")]
        let titles = [TitleMatch(kind: .show, externalIDs: ["tvdb": "9"], plexGUID: "plex://show/b"),
                      TitleMatch(kind: .movie, externalIDs: [:], plexGUID: "plex://movie/a")]
        let items = try await provider(network, lookup: { _, _ in XCTFail("no lookup"); return nil })
            .ownedItems(matching: titles, limit: 10)
        XCTAssertEqual(items.map(\.ref.itemID), ["b", "a"], "title order")
        XCTAssertEqual(network.guidCalls, [["plex://show/b", "plex://movie/a"]])
    }

    func test_ownedItems_limitCuts() async throws {
        let network = StubNetwork()
        network.owned = [meta("a", guid: "g/a"), meta("b", guid: "g/b")]
        let titles = [TitleMatch(kind: .movie, externalIDs: [:], plexGUID: "g/a"),
                      TitleMatch(kind: .movie, externalIDs: [:], plexGUID: "g/b")]
        let items = try await provider(network).ownedItems(matching: titles, limit: 1)
        XCTAssertEqual(items.map(\.ref.itemID), ["a"])
    }

    func test_ownedItems_noGuidsMakesNoRequest() async throws {
        let network = StubNetwork()
        let items = try await provider(network).ownedItems(
            matching: [TitleMatch(kind: .movie, externalIDs: ["tmdb": "1"], plexGUID: nil)], limit: 10)
        XCTAssertTrue(items.isEmpty)
        XCTAssertTrue(network.guidCalls.isEmpty)
    }

    func test_titleMatch_fromAWatchlistEntryReadsItsExternalGuids() {
        let entry = PlexWatchlistItem(id: "x", title: "T", year: nil, type: .show, posterURL: nil,
                                      guids: ["tmdb://1396", "imdb://tt0903747", "tvdb://81189"], plexGUID: "plex://show/abc")
        let title = TitleMatch(entry)
        XCTAssertEqual(title.kind, .show)
        XCTAssertEqual(title.externalIDs, ["tmdb": "1396", "imdb": "tt0903747", "tvdb": "81189"])
        XCTAssertEqual(title.plexGUID, "plex://show/abc")
    }

    // MARK: - Image sizing

    func test_imageURL_asksThePhotoTranscoderForTheServerPath() throws {
        let art = try XCTUnwrap(PlexMediaMapper.artworkURL("/library/metadata/1/thumb/5", serverURL: "http://plex.test", authToken: "t"))
        let sized = provider(StubNetwork()).imageURL(art, width: 180, height: 270)
        XCTAssertEqual(sized.path, "/photo/:/transcode")
        XCTAssertEqual(queryDict(sized), ["url": "/library/metadata/1/thumb/5", "width": "180", "height": "270",
                                          "minSize": "1", "X-Plex-Token": "t"])
    }

    func test_imageURL_keepsTheArtworksOwnQueryButNotItsToken() throws {
        let art = try XCTUnwrap(PlexMediaMapper.artworkURL("/library/collections/9/composite/1?width=400&height=600",
                                                           serverURL: "http://plex.test", authToken: "t"))
        let sized = provider(StubNetwork()).imageURL(art, width: 100, height: 150)
        XCTAssertEqual(queryDict(sized)["url"], "/library/collections/9/composite/1?width=400&height=600")
    }

    func test_imageURL_aCdnUrlIsPassedAbsolute() throws {
        let cdn = try XCTUnwrap(URL(string: "https://metadata-static.plex.tv/a/b.jpg"))
        let sized = provider(StubNetwork()).imageURL(cdn, width: 60, height: 60)
        XCTAssertEqual(queryDict(sized)["url"], "https://metadata-static.plex.tv/a/b.jpg")
    }

    /// Another server's URL (a Jellyfin or Emby image, anything with a token) must not reach this Plex server.
    func test_imageURL_aForeignUrlComesBackUnchanged() throws {
        for raw in ["http://emby.local:8096/Items/1/Images/Primary?api_key=secret",
                    "https://jf.example.com/Items/1/Images/Primary?tag=a",
                    "http://other-plex.test:32400/library/metadata/1/thumb/5?X-Plex-Token=theirs",
                    "https://image.tmdb.org/t/p/w500/a.jpg"] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertEqual(provider(StubNetwork()).imageURL(url, width: 100, height: 150), url, raw)
        }
    }

    func test_imageURL_aServerRelativePathIsTranscoded() throws {
        let relative = try XCTUnwrap(URL(string: "/library/metadata/1/thumb/5"))
        let sized = provider(StubNetwork()).imageURL(relative, width: 100, height: 150)
        XCTAssertEqual(sized.path, "/photo/:/transcode")
        XCTAssertEqual(queryDict(sized)["url"], "/library/metadata/1/thumb/5")
    }

    func test_imageURL_plexTvHostsAreTranscodedAbsolute() throws {
        for raw in ["https://plex.tv/users/a/avatar", "https://metadata-static.plex.tv/a/b.jpg", "https://image.plex.tv/x.jpg"] {
            let sized = provider(StubNetwork()).imageURL(try XCTUnwrap(URL(string: raw)), width: 60, height: 60)
            XCTAssertEqual(sized.path, "/photo/:/transcode", raw)
            XCTAssertEqual(queryDict(sized)["url"], raw)
        }
        let lookalike = try XCTUnwrap(URL(string: "https://evilplex.tv/a.jpg"))
        XCTAssertEqual(provider(StubNetwork()).imageURL(lookalike, width: 60, height: 60), lookalike)
    }

    // MARK: - Show logos

    private func logoMeta(key: String, path: String) -> PlexMetadata {
        var m = meta(key, type: "show")
        m.Image = [PlexImage(alt: nil, type: "clearLogo", url: path)]
        return m
    }

    func test_logoURL_anEpisodeResolvesItsShowsLogoOnce() async throws {
        let network = StubNetwork()
        network.metadata["show-1"] = logoMeta(key: "show-1", path: "/library/metadata/show-1/clearLogo/9")
        var ep = meta("ep-1", type: "episode")
        ep.grandparentRatingKey = "show-1"
        let item = mapped(ep)
        let p = provider(network)
        let first = await p.logoURL(for: item)
        let second = await p.logoURL(for: item)
        XCTAssertEqual(first?.absoluteString, "http://plex.test/library/metadata/show-1/clearLogo/9?X-Plex-Token=t")
        XCTAssertEqual(second, first)
        XCTAssertEqual(network.metadataCalls, ["show-1"], "cached after the first")
    }

    func test_logoURL_aSeasonResolvesItsShow() async {
        let network = StubNetwork()
        network.metadata["show-1"] = logoMeta(key: "show-1", path: "/l/1")
        var season = meta("s-1", type: "season")
        season.parentRatingKey = "show-1"
        let url = await provider(network).logoURL(for: mapped(season))
        XCTAssertNotNil(url)
        XCTAssertEqual(network.metadataCalls, ["show-1"])
    }

    func test_logoURL_aMovieWithALogoNeedsNoRequest() async {
        let network = StubNetwork()
        var movie = meta("m-1")
        movie.Image = [PlexImage(alt: nil, type: "clearLogo", url: "/l/m")]
        let url = await provider(network).logoURL(for: mapped(movie))
        XCTAssertEqual(url?.absoluteString, "http://plex.test/l/m?X-Plex-Token=t")
        XCTAssertTrue(network.metadataCalls.isEmpty)
    }

    func test_logoURL_aMissIsRememberedToo() async {
        let network = StubNetwork()
        network.metadata["m-1"] = meta("m-1")
        let item = mapped(meta("m-1"))
        let p = provider(network)
        let first = await p.logoURL(for: item)
        let second = await p.logoURL(for: item)
        XCTAssertNil(first)
        XCTAssertNil(second)
        XCTAssertEqual(network.metadataCalls, ["m-1"])
    }

    // MARK: - Promoted hubs, pinned libraries, list fields

    func test_library_pinnedToHomeFollowsHidden() throws {
        func library(hidden: Int?) throws -> PlexLibrary {
            let hiddenJSON = hidden.map { #","hidden":\#($0)"# } ?? ""
            return try JSONDecoder().decode(PlexLibrary.self, from:
                Data(#"{"key":"1","type":"movie","title":"M","uuid":"u"\#(hiddenJSON)}"#.utf8))
        }
        XCTAssertTrue(PlexMediaMapper.library(try library(hidden: nil), providerID: "p").isPinnedToHome)
        XCTAssertTrue(PlexMediaMapper.library(try library(hidden: 0), providerID: "p").isPinnedToHome)
        XCTAssertFalse(PlexMediaMapper.library(try library(hidden: 1), providerID: "p").isPinnedToHome)
        XCTAssertFalse(PlexMediaMapper.library(try library(hidden: 2), providerID: "p").isPinnedToHome)
    }

    func test_item_carriesGenresAndExternalIDs() {
        var m = meta("1", guid: "plex://movie/abc")
        m.Genre = [PlexTag(tag: "Drama"), PlexTag(tag: "Crime")]
        m.Guid = [PlexGuid(id: "tmdb://603"), PlexGuid(id: "imdb://tt0133093"), PlexGuid(id: "tvdb://169")]
        let item = mapped(m)
        XCTAssertEqual(item.genres, ["Drama", "Crime"])
        XCTAssertEqual(item.externalIDs, ["tmdb": "603", "imdb": "tt0133093", "tvdb": "169", "plex": "plex://movie/abc"])
    }

    func test_item_withoutThemHasNone() {
        let item = mapped(meta("1"))
        XCTAssertNil(item.genres)
        XCTAssertNil(item.externalIDs)
    }
}
