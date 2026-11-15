// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The pure parts of the browse surfaces that Jellyfin items pass through.
@MainActor
final class JellyfinBrowseSurfaceTests: XCTestCase {
    private let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)

    private func menu(_ item: MediaItem, continueWatching: Bool = false) -> [[TileMenuAction]] {
        PlexHomeViewController.providerTileMenuSections(
            for: item, provider: provider, isContinueWatching: continueWatching,
            onWatchFromBeginning: {}, onMoreInfo: {}, onGoToEpisode: {}, onGoToShow: {}, onPlayVersion: {})
    }

    func test_posterCell_sourceBadge_clearsOnReuse() {
        let cell = PosterCell(frame: CGRect(x: 0, y: 0, width: 220, height: 400))
        cell.configure(item: JellyfinFixtures.mediaItem("m1"))
        cell.setSourceBadge("Jellyfin")
        XCTAssertEqual(cell.sourceBadgeText, "Jellyfin")
        cell.prepareForReuse()
        XCTAssertNil(cell.sourceBadgeText, "a recycled poster must not keep another item's server")
        cell.configure(item: JellyfinFixtures.mediaItem("m2"))
        XCTAssertNil(cell.sourceBadgeText, "configure alone never adds a badge")
    }

    func test_posterCell_noArtwork_showsTitle() {
        let cell = PosterCell(frame: CGRect(x: 0, y: 0, width: 220, height: 400))
        var show = PlexMetadata()
        show.type = "show"
        show.title = "Some Show"
        cell.configure(item: show)
        XCTAssertEqual(cell.failureTitleShown, "Some Show")
        cell.prepareForReuse()
        XCTAssertNil(cell.failureTitleShown)
    }

    // MARK: - Plex paths

    func test_kindOfAProviderID_comesFromTheRegistry_elseTheIDsOwnPrefix() {
        let registry = MediaProviderRegistry.shared
        let extra = StubMediaProvider(id: "plex:office", kind: .plex)
        registry.register(extra)
        defer { registry.unregister(providerID: extra.id) }

        XCTAssertEqual(registry.kind(of: "plex:office"), .plex)
        XCTAssertEqual(registry.kind(of: "jellyfin:gone"), .jellyfin, "a signed-out server's tiles keep their kind")
        XCTAssertNil(registry.kind(of: "tmdb"))
        XCTAssertEqual(MediaProviderKind(providerID: "jellyfin:srv"), .jellyfin)
        XCTAssertNil(MediaProviderKind(providerID: "jellyfinish:srv"))
        XCTAssertNil(MediaProviderKind(providerID: "plex"))
    }

    // MARK: - Tile menu

    func test_providerTileMenu_matchesThePlexMenu() {
        let episode = JellyfinFixtures.mediaItem("ep1", kind: .episode, played: true, grandparent: "show1")
        XCTAssertEqual(menu(episode).map { $0.map(\.title) },
                       [["Watch from Beginning", "More Info", "Go to Episode", "Go to Show"],
                        ["Mark as Unwatched"], ["Refresh Metadata"]])
        XCTAssertEqual(menu(JellyfinFixtures.mediaItem("m1")).map { $0.map(\.title) },
                       [["Watch from Beginning", "More Info"], ["Mark as Watched"], ["Refresh Metadata"]])
    }

    func test_providerTileMenu_continueWatching_removeOnlyWhereJellyfinCanDoIt() {
        let movie = JellyfinFixtures.mediaItem("m1")
        XCTAssertEqual(menu(movie, continueWatching: true)[1].map(\.title),
                       ["Mark as Watched", "Remove from Continue Watching"])
        let episode = JellyfinFixtures.mediaItem("ep1", kind: .episode, grandparent: "show1")
        XCTAssertFalse(menu(episode, continueWatching: true).joined().contains { $0.title == "Remove from Continue Watching" },
                       "an episode cleared from Resume comes straight back as Next Up")
    }

    func test_providerTileMenu_actionsGoThroughTheProvider_thenRepaint() async {
        let movie = JellyfinFixtures.mediaItem("m1")
        let sections = menu(movie, continueWatching: true)

        let watched = expectation(forNotification: .plexDataNeedsRefresh, object: nil)
        sections[1][0].handler()
        await fulfillment(of: [watched], timeout: 2)
        let removed = expectation(forNotification: .plexDataNeedsRefresh, object: nil)
        sections[1][1].handler()
        await fulfillment(of: [removed], timeout: 2)
        let refreshed = expectation(forNotification: .plexDataNeedsRefresh, object: nil)
        sections[2][0].handler()
        await fulfillment(of: [refreshed], timeout: 2)

        XCTAssertEqual(provider.markedPlayed, [movie.ref])
        XCTAssertEqual(provider.progressUpdates.map(\.0), [movie.ref])
        XCTAssertEqual(provider.progressUpdates.map(\.1), [0])
        XCTAssertEqual(provider.refreshed, [movie.ref])
    }

    // MARK: - Library page

    /// Jellyfin takes the seam's default: Plex's list minus resolution.
    func test_sortOptions_jellyfinMatchesPlexMinusResolution() {
        let jellyfin = JellyfinProvider(serverID: "srv", displayName: "NAS", userID: "u",
                                        client: JellyfinClient(baseURL: JellyfinFixtures.baseURL, token: "t"))
        XCTAssertEqual(jellyfin.sortOptions(for: .movies),
                       LibrarySortOption.options(for: "movie").filter { $0 != .resolutionDesc && $0 != .resolutionAsc })
        XCTAssertEqual(jellyfin.sortOptions(for: .shows), LibrarySortOption.options(for: "show"))
        XCTAssertEqual(jellyfin.sortOptions(for: .mixed), LibrarySortOption.options(for: nil))
    }

    /// The views ask the provider through the protocol, so a server that can
    /// sort differently takes its own list.
    func test_sortOptions_aProviderCanOverrideTheDefault() {
        let custom = StubMediaProvider(id: "x:1", kind: .jellyfin)
        custom.sortOverride = [.titleAsc, .resolutionDesc]
        let asProtocol: any MediaProvider = custom
        XCTAssertEqual(asProtocol.sortOptions(for: .movies), [.titleAsc, .resolutionDesc])
    }

    func test_providerSort_mapsEveryOfferedOption() {
        let pairs: [(LibrarySortOption, SortOption)] = [
            (.addedAtDesc, .addedAtDesc), (.addedAtAsc, .addedAtAsc), (.titleAsc, .titleAsc),
            (.titleDesc, .titleDesc), (.releaseDateDesc, .releaseDateDesc), (.releaseDateAsc, .releaseDateAsc),
            (.ratingDesc, .ratingDesc), (.lastEpisodeAddedDesc, .lastContentAddedDesc)
        ]
        for (option, expected) in pairs {
            XCTAssertEqual(PlexHomeViewController.providerSort(option), expected, "\(option)")
        }
        XCTAssertEqual(PlexHomeViewController.providerSort(.resolutionDesc), .addedAtDesc,
                       "a resolution sort stored before cannot be sent; Jellyfin would silently sort by title")
    }

    func test_heroItems_recentlyAddedFirst_withBackdrops_capped() {
        func art(_ id: String, backdrop: Bool, kind: MediaKind = .movie) -> MediaItem {
            let base = JellyfinFixtures.mediaItem(id, kind: kind)
            return MediaItem(ref: base.ref, kind: kind, title: id, sortTitle: nil, overview: nil, year: nil,
                             runtime: nil, parentRef: nil, grandparentRef: nil, episodeNumber: nil,
                             seasonNumber: nil, childProgress: nil, userState: base.userState,
                             artwork: MediaArtwork(poster: nil, backdrop: backdrop ? URL(string: "http://x/\(id)") : nil,
                                                   thumbnail: nil, logo: nil),
                             parentArtwork: nil, grandparentArtwork: nil)
        }
        let rows: CachedHomeRail = [
            CachedHomeHub(id: "cw", title: "Continue Watching", isContinueWatching: true, hubKey: nil,
                          hubIdentifier: nil, totalSize: nil, items: [art("c", backdrop: true)]),
            CachedHomeHub(id: "ra", title: "Recently Added in Movies", isContinueWatching: false, hubKey: nil,
                          hubIdentifier: nil, totalSize: nil,
                          items: [art("a", backdrop: true), art("b", backdrop: false)]
                              + (1...12).map { art("n\($0)", backdrop: true) })
        ]

        let hero = PlexHomeViewController.heroItems(from: rows)

        XCTAssertEqual(hero.first?.ref.itemID, "a", "the newest additions lead, as on a Plex library page")
        XCTAssertFalse(hero.contains { $0.ref.itemID == "b" }, "no backdrop, nothing to show behind the hero")
        XCTAssertFalse(hero.contains { $0.ref.itemID == "c" }, "Continue Watching has its own row")
        XCTAssertEqual(hero.count, 10)
    }

    /// A music library's Recently Added row lists albums; the hero leaves them out.
    func test_heroItems_skipAlbums() {
        func art(_ id: String, isMusic: Bool) -> MediaItem {
            let base = JellyfinFixtures.mediaItem(id)
            return MediaItem(ref: base.ref, kind: .movie, title: id, sortTitle: nil, overview: nil, year: nil,
                             runtime: nil, isMusic: isMusic, parentRef: nil, grandparentRef: nil, episodeNumber: nil,
                             seasonNumber: nil, childProgress: nil, userState: base.userState,
                             artwork: MediaArtwork(poster: nil, backdrop: URL(string: "http://x/\(id)"),
                                                   thumbnail: nil, logo: nil),
                             parentArtwork: nil, grandparentArtwork: nil)
        }
        let rows: CachedHomeRail = [
            CachedHomeHub(id: "mu", title: "Recently Added in Music", isContinueWatching: false, hubKey: nil,
                          hubIdentifier: nil, totalSize: nil, items: [art("album", isMusic: true)]),
            CachedHomeHub(id: "ra", title: "Recently Added in Movies", isContinueWatching: false, hubKey: nil,
                          hubIdentifier: nil, totalSize: nil, items: [art("movie", isMusic: false)])
        ]

        XCTAssertEqual(PlexHomeViewController.heroItems(from: rows).map(\.ref.itemID), ["movie"])
    }

    func test_heroItems_trendingFirst_fallsBackToRecentWhenTooFew() {
        func art(_ id: String) -> MediaItem {
            let base = JellyfinFixtures.mediaItem(id, kind: .movie)
            return MediaItem(ref: base.ref, kind: .movie, title: id, sortTitle: nil, overview: nil, year: nil,
                             runtime: nil, parentRef: nil, grandparentRef: nil, episodeNumber: nil,
                             seasonNumber: nil, childProgress: nil, userState: base.userState,
                             artwork: MediaArtwork(poster: nil, backdrop: URL(string: "http://x/\(id)"),
                                                   thumbnail: nil, logo: nil),
                             parentArtwork: nil, grandparentArtwork: nil)
        }
        let rows: CachedHomeRail = [
            CachedHomeHub(id: "ra", title: "Recently Added in Movies", isContinueWatching: false, hubKey: nil,
                          hubIdentifier: nil, totalSize: nil, items: [art("new")])
        ]

        let trending = PlexHomeViewController.heroItems(trending: [[art("m1"), art("m2")], [art("s1")]], rows: rows)
        XCTAssertEqual(trending.map(\.ref.itemID), ["m1", "s1", "m2"], "one library at a time")

        let few = PlexHomeViewController.heroItems(trending: [[art("m1")], [art("s1")]], rows: rows)
        XCTAssertEqual(few.map(\.ref.itemID), ["new"], "two matches are too few for a hero, as on Plex")
    }

    // MARK: - Home

    private func row(_ id: String, cw: Bool = false, pin: Bool = false) -> CachedHomeHub {
        CachedHomeHub(id: id, title: id, isContinueWatching: cw, hubKey: nil,
                      hubIdentifier: pin ? "rivulet.pin.\(id)" : id, totalSize: nil, items: [])
    }

    func test_homeRail_followsTheLibraryOrderAcrossServers_pinsStayWithTheirLibrary() {
        func lib(_ id: String, _ key: String?) -> CachedHomeHub {
            var hub = row(id)
            hub.libraryKey = key
            return hub
        }
        let rail = PlexHomeViewController.homeRail(
            plex: [row("plex-cw", cw: true), lib("angel-movies", "1"), lib("pin", nil), lib("angel-tv", "2")],
            otherServers: [lib("test-movies", "plex:test/1")],
            libraryOrder: ["1", "plex:test/1", "2"])
        XCTAssertEqual(rail.map(\.row.id), ["plex-cw", "angel-movies", "pin", "test-movies", "angel-tv"])
    }

    func test_homeRail_pairsContinueWatching_thenEachServersLibraryRows_pinsInPlace() {
        let rail = PlexHomeViewController.homeRail(
            plex: [row("plex-cw", cw: true), row("plex-movies"), row("plex-tv"), row("pin", pin: true)],
            otherServers: [row("jellyfin:srv|cw", cw: true), row("jellyfin:srv|movies")])

        XCTAssertEqual(rail.map(\.row.id),
                       ["plex-cw", "jellyfin:srv|cw", "plex-movies", "plex-tv", "pin", "jellyfin:srv|movies"])
        XCTAssertEqual(rail.map(\.kind), [.plex, .jellyfin, .plex, .plex, .plex, .jellyfin])
    }

    /// An extra Plex server's rows are Plex's, not tagged with the one other kind that exists.
    func test_homeRail_tagsEachRowWithItsServersRealKind() {
        let rail = PlexHomeViewController.homeRail(
            plex: [row("plex-movies")],
            otherServers: [row("plex:office|1.recentlyAdded"), row("jellyfin:srv|2.recentlyAdded"),
                           row("plex:gone|3.recentlyAdded")],
            kindOf: { $0 == "plex:gone" ? nil : MediaProviderKind(providerID: $0) })
        XCTAssertEqual(rail.map(\.kind), [.plex, .plex, .jellyfin, .plex])
    }

    func test_homeRail_plexOnly_keepsEachLibrarysPinsAfterItsRows() {
        let plex = [row("plex-cw", cw: true), row("plex-movies"), row("pin", pin: true), row("plex-tv")]
        let rail = PlexHomeViewController.homeRail(plex: plex, otherServers: [])
        XCTAssertEqual(rail.map(\.row.id), ["plex-cw", "plex-movies", "pin", "plex-tv"])
    }

    /// Favorites follow their library's rows; a hidden library's are dropped;
    /// pinned playlists come after every library row.
    func test_homeRail_personalRows_favoritesWithTheirLibrary_playlistsLast() {
        func lib(_ id: String, _ key: String?) -> CachedHomeHub {
            var hub = row(id)
            hub.libraryKey = key
            return hub
        }
        let rail = PlexHomeViewController.homeRail(
            plex: [row("plex-cw", cw: true), lib("angel-movies", "1"), lib("angel-tv", "2")],
            otherServers: [lib("test-movies", "jellyfin:test/m")],
            personal: [lib("fav-movies", "1"), lib("fav-hidden", "3"), lib("fav-test", "jellyfin:test/m"),
                       row("playlist")],
            libraryOrder: ["1", "jellyfin:test/m", "2"])
        XCTAssertEqual(rail.map(\.row.id),
                       ["plex-cw", "angel-movies", "fav-movies", "test-movies", "fav-test", "angel-tv", "playlist"])
    }

    /// A favorites or playlist row takes its kind from its items' server, Emby's included.
    func test_homeRail_personalRows_takeTheirItemsServerKind() {
        func personal(_ id: String, providerID: String) -> CachedHomeHub {
            let base = JellyfinFixtures.mediaItem(id, kind: .movie)
            let item = MediaItem(ref: MediaItemRef(providerID: providerID, itemID: id), kind: .movie, title: id,
                                 sortTitle: nil, overview: nil, year: nil, runtime: nil, parentRef: nil,
                                 grandparentRef: nil, episodeNumber: nil, seasonNumber: nil, childProgress: nil,
                                 userState: base.userState, artwork: base.artwork,
                                 parentArtwork: nil, grandparentArtwork: nil)
            return CachedHomeHub(id: id, title: id, isContinueWatching: false, hubKey: nil,
                                 hubIdentifier: id, totalSize: nil, items: [item])
        }
        let rail = PlexHomeViewController.homeRail(
            plex: [], otherServers: [],
            personal: [personal("emby", providerID: "emby:srv"), personal("jf", providerID: "jellyfin:srv"),
                       personal("plex", providerID: "plex:angel")])
        XCTAssertEqual(rail.map(\.kind), [.emby, .jellyfin, .plex])
    }

    func test_homeRail_jellyfinOnly() {
        let rail = PlexHomeViewController.homeRail(plex: [], otherServers: [row("jf-cw", cw: true), row("jf-movies")])
        XCTAssertEqual(rail.map(\.row.id), ["jf-cw", "jf-movies"])
    }

    func test_providerTileMenu_playVersion_onlyWithTwoVersions() {
        func titles(_ json: String) -> [String] {
            let item = JellyfinMediaMapper.item(JellyfinFixtures.decode(json), providerID: "jellyfin:srv",
                                                baseURL: JellyfinFixtures.baseURL)
            return menu(item).flatMap { $0 }.map(\.title)
        }
        XCTAssertTrue(titles(#"{"Id":"m1","Name":"Heat","Type":"Movie","MediaSourceCount":2}"#)
            .contains("Play Version"))
        XCTAssertFalse(titles(#"{"Id":"m1","Name":"Heat","Type":"Movie","MediaSourceCount":1}"#)
            .contains("Play Version"))
    }

    func test_sourceBadge_onlyWhileBothServersAreSignedIn() {
        let jellyfin = MediaItemRef(providerID: "jellyfin:srv", itemID: "1")
        XCTAssertEqual(PlexHomeViewController.sourceBadge(for: jellyfin, labelsServers: true), "Jellyfin")
        // The host app's own Plex sign-in, if the simulator has one, names the Plex server.
        let plexName = MediaProviderRegistry.shared.plexProvider?.displayName ?? "Plex"
        XCTAssertEqual(PlexHomeViewController.sourceBadge(for: MediaItemRef(providerID: "plex:abc", itemID: "1"),
                                                          labelsServers: true), plexName)
        XCTAssertNil(PlexHomeViewController.sourceBadge(for: jellyfin, labelsServers: false))
    }

    func test_sourceBadge_namesTheRegisteredServer() {
        let provider = StubMediaProvider(id: "jellyfin:named", kind: .jellyfin)
        MediaProviderRegistry.shared.register(provider)
        defer { MediaProviderRegistry.shared.unregister(providerID: provider.id) }
        let ref = MediaItemRef(providerID: provider.id, itemID: "1")
        XCTAssertEqual(PlexHomeViewController.sourceBadge(for: ref, labelsServers: true), "Stub")
        XCTAssertEqual(PlexHomeViewController.serverName(providerID: nil, kind: .jellyfin), "Stub")
    }

    /// Without an id, a kind with several servers must not name an arbitrary one.
    func test_serverName_withoutAnID_doesNotPickBlindlyAmongSeveral() {
        let registry = MediaProviderRegistry.shared
        let first = StubMediaProvider(id: "jellyfin:one", kind: .jellyfin)
        let second = StubMediaProvider(id: "jellyfin:two", kind: .jellyfin)
        registry.register(first)
        registry.register(second)
        defer { registry.unregister(providerID: first.id); registry.unregister(providerID: second.id) }

        XCTAssertEqual(PlexHomeViewController.serverName(providerID: nil, kind: .jellyfin), "Jellyfin")
        XCTAssertEqual(PlexHomeViewController.serverName(providerID: "jellyfin:two", kind: .jellyfin), "Stub (Jellyfin)",
                       "two servers with one name say their type")
        XCTAssertEqual(PlexHomeViewController.serverName(providerID: "jellyfin:missing", kind: .jellyfin), "Jellyfin",
                       "a server no longer registered is not swapped for another of its kind")
    }

    // MARK: - Settings server headers

    func test_serverRunHeaders_suffixOnlyWhenNamesMatch() {
        XCTAssertEqual(SettingsContent.serverRunHeaders([("Media", .plex), ("Media", .jellyfin)]),
                       ["Media (Plex)", "Media (Jellyfin)"])
        XCTAssertEqual(SettingsContent.serverRunHeaders([("Den", .plex), ("Office", .plex), ("Attic", .jellyfin)]),
                       ["Den", "Office", "Attic"])
    }

    func test_sourceBadgeView_hidesWithoutText() {
        let badge = SourceBadgeView(style: .inline)
        XCTAssertTrue(badge.isHidden)
        badge.text = "Jellyfin"
        XCTAssertFalse(badge.isHidden)
        XCTAssertEqual(badge.accessibilityLabel, "Jellyfin")
        badge.text = nil
        XCTAssertTrue(badge.isHidden)
    }

    func test_hubHeader_showsAndClearsTheBadge() {
        let header = HubHeaderView(frame: CGRect(x: 0, y: 0, width: 800, height: 60))
        header.configure(title: "Continue Watching", style: .swiftUIInfiniteRow, sourceBadge: "Plex")
        XCTAssertEqual(header.sourceBadgeText, "Plex")
        header.configure(title: "Recently Added", style: .swiftUIInfiniteRow, sourceBadge: nil)
        XCTAssertNil(header.sourceBadgeText, "a reused header must not keep the last row's badge")
    }

    // MARK: - Search

    func test_interleave_alternatesInEachServersOrder() {
        let plex = ["p1", "p2", "p3"].map { JellyfinFixtures.mediaItem($0, providerID: "plex:a") }
        let jellyfin = ["j1"].map { JellyfinFixtures.mediaItem($0) }
        XCTAssertEqual(PlexHomeViewController.interleave(plex, jellyfin).map(\.ref.itemID), ["p1", "j1", "p2", "p3"])
        XCTAssertEqual(PlexHomeViewController.interleave([], jellyfin).map(\.ref.itemID), ["j1"])
    }

    func test_searchError_onlyWhenNothingCameBack() {
        let down: Result<Bool, Error> = .failure(URLError(.timedOut))
        let found: Result<Bool, Error> = .success(true)
        let none: Result<Bool, Error> = .success(false)
        XCTAssertNil(PlexHomeViewController.searchErrorMessage(plex: down, otherServers: found),
                     "one server down must not hide the other's results")
        XCTAssertNotNil(PlexHomeViewController.searchErrorMessage(plex: down, otherServers: none),
                        "'No results' would be a lie while a server is down")
        XCTAssertNil(PlexHomeViewController.searchErrorMessage(plex: .success(false), otherServers: none))
    }

    // MARK: - Home hero

    func test_homeHeroSource() {
        XCTAssertEqual(PlexHomeViewController.homeHeroSource(plexSignedIn: true, otherServersSignedIn: false), .plex)
        XCTAssertEqual(PlexHomeViewController.homeHeroSource(plexSignedIn: false, otherServersSignedIn: true), .otherServers)
        XCTAssertEqual(PlexHomeViewController.homeHeroSource(plexSignedIn: true, otherServersSignedIn: true), .both)
        XCTAssertEqual(PlexHomeViewController.homeHeroSource(plexSignedIn: false, otherServersSignedIn: false), .none)
    }

    func test_mixedHeroItems_alternatesAndCaps() {
        let plex = (1...6).map { JellyfinFixtures.mediaItem("p\($0)", providerID: "plex:a") }
        let jellyfin = (1...6).map { JellyfinFixtures.mediaItem("j\($0)") }
        let mixed = PlexHomeViewController.mixedHeroItems(plex: plex, otherServers: jellyfin, cap: 10)
        XCTAssertEqual(mixed.prefix(4).map(\.ref.itemID), ["p1", "j1", "p2", "j2"])
        XCTAssertEqual(mixed.count, 10)
        XCTAssertEqual(PlexHomeViewController.mixedHeroItems(plex: [], otherServers: jellyfin, cap: 10).map(\.ref.itemID),
                       jellyfin.map(\.ref.itemID))
    }
}
