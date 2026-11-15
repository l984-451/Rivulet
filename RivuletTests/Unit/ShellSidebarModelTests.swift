// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class ShellSidebarModelTests: XCTestCase {

    private func sections(_ servers: [(providerID: String, name: String, libraries: [MediaLibrary])]) -> [ShellSidebarSection] {
        ShellSidebarModel.sections(
            libraries: servers.flatMap { server in server.libraries.map { SidebarLibrary($0, serverName: server.name) } },
            liveTVSources: [], combineLiveTV: true,
            showDiscover: false, showWatchlist: false,
            profileName: "Bain")
    }

    func test_favorites_showWithAnyMediaServer_andLeadBesideTheWatchlist() {
        func tabs(showFavorites: Bool, hasServer: Bool) -> [SidebarTab] {
            ShellSidebarModel.sections(
                libraries: [], liveTVSources: [], combineLiveTV: true,
                showDiscover: false, showWatchlist: true, showFavorites: showFavorites,
                profileName: "Bain", hasMediaServer: hasServer)
                .flatMap(\.items).map(\.tab)
        }
        XCTAssertEqual(tabs(showFavorites: true, hasServer: true),
                       [.account, .search, .home, .watchlist, .favorites, .settings])
        XCTAssertFalse(tabs(showFavorites: false, hasServer: true).contains(.favorites))
        XCTAssertFalse(tabs(showFavorites: true, hasServer: false).contains(.favorites))
    }

    func test_favorites_areOffUnlessAskedFor() {
        let rows = ShellSidebarModel.arrangeableRows(
            libraries: [], liveTVSources: [], combineLiveTV: true, showDiscover: false, showWatchlist: false)
        XCTAssertFalse(rows.contains { $0.key == SidebarArrangement.favorites })
    }

    private func tabs(hasServer: Bool, liveTV: Bool, libraries: [PlexLibrary] = [],
                      playlistServers: [PlaylistServer] = []) -> [SidebarTab] {
        let source = LiveTVDataStore.LiveTVSourceInfo(
            id: "m3u", sourceType: .genericM3U, displayName: "IPTV", channelCount: 10, isConnected: true, lastSync: nil)
        return ShellSidebarModel.sections(
            libraries: libraries.map { SidebarLibrary(plex: $0, serverName: "Angel") },
            liveTVSources: liveTV ? [source] : [], combineLiveTV: true,
            showDiscover: true, showWatchlist: true,
            profileName: "Account", hasMediaServer: hasServer,
            playlistServers: playlistServers)
            .flatMap(\.items).map(\.tab)
    }

    func test_profileName_prefersPlexProfileThenPlexAccount() {
        XCTAssertEqual(ShellSidebarModel.profileName(plexProfile: "Kids", plexUser: "bain", otherServerUsers: ["jf"]), "Kids")
        XCTAssertEqual(ShellSidebarModel.profileName(plexProfile: nil, plexUser: "bain", otherServerUsers: ["jf"]), "bain")
    }

    func test_profileName_withoutPlex_namesTheOtherServersUser() {
        XCTAssertEqual(ShellSidebarModel.profileName(plexProfile: nil, plexUser: nil, otherServerUsers: [nil, "emby-user"]), "emby-user")
        XCTAssertEqual(ShellSidebarModel.profileName(plexProfile: nil, plexUser: nil, otherServerUsers: ["jf", "emby-user"]), "jf")
    }

    func test_profileName_skipsEmptyNames_andFallsBackToAccount() {
        XCTAssertEqual(ShellSidebarModel.profileName(plexProfile: "", plexUser: nil, otherServerUsers: ["", "emby-user"]), "emby-user")
        XCTAssertEqual(ShellSidebarModel.profileName(plexProfile: nil, plexUser: nil, otherServerUsers: [nil, nil]),
                       String(localized: "Account"))
    }

    private let movies = PlexLibrary(
        key: "1", type: "movie", title: "Movies", agent: nil, scanner: nil, language: nil, uuid: "u",
        updatedAt: nil, createdAt: nil, scannedAt: nil, Location: nil)

    private let primary = PlaylistServer(providerID: "plex:primary", name: "Angel", serverID: "")

    private func server(_ providerID: String, _ name: String) -> PlaylistServer {
        PlaylistServer(providerID: providerID, name: name, serverID: providerID)
    }

    /// The arrangeable sections alone: no profile, Search/Home or Settings.
    private func middle(_ libraries: [SidebarLibrary], playlistServers: [PlaylistServer] = []) -> [ShellSidebarSection] {
        Array(ShellSidebarModel.sections(libraries: libraries, liveTVSources: [], combineLiveTV: true,
                                         showDiscover: false, showWatchlist: false,
                                         // The libraries' order as the profile stored it.
                                         order: SidebarArrangement.seed(libraryOrder: libraries.map(\.key),
                                                                        discoverAbove: true, liveTVAbove: false),
                                         profileName: "Bain",
                                         playlistServers: playlistServers).dropFirst(2).dropLast())
    }

    /// The selected Plex server's Movies, then each other server's libraries, grouped.
    private func playlistSections(_ playlistServers: [PlaylistServer],
                                  _ servers: [(providerID: String, name: String, libraries: [MediaLibrary])]) -> [ShellSidebarSection] {
        middle([SidebarLibrary(plex: movies, serverName: "Angel")]
                + servers.flatMap { server in server.libraries.map { SidebarLibrary($0, serverName: server.name) } },
               playlistServers: playlistServers)
    }

    func test_liveTVOnly_hidesServerTabs_andHome() {
        XCTAssertEqual(tabs(hasServer: false, liveTV: true), [.account, .liveTV(sourceId: nil), .settings])
    }

    func test_nothingConnected_keepsHomeForTheWelcome() {
        XCTAssertEqual(tabs(hasServer: false, liveTV: false), [.account, .home, .settings])
    }

    func test_withServer_keepsEveryTab() {
        XCTAssertEqual(tabs(hasServer: true, liveTV: true, libraries: [movies], playlistServers: [primary]),
                       [.account, .search, .home, .discover, .watchlist, .library(key: "1"),
                        .playlists(providerID: "plex:primary"), .liveTV(sourceId: nil), .settings])
    }

    func test_playlistsRow_onlyForServersWithPlaylists() {
        let office = [MediaLibrary(id: "1", providerID: "plex:office", title: "Movies", kind: .movies)]
        let jf = [MediaLibrary(id: "lib-m", providerID: "jellyfin:srv", title: "Movies", kind: .movies)]

        let all = playlistSections([server("jellyfin:srv", "jellyfin-test")],
                                   [("plex:office", "Office", office), ("jellyfin:srv", "jellyfin-test", jf)])

        XCTAssertEqual(all.flatMap(\.items).filter { $0.title == "Playlists" }.map(\.tab),
                       [.playlists(providerID: "jellyfin:srv")])
        XCTAssertTrue(playlistSections([], [("plex:office", "Office", office)]).flatMap(\.items).allSatisfy { $0.title != "Playlists" })
    }

    func test_playlistsRow_isLastInItsServerSection() {
        let jf = [MediaLibrary(id: "lib-m", providerID: "jellyfin:srv", title: "Movies", kind: .movies),
                  MediaLibrary(id: "lib-t", providerID: "jellyfin:srv", title: "TV Shows", kind: .shows)]

        let section = playlistSections([server("jellyfin:srv", "jellyfin-test")], [("jellyfin:srv", "jellyfin-test", jf)])
            .first { $0.title == "jellyfin-test" }

        XCTAssertEqual(section?.items.map(\.title), ["Movies", "TV Shows", "Playlists"])
        XCTAssertEqual(section?.items.last?.icon, "list.bullet.rectangle")
    }

    func test_playlistsRow_survivesEveryLibraryHidden() {
        let all = playlistSections([server("jellyfin:srv", "jellyfin-test")], [("jellyfin:srv", "jellyfin-test", [])])

        XCTAssertEqual(all.first { $0.title == "jellyfin-test" }?.items.map(\.tab),
                       [.playlists(providerID: "jellyfin:srv")])
        let primaryOnly = middle([], playlistServers: [primary])
        XCTAssertEqual(primaryOnly.first { $0.title == "Angel" }?.items.map(\.tab),
                       [.playlists(providerID: "plex:primary")])
    }

    func test_playlistsRow_primaryPlexServer() {
        let section = playlistSections([primary], []).first { $0.title == "Angel" }

        XCTAssertEqual(section?.items.map(\.tab), [.library(key: "1"), .playlists(providerID: "plex:primary")])
    }

    func test_playlistsRow_mixedServers_joinsLibrariesWithABadge() {
        let mixed = middle(
            [SidebarLibrary(plex: movies, serverName: "Angel"), SidebarLibrary(testMovies, serverName: "Test"),
             SidebarLibrary(plex: angelTV, serverName: "Angel")],
            playlistServers: [primary])

        XCTAssertEqual(mixed.map(\.title), [nil])
        XCTAssertEqual(mixed.first?.items.last?.tab, .playlists(providerID: "plex:primary"))
        XCTAssertEqual(mixed.first?.items.last?.badge, "Angel")
    }

    func test_jellyfinLibraries_getAServerNamedSection_withProviderTabs() {
        let libs = [MediaLibrary(id: "lib-m", providerID: "jellyfin:srv", title: "Movies", kind: .movies),
                    MediaLibrary(id: "lib-t", providerID: "jellyfin:srv", title: "TV Shows", kind: .shows),
                    MediaLibrary(id: "lib-x", providerID: "jellyfin:srv", title: "Home Videos", kind: .mixed)]

        let jf = sections([("jellyfin:srv", "jellyfin-test", libs)]).first { $0.title == "jellyfin-test" }

        XCTAssertEqual(jf?.items.map(\.title), ["Movies", "TV Shows", "Home Videos"])
        XCTAssertEqual(jf?.items.map(\.icon), ["film.fill", "tv.fill", "folder.fill"])
        XCTAssertEqual(jf?.items.first?.tab, .providerLibrary(providerID: "jellyfin:srv", libraryID: "lib-m"))
    }

    func test_eachOtherServer_getsItsOwnSection_inOrder_andEmptyOnesAreDropped() {
        let office = [MediaLibrary(id: "1", providerID: "plex:office", title: "Movies", kind: .movies)]
        let jf = [MediaLibrary(id: "lib-m", providerID: "jellyfin:srv", title: "Movies", kind: .movies)]

        let titles = sections([("plex:office", "Office", office), ("plex:empty", "Empty", []), ("jellyfin:srv", "jellyfin-test", jf)]).compactMap(\.title)

        XCTAssertEqual(titles, ["Office", "jellyfin-test"])
    }

    // MARK: Library order across servers (#87)

    private let angelMovies = PlexLibrary(key: "1", type: "movie", title: "Movies", agent: nil, scanner: nil, language: nil,
                                        uuid: "u1", updatedAt: nil, createdAt: nil, scannedAt: nil, Location: nil)
    private let angelTV = PlexLibrary(key: "2", type: "show", title: "TV Shows", agent: nil, scanner: nil, language: nil,
                                        uuid: "u2", updatedAt: nil, createdAt: nil, scannedAt: nil, Location: nil)
    private let testMovies = MediaLibrary(id: "1", providerID: "plex:test", title: "Movies", kind: .movies)

    private func librarySections(_ libraries: [SidebarLibrary]) -> [ShellSidebarSection] {
        middle(libraries)
    }

    func test_groupedByServer_eachServerUnderItsName_noBadges() {
        let sections = librarySections([SidebarLibrary(plex: angelMovies, serverName: "Angel"),
                                        SidebarLibrary(plex: angelTV, serverName: "Angel"),
                                        SidebarLibrary(testMovies, serverName: "Rivulet Test Plex")])
        XCTAssertEqual(sections.map(\.title), ["Angel", "Rivulet Test Plex"])
        XCTAssertTrue(sections.flatMap(\.items).allSatisfy { $0.badge == nil })
    }

    func test_anotherServerFirst_stillGrouped_headsInThatOrder() {
        let sections = librarySections([SidebarLibrary(testMovies, serverName: "Rivulet Test Plex"),
                                        SidebarLibrary(plex: angelMovies, serverName: "Angel")])
        XCTAssertEqual(sections.map(\.title), ["Rivulet Test Plex", "Angel"])
    }

    func test_mixedServers_oneHeaderlessSection_eachRowBadged() {
        let sections = librarySections([SidebarLibrary(plex: angelMovies, serverName: "Angel"),
                                        SidebarLibrary(testMovies, serverName: "Rivulet Test Plex"),
                                        SidebarLibrary(plex: angelTV, serverName: "Angel")])
        XCTAssertEqual(sections.map(\.title), [nil])
        XCTAssertEqual(sections.first?.items.map(\.badge), ["Angel", "Rivulet Test Plex", "Angel"])
    }

    func test_profileHeader_isItsOwnFirstSection_withFirstNameAndAvatar() {
        let avatar = URL(string: "https://plex.tv/users/abc/avatar")
        let all = ShellSidebarModel.sections(
            libraries: [], liveTVSources: [], combineLiveTV: true,
            showDiscover: false, showWatchlist: false,
            profileName: "William Gurley", profileAvatar: avatar)

        XCTAssertEqual(all[0].items.map(\.tab), [.account])
        XCTAssertEqual(all[0].items.first?.title, "William")
        XCTAssertEqual(all[0].items.first?.avatarURL, avatar)
        XCTAssertEqual(all[1].items.map(\.tab), [.search, .home])
    }

    func test_profileHeader_canSwitchProfile_followsTheArgument() {
        func header(_ canSwitch: Bool) -> ShellSidebarItem? {
            ShellSidebarModel.sections(
                libraries: [], liveTVSources: [], combineLiveTV: true,
                showDiscover: false, showWatchlist: false,
                profileName: "Bain",
                canSwitchProfile: canSwitch)[0].items.first
        }
        XCTAssertEqual(header(true)?.canSwitchProfile, true)
        XCTAssertEqual(header(false)?.canSwitchProfile, false)
        XCTAssertEqual(sections([])[0].items.first?.canSwitchProfile, false)
    }

    func test_nowPlaying_joinsTheProfileSlot_withoutAddingARowOrASection() {
        func build(_ playing: SidebarNowPlaying?) -> [ShellSidebarSection] {
            ShellSidebarModel.sections(
                libraries: [], liveTVSources: [], combineLiveTV: true,
                showDiscover: false, showWatchlist: false,
                profileName: "Bain", nowPlaying: playing)
        }
        let track = SidebarNowPlaying(title: "Nightcall", artist: "Kavinsky", isPlaying: true)
        let with = build(track)
        let without = build(nil)

        XCTAssertEqual(with[0].items.map(\.tab), [.account, .nowPlaying])
        XCTAssertEqual(with[0].items[1].title, "Nightcall \u{00B7} Kavinsky")
        XCTAssertEqual(with[0].items[1].nowPlaying, track)
        XCTAssertEqual(Array(with.dropFirst()), Array(without.dropFirst()))
        XCTAssertEqual(without[0].items.map(\.tab), [.account])
    }

    func test_nowPlaying_lineWithoutArtist_isTheTitle() {
        XCTAssertEqual(SidebarNowPlaying(title: "Intro", artist: nil, isPlaying: false).line, "Intro")
        XCTAssertEqual(SidebarNowPlaying(title: "Intro", artist: "", isPlaying: false).line, "Intro")
    }

    func test_firstName() {
        XCTAssertEqual(ShellSidebarModel.firstName(of: "William Gurley"), "William")
        XCTAssertEqual(ShellSidebarModel.firstName(of: "  Mary  Ann\tSmith"), "Mary")
        XCTAssertEqual(ShellSidebarModel.firstName(of: "katmgurley"), "katmgurley")
        XCTAssertEqual(ShellSidebarModel.firstName(of: "l984_451"), "l984_451")
        XCTAssertEqual(ShellSidebarModel.firstName(of: "Account"), "Account")
        XCTAssertEqual(ShellSidebarModel.firstName(of: ""), "")
    }

    func test_noJellyfin_noJellyfinSection() {
        XCTAssertEqual(sections([]).map(\.title), [nil, nil, nil])
    }

    func test_jellyfinSectionSitsBeforeSettings() {
        let libs = [MediaLibrary(id: "lib-m", providerID: "jellyfin:srv", title: "Movies", kind: .movies)]
        XCTAssertEqual(sections([("jellyfin:srv", "jellyfin-test", libs)]).map(\.title),
                       [nil, nil, "jellyfin-test", nil])
    }

    func test_upwardRun_stopsAtHomeAndSearch_onlyWhenTheGestureAlreadyMoved() {
        func stops(_ from: SidebarTab, _ to: SidebarTab, moved: Bool, up: Bool = true) -> Bool {
            ShellSidebarModel.stopsUpwardRun(from: from, to: to, headingUp: up, gestureAlreadyMoved: moved)
        }
        XCTAssertTrue(stops(.home, .search, moved: true))
        XCTAssertTrue(stops(.search, .account, moved: true))
        XCTAssertFalse(stops(.home, .search, moved: false), "a fresh press always moves")
        XCTAssertFalse(stops(.discover, .home, moved: true), "the run reaches Home")
        XCTAssertFalse(stops(.home, .discover, moved: true, up: false), "Down never stops")
    }

    func test_gestureCounter_heldArrowIsOneGesture() {
        let press = NSObject(), next = NSObject()
        var counter = RemoteGestureCounter()
        counter.observe(arrowBegan: press, arrowFinished: false, touchBegan: false)
        counter.observe(arrowBegan: press, arrowFinished: false, touchBegan: false)
        XCTAssertEqual(counter.count, 1, "a repeated .began of the held press is the same gesture")
        counter.observe(arrowBegan: nil, arrowFinished: true, touchBegan: false)
        counter.observe(arrowBegan: press, arrowFinished: false, touchBegan: false)
        XCTAssertEqual(counter.count, 2, "a reused press object after release is a new gesture")
        counter.observe(arrowBegan: next, arrowFinished: false, touchBegan: false)
        counter.observe(arrowBegan: nil, arrowFinished: false, touchBegan: true)
        XCTAssertEqual(counter.count, 4)
    }
}
