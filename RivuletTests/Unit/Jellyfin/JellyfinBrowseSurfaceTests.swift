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

    // MARK: - Plex paths

    func test_isJellyfin() {
        XCTAssertTrue(MediaItemRef(providerID: "jellyfin:srv", itemID: "x").isJellyfin)
        XCTAssertFalse(MediaItemRef(providerID: "plex:abc", itemID: "1").isJellyfin)
        XCTAssertFalse(MediaItemRef(providerID: "tmdb", itemID: "1").isJellyfin)
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

    func test_providerSortOptions_matchPlexMinusResolution() {
        XCTAssertEqual(PlexHomeViewController.providerSortOptions(for: .movies),
                       LibrarySortOption.options(for: "movie").filter { $0 != .resolutionDesc && $0 != .resolutionAsc })
        XCTAssertEqual(PlexHomeViewController.providerSortOptions(for: .shows),
                       LibrarySortOption.options(for: "show"))
        XCTAssertEqual(PlexHomeViewController.providerSortOptions(for: .mixed),
                       LibrarySortOption.options(for: nil))
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

    // MARK: - Home

    private func row(_ id: String, cw: Bool = false, pin: Bool = false) -> CachedHomeHub {
        CachedHomeHub(id: id, title: id, isContinueWatching: cw, hubKey: nil,
                      hubIdentifier: pin ? "rivulet.pin.\(id)" : id, totalSize: nil, items: [])
    }

    func test_homeRail_pairsContinueWatching_thenEachServersLibraryRows_pinsInPlace() {
        let rail = PlexHomeViewController.homeRail(
            plex: [row("plex-cw", cw: true), row("plex-movies"), row("plex-tv"), row("pin", pin: true)],
            jellyfin: [row("jf-cw", cw: true), row("jf-movies")])

        XCTAssertEqual(rail.map(\.row.id), ["plex-cw", "jf-cw", "plex-movies", "plex-tv", "pin", "jf-movies"])
        XCTAssertEqual(rail.map(\.kind), [.plex, .jellyfin, .plex, .plex, .plex, .jellyfin])
    }

    func test_homeRail_plexOnly_keepsEachLibrarysPinsAfterItsRows() {
        let plex = [row("plex-cw", cw: true), row("plex-movies"), row("pin", pin: true), row("plex-tv")]
        let rail = PlexHomeViewController.homeRail(plex: plex, jellyfin: [])
        XCTAssertEqual(rail.map(\.row.id), ["plex-cw", "plex-movies", "pin", "plex-tv"])
    }

    func test_homeRail_jellyfinOnly() {
        let rail = PlexHomeViewController.homeRail(plex: [], jellyfin: [row("jf-cw", cw: true), row("jf-movies")])
        XCTAssertEqual(rail.map(\.row.id), ["jf-cw", "jf-movies"])
    }

    func test_providerTileMenu_playVersion_onlyWithTwoVersions() {
        func titles(_ json: String) -> [String] {
            let item = JellyfinMediaMapper.item(JellyfinFixtures.decode(json), providerID: "jellyfin:srv",
                                                baseURL: JellyfinFixtures.baseURL)
            return menu(item).flatMap { $0 }.map(\.title)
        }
        XCTAssertTrue(titles(#"{"Id":"m1","Name":"Heat","Type":"Movie","MediaSourceCount":2}"#)
            .contains("Play Version…"))
        XCTAssertFalse(titles(#"{"Id":"m1","Name":"Heat","Type":"Movie","MediaSourceCount":1}"#)
            .contains("Play Version…"))
    }

    func test_sourceBadge_onlyWhileBothServersAreSignedIn() {
        let jellyfin = MediaItemRef(providerID: "jellyfin:srv", itemID: "1")
        XCTAssertEqual(PlexHomeViewController.sourceBadge(for: jellyfin, labelsServers: true), "Jellyfin")
        XCTAssertEqual(PlexHomeViewController.sourceBadge(for: MediaItemRef(providerID: "plex:abc", itemID: "1"),
                                                          labelsServers: true), "Plex")
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

    // MARK: - Settings server headers

    func test_serverRunHeaders_suffixOnlyWhenNamesMatch() {
        let same = SettingsContent.serverRunHeaders(plex: "Media", jellyfin: "Media")
        XCTAssertEqual(same.plex, "Media (Plex)")
        XCTAssertEqual(same.jellyfin, "Media (Jellyfin)")
        let different = SettingsContent.serverRunHeaders(plex: "Den", jellyfin: "Attic")
        XCTAssertEqual(different.plex, "Den")
        XCTAssertEqual(different.jellyfin, "Attic")
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
        let down: Result<[PlexMetadata], Error> = .failure(URLError(.timedOut))
        let found: Result<[MediaItem], Error> = .success([JellyfinFixtures.mediaItem("m1")])
        let none: Result<[MediaItem], Error> = .success([])
        XCTAssertNil(PlexHomeViewController.searchErrorMessage(plex: down, jellyfin: found),
                     "one server down must not hide the other's results")
        XCTAssertNotNil(PlexHomeViewController.searchErrorMessage(plex: down, jellyfin: none),
                        "'No results' would be a lie while a server is down")
        XCTAssertNil(PlexHomeViewController.searchErrorMessage(plex: .success([]), jellyfin: none))
    }

    // MARK: - Home hero

    func test_homeHeroSource() {
        XCTAssertEqual(PlexHomeViewController.homeHeroSource(plexSignedIn: true, jellyfinSignedIn: false), .plex)
        XCTAssertEqual(PlexHomeViewController.homeHeroSource(plexSignedIn: false, jellyfinSignedIn: true), .jellyfin)
        XCTAssertEqual(PlexHomeViewController.homeHeroSource(plexSignedIn: true, jellyfinSignedIn: true), .both)
        XCTAssertEqual(PlexHomeViewController.homeHeroSource(plexSignedIn: false, jellyfinSignedIn: false), .none)
    }

    func test_mixedHeroItems_alternatesAndCaps() {
        let plex = (1...6).map { JellyfinFixtures.mediaItem("p\($0)", providerID: "plex:a") }
        let jellyfin = (1...6).map { JellyfinFixtures.mediaItem("j\($0)") }
        let mixed = PlexHomeViewController.mixedHeroItems(plex: plex, jellyfin: jellyfin, cap: 10)
        XCTAssertEqual(mixed.prefix(4).map(\.ref.itemID), ["p1", "j1", "p2", "j2"])
        XCTAssertEqual(mixed.count, 10)
        XCTAssertEqual(PlexHomeViewController.mixedHeroItems(plex: [], jellyfin: jellyfin, cap: 10).map(\.ref.itemID),
                       jellyfin.map(\.ref.itemID))
    }
}
