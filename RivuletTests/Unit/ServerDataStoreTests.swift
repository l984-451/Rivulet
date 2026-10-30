// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import XCTest
@testable import Rivulet

@MainActor
final class ServerDataStoreTests: XCTestCase {
    private let jellyfin = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
    private let settings = LibrarySettingsManager.shared
    private var savedOrder: [String] = []
    private var savedHidden: Set<String> = []
    private var savedHiddenServers: Set<String> = []
    private var savedAccount: Data?
    private var savedSiloAccount: Data?

    override func setUp() async throws {
        try await super.setUp()
        savedOrder = settings.libraryOrder
        savedHidden = settings.hiddenLibraryKeys
        savedHiddenServers = settings.hiddenLibraryServerIDs
        savedAccount = UserDefaults.standard.data(forKey: JellyfinSession.accountKey)
        savedSiloAccount = UserDefaults.standard.data(forKey: SiloSession.accountKey)
        UserDefaults.standard.removeObject(forKey: JellyfinSession.accountKey)
        UserDefaults.standard.removeObject(forKey: SiloSession.accountKey)
    }

    override func tearDown() async throws {
        settings.libraryOrder = savedOrder
        settings.hiddenLibraryKeys = savedHidden
        settings.hiddenLibraryServerIDs = savedHiddenServers
        if let savedAccount {
            UserDefaults.standard.set(savedAccount, forKey: JellyfinSession.accountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: JellyfinSession.accountKey)
        }
        if let savedSiloAccount {
            UserDefaults.standard.set(savedSiloAccount, forKey: SiloSession.accountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SiloSession.accountKey)
        }
        try await super.tearDown()
    }

    private func library(_ id: String, _ kind: MediaLibrary.LibraryKind) -> MediaLibrary {
        MediaLibrary(id: id, providerID: "jellyfin:srv", title: id, kind: kind)
    }

    private func recentlyAdded(_ libraryID: String, _ itemID: String) -> MediaHub {
        MediaHub(id: "\(libraryID).recentlyAdded", providerID: "jellyfin:srv",
                 title: "Recently Added in \(libraryID)", style: .shelf,
                 items: [JellyfinFixtures.mediaItem(itemID)])
    }

    func test_load_keepsVideoPhotoAndMusicLibraries() async {
        jellyfin.libraryList = [library("m", .movies), library("t", .shows), library("mu", .music),
                                library("p", .photos), library("x", .mixed), library("l", .liveTV)]
        jellyfin.hubsByLibrary = ["p": [recentlyAdded("p", "z")], "mu": [recentlyAdded("mu", "y")]]
        let store = ServerDataStore(observesRefresh: false)

        await store.load(from: jellyfin)

        XCTAssertEqual(store.libraries.map(\.id), ["m", "t", "mu", "p", "x"])
        XCTAssertFalse(store.homeRows.contains { $0.id.hasSuffix("|p.recentlyAdded") },
                       "a photo library has no Home row")
        XCTAssertFalse(store.homeRows.contains { $0.id.hasSuffix("|mu.recentlyAdded") },
                       "a music library has no Home row")
    }

    func test_load_rows_continueWatchingThenEachLibrarysRecentlyAdded() async {
        jellyfin.libraryList = [library("m", .movies), library("t", .shows)]
        jellyfin.continueWatchingItems = [JellyfinFixtures.mediaItem("a")]
        jellyfin.hubsByLibrary = [
            "m": [MediaHub(id: "m.continueWatching", providerID: "jellyfin:srv", title: "Continue Watching",
                           style: .shelf, items: [JellyfinFixtures.mediaItem("a")]),
                  recentlyAdded("m", "b")],
            "t": [recentlyAdded("t", "c")]
        ]
        let store = ServerDataStore(observesRefresh: false)

        await store.load(from: jellyfin)

        XCTAssertEqual(store.homeRows.map(\.id),
                       ["jellyfin:srv|continueWatching", "jellyfin:srv|m.recentlyAdded", "jellyfin:srv|t.recentlyAdded"],
                       "Home takes each library's Recently Added; its library Continue Watching row is page-only")
        XCTAssertEqual(store.homeRows.map(\.hubIdentifier), store.homeRows.map(\.id))
        XCTAssertEqual(store.homeRows.map(\.isContinueWatching), [true, false, false])
        XCTAssertEqual(store.homeRows.map(\.title), ["Continue Watching", "Recently Added in m", "Recently Added in t"])
        XCTAssertTrue(store.homeRows.allSatisfy { $0.hubKey == nil }, "a hub key would turn on Plex row paging")
        XCTAssertFalse(store.isLoading)
    }

    func test_load_failure_keepsWhatWasThere() async {
        jellyfin.libraryList = [library("m", .movies)]
        let store = ServerDataStore(observesRefresh: false)
        await store.load(from: jellyfin)

        jellyfin.librariesError = URLError(.timedOut)
        await store.load(from: jellyfin)

        XCTAssertEqual(store.libraries.map(\.id), ["m"], "a server that drops off must not empty the sidebar")
        XCTAssertFalse(store.isLoading)
    }

    func test_load_continueWatchingFailure_keepsItsRow() async {
        jellyfin.libraryList = [library("m", .movies)]
        jellyfin.continueWatchingItems = [JellyfinFixtures.mediaItem("a")]
        jellyfin.hubsByLibrary = ["m": [recentlyAdded("m", "b")]]
        let store = ServerDataStore(observesRefresh: false)
        await store.load(from: jellyfin)

        jellyfin.continueWatchingError = URLError(.timedOut)
        await store.load(from: jellyfin)

        XCTAssertEqual(store.homeRows.map(\.id), ["jellyfin:srv|continueWatching", "jellyfin:srv|m.recentlyAdded"])
        jellyfin.continueWatchingError = nil
        jellyfin.continueWatchingItems = []
        await store.load(from: jellyfin)
        XCTAssertEqual(store.homeRows.map(\.id), ["jellyfin:srv|m.recentlyAdded"], "an empty answer still removes the row")
    }

    func test_load_hubsFailure_keepsThatLibrarysRow() async {
        jellyfin.libraryList = [library("m", .movies)]
        jellyfin.hubsByLibrary = ["m": [recentlyAdded("m", "b")]]
        let store = ServerDataStore(observesRefresh: false)
        await store.load(from: jellyfin)

        jellyfin.hubsError = URLError(.timedOut)
        await store.load(from: jellyfin)

        XCTAssertEqual(store.homeRows.map(\.id), ["jellyfin:srv|m.recentlyAdded"])

        jellyfin.hubsError = nil
        jellyfin.hubsByLibrary = ["m": []]
        await store.load(from: jellyfin)
        XCTAssertEqual(store.homeRows.map(\.id), [], "a library with nothing new drops its row")
    }

    func test_reload_withoutAccount_clearsEveryProvidersContentAndErrors() async {
        let store = ServerDataStore(observesRefresh: false)
        for kind in [MediaProviderKind.plex, .jellyfin, .silo] {
            let provider = ReloadTestProvider(kind: kind)
            await store.load(from: provider)
            provider.base.librariesError = URLError(.timedOut)
            await store.load(from: provider)
        }
        XCTAssertEqual(store.libraries.count, 3)
        XCTAssertEqual(store.homeRows.count, 3)
        XCTAssertEqual(store.errors.count, 3)
        var publishes = 0
        let sub = store.objectWillChange.sink { publishes += 1 }

        store.reload()

        XCTAssertTrue(store.sources.isEmpty)
        XCTAssertTrue(store.libraries.isEmpty)
        XCTAssertTrue(store.homeRows.isEmpty)
        XCTAssertTrue(store.errors.isEmpty)
        XCTAssertTrue(store.visibilityErrors.isEmpty)
        XCTAssertFalse(store.isLoading)
        XCTAssertGreaterThan(publishes, 0, "removing loaded content must notify its consumers")
        let afterRemoval = publishes
        store.reload()
        XCTAssertEqual(publishes, afterRemoval, "the cleared state is idempotent too")
        sub.cancel()
    }

    func test_reload_withoutAccount_publishesNothingWhenAlreadyEmpty() {
        UserDefaults.standard.removeObject(forKey: JellyfinSession.accountKey)
        let store = ServerDataStore(observesRefresh: false)
        var publishes = 0
        let sub = store.objectWillChange.sink { publishes += 1 }
        store.reload()
        store.reload()
        sub.cancel()
        XCTAssertEqual(publishes, 0, "a Plex-only user's every foreground would redraw Home")
    }

    func test_reload_withoutAccount_invalidatesInFlightLoadsWithoutPublishingTheirCompletion() async {
        for kind in [MediaProviderKind.plex, .jellyfin, .silo] {
            let store = ServerDataStore(observesRefresh: false)
            let provider = ReloadTestProvider(kind: kind)
            provider.holdLibraries = true
            let stale = Task { await store.load(from: provider) }
            await fulfillment(of: [provider.librariesEntered], timeout: 2)
            XCTAssertTrue(store.isLoading)

            store.reload()
            XCTAssertFalse(store.isLoading)
            var publishes = 0
            let sub = store.objectWillChange.sink { publishes += 1 }
            store.reload()
            XCTAssertEqual(publishes, 0)

            // A current-generation load finishes independently of the held, obsolete one.
            await store.load(from: ReloadTestProvider(kind: kind))
            XCTAssertFalse(store.isLoading, "obsolete work must not keep the current generation loading")
            let afterCurrentLoad = publishes
            provider.releaseLibraries()
            await stale.value
            XCTAssertEqual(publishes, afterCurrentLoad, "obsolete completion must not change content or loading")
            XCTAssertEqual(store.libraries.count, 1)
            XCTAssertEqual(store.homeRows.count, 1)
            XCTAssertTrue(store.errors.isEmpty)
            sub.cancel()
        }
    }

    func test_reload_withoutAccount_clearsSiloVisibilityState() async {
        let provider = ReloadTestProvider(kind: .silo)
        let hidden = MediaLibrary(id: "hidden", providerID: provider.id, title: "Hidden", kind: .movies)
        provider.base.libraryList.append(hidden)
        provider.itemsError = URLError(.timedOut)
        settings.hiddenLibraryKeys.insert(hidden.settingsKey)
        let store = ServerDataStore(observesRefresh: false)
        let failed = expectation(description: "Visibility error published")
        let errorSub = store.$visibilityErrors.filter { !$0.isEmpty }.sink { _ in failed.fulfill() }
        await store.load(from: provider)
        await fulfillment(of: [failed], timeout: 2)
        XCTAssertFalse(store.visibilityErrors.isEmpty)
        errorSub.cancel()
        var publishes = 0
        let sub = store.objectWillChange.sink { publishes += 1 }

        store.reload()

        XCTAssertTrue(store.visibilityErrors.isEmpty)
        XCTAssertFalse(store.isResolvingVisibility)
        XCTAssertTrue(store.visibleItems([JellyfinFixtures.mediaItem("movie", providerID: provider.id)]).isEmpty)
        XCTAssertGreaterThan(publishes, 0)
        let afterRemoval = publishes
        store.reload()
        XCTAssertEqual(publishes, afterRemoval)
        sub.cancel()
    }

    func test_reload_sameProviderWithNewAuthority_clearsPreviousUsersContentBeforeFetching() async throws {
        for kind in [MediaProviderKind.jellyfin, .silo] {
            let old = ReloadTestProvider(kind: kind, accountID: "old-user")
            let replacement = ReloadTestProvider(
                kind: kind, accountID: kind == .jellyfin ? "new-user" : "old-user",
                authorityRevision: kind == .silo ? 1 : 0
            )
            let registry = MediaProviderRegistry.shared
            let savedProvider = registry.provider(for: old.id)
            defer {
                registry.unregister(providerID: old.id)
                if let savedProvider { registry.register(savedProvider) }
            }
            if kind == .jellyfin {
                let account = JellyfinSession.Account(
                    serverURL: URL(string: "https://example.invalid")!, serverID: "reload",
                    serverName: "Reload", userID: "new-user", userName: "New User"
                )
                UserDefaults.standard.set(try JSONEncoder().encode(account), forKey: JellyfinSession.accountKey)
            } else {
                let account = SiloSession.Account(
                    serverURL: URL(string: "https://example.invalid")!, serverID: "reload",
                    serverName: "Reload", userID: "user", userName: "User",
                    profileID: "profile", profileName: "Profile",
                    credentialID: UUID()
                )
                UserDefaults.standard.set(try JSONEncoder().encode(account), forKey: SiloSession.accountKey)
            }
            let store = ServerDataStore(observesRefresh: false)
            await store.load(from: old)
            old.base.librariesError = URLError(.timedOut)
            await store.load(from: old)
            replacement.holdLibraries = true
            registry.register(replacement)
            let finished = expectation(description: "Replacement load finishes")
            let sub = store.$isLoading.dropFirst().filter { !$0 }.sink { _ in finished.fulfill() }

            store.reload()

            XCTAssertTrue(store.libraries.isEmpty, "same server identity does not authorize the previous user's libraries")
            XCTAssertTrue(store.homeRows.isEmpty)
            XCTAssertTrue(store.errors.isEmpty)
            XCTAssertTrue(store.isLoading)
            await fulfillment(of: [replacement.librariesEntered], timeout: 2)
            replacement.releaseLibraries()
            await fulfillment(of: [finished], timeout: 2)
            XCTAssertEqual(store.libraries.count, 1)
            XCTAssertEqual(store.homeRows.count, 1)
            XCTAssertFalse(store.isLoading)
            sub.cancel()
        }
    }

    func test_visibleHomeRows_followRowAndLibraryVisibility() async {
        jellyfin.libraryList = [library("m", .movies), library("t", .shows)]
        jellyfin.continueWatchingItems = [JellyfinFixtures.mediaItem("a")]
        jellyfin.hubsByLibrary = ["m": [recentlyAdded("m", "b")], "t": [recentlyAdded("t", "c")]]
        let store = ServerDataStore(observesRefresh: false)
        await store.load(from: jellyfin)
        let cw = "jellyfin:srv|continueWatching"
        HomeRowSettings.setHidden(true, for: cw)
        defer { HomeRowSettings.setHidden(false, for: cw) }
        settings.hiddenLibraryKeys.insert(library("t", .shows).settingsKey)

        XCTAssertEqual(store.visibleHomeRows.map(\.id), ["jellyfin:srv|m.recentlyAdded"])
        XCTAssertEqual(store.homeRowsInSidebarOrder.map(\.id), [cw, "jellyfin:srv|m.recentlyAdded"],
                       "Settings lists Home-hidden rows, never sidebar-hidden libraries' rows")
        XCTAssertEqual(store.homeRows.count, 3, "Settings lists hidden rows too, so they can come back")
    }

    func test_visibleLibraries_followSidebarOrderAndVisibility() async {
        jellyfin.libraryList = [library("m", .movies), library("t", .shows), library("x", .mixed)]
        let store = ServerDataStore(observesRefresh: false)
        await store.load(from: jellyfin)
        settings.libraryOrder = [library("x", .mixed).settingsKey, library("m", .movies).settingsKey]
        settings.hiddenLibraryKeys.insert(library("t", .shows).settingsKey)

        XCTAssertEqual(store.visibleLibraries.map(\.id), ["x", "m"])
    }

    func test_sort_keepsHiddenLibrariesInPlace() {
        let libs = [library("m", .movies), library("t", .shows), library("x", .mixed)]
        settings.libraryOrder = [library("x", .mixed).settingsKey, library("t", .shows).settingsKey, library("m", .movies).settingsKey]
        settings.hiddenLibraryKeys.insert(library("t", .shows).settingsKey)

        XCTAssertEqual(settings.sort(libs).map(\.id), ["x", "t", "m"])
        XCTAssertEqual(settings.filterAndSort(libs).map(\.id), ["x", "m"])
    }

    func test_plexSync_keepsJellyfinKeys() {
        let jellyfinKey = library("m", .movies).settingsKey
        settings.libraryOrder = ["1", jellyfinKey]
        settings.hiddenLibraryKeys = [jellyfinKey, "gone"]

        settings.syncOrderWithLibraries([])

        XCTAssertEqual(settings.libraryOrder, [jellyfinKey], "a Plex refresh must not delete Jellyfin settings")
        XCTAssertEqual(settings.hiddenLibraryKeys, [jellyfinKey])
    }

    func test_moveLibrary_staysInsideItsOwnRun() {
        let a = library("a", .movies).settingsKey, b = library("b", .shows).settingsKey
        settings.libraryOrder = ["1", "2", a, b]

        settings.moveLibrary(key: b, up: true, among: [a, b])
        XCTAssertEqual(Array(settings.libraryOrder.prefix(2)), [b, a])
        XCTAssertEqual(Set(settings.libraryOrder), ["1", "2", a, b], "nothing dropped")

        let before = settings.libraryOrder
        settings.moveLibrary(key: b, up: true, among: [b, a])
        XCTAssertEqual(settings.libraryOrder, before, "the first of a run cannot move up into another server's run")
    }

    /// Settings re-reads the order per move (its page is not rebuilt between
    /// moves); a stale order would swap C against A,B,C twice and save A,C,B.
    func test_moveLibrary_twice_withOrderReReadEachMove() {
        let libs = [library("a", .movies), library("b", .shows), library("c", .mixed)]
        let (a, b, c) = (libs[0].settingsKey, libs[1].settingsKey, libs[2].settingsKey)
        settings.libraryOrder = [a, b, c]

        settings.moveLibrary(key: c, up: true, among: settings.sort(libs).map(\.settingsKey))
        settings.moveLibrary(key: c, up: true, among: settings.sort(libs).map(\.settingsKey))

        XCTAssertEqual(settings.sort(libs).map(\.id), ["c", "a", "b"])
    }

    func test_serverVisibility_filtersHomeAndNewLibraries_withoutLosingChoicesOrOtherSources() async {
        let native = ReloadTestProvider(kind: .silo)
        jellyfin.libraryList = [library("m", .movies)]
        jellyfin.continueWatchingItems = [JellyfinFixtures.mediaItem("a")]
        jellyfin.hubsByLibrary = ["m": [recentlyAdded("m", "b")]]
        let store = ServerDataStore(observesRefresh: false)
        await store.load(from: native)
        await store.load(from: jellyfin)
        XCTAssertEqual(store.visibleHomeRows.count, 3)

        settings.setServerLibrariesVisible(false, providerID: native.id)
        native.base.libraryList.append(MediaLibrary(id: "new", providerID: native.id, title: "New", kind: .shows))
        await store.load(from: native)
        XCTAssertEqual(store.visibleLibraries.map(\.providerID), [jellyfin.id])
        XCTAssertEqual(Set(store.visibleHomeRows.compactMap(\.nativeProviderID)), [jellyfin.id])
        XCTAssertEqual(store.homeRows.count, 3, "hidden content stays loaded so showing it again does not require signing in")
        XCTAssertTrue(store.visibleItems([JellyfinFixtures.mediaItem("recommendation", providerID: native.id)]).isEmpty,
                      "global native cards without a library ID must not bypass a hidden server")

        settings.setServerLibrariesVisible(true, providerID: native.id)
        XCTAssertEqual(Set(store.visibleLibraries.map(\.settingsKey)),
                       ["\(native.id)/movies", "\(native.id)/new", "\(jellyfin.id)/m"])
        XCTAssertEqual(store.visibleHomeRows.count, 3)
        settings.setServerLibrariesVisible(false, providerID: jellyfin.id)
        XCTAssertEqual(Set(store.visibleHomeRows.compactMap(\.nativeProviderID)), [native.id],
                       "Jellyfin's global Continue Watching is hidden along with its library rows")
    }

    func test_labelsAndBadges_followVisibleLibrarySources_immediatelyAcrossHideAndShow() async {
        let primary = PlexDataStore.shared
        let previousLibraries = primary.libraries
        primary.libraries = []
        defer { primary.libraries = previousLibraries }
        let native = ReloadTestProvider(kind: .silo)
        jellyfin.libraryList = [library("m", .movies)]
        let store = ServerDataStore(observesRefresh: false)
        await store.load(from: native)
        await store.load(from: jellyfin)
        let ref = MediaItemRef(providerID: native.id, itemID: "movie")
        XCTAssertTrue(store.labelsServers)
        XCTAssertNotNil(PlexHomeViewController.sourceBadge(for: ref, labelsServers: store.labelsServers))

        settings.setServerLibrariesVisible(false, providerID: jellyfin.id)
        XCTAssertEqual(store.visibleLibraries.count, 1)
        XCTAssertFalse(store.labelsServers)
        XCTAssertNil(PlexHomeViewController.sourceBadge(for: ref, labelsServers: store.labelsServers))
        XCTAssertEqual(store.visibleHomeRows.count, 1, "Silo's native section remains without a redundant source label")

        settings.setServerLibrariesVisible(true, providerID: jellyfin.id)
        XCTAssertTrue(store.labelsServers)
        settings.hideLibrary("\(jellyfin.id)/m")
        XCTAssertFalse(store.labelsServers, "hiding the last individual library removes its source too")
        settings.showLibrary("\(jellyfin.id)/m")
        XCTAssertTrue(store.labelsServers)
    }

    func test_signedInServerPages_toggleTheirOwnLibraries_withoutSigningOut() async throws {
        let native = ReloadTestProvider(kind: .silo)
        jellyfin.libraryList = [library("m", .movies)]
        let jfAccount = JellyfinSession.Account(
            serverURL: URL(string: "https://jellyfin.invalid")!, serverID: "srv", serverName: "Films",
            userID: "user", userName: "User")
        let siloAccount = SiloSession.Account(
            serverURL: URL(string: "https://silo.invalid")!, serverID: "reload", serverName: "Movies",
            userID: "user", userName: "User", profileID: "profile", profileName: "Profile", credentialID: UUID())
        let jfData = try JSONEncoder().encode(jfAccount)
        let siloData = try JSONEncoder().encode(siloAccount)
        UserDefaults.standard.set(jfData, forKey: JellyfinSession.accountKey)
        UserDefaults.standard.set(siloData, forKey: SiloSession.accountKey)
        let store = ServerDataStore(observesRefresh: false)
        await store.load(from: native)
        await store.load(from: jellyfin)

        for (rows, providerID, otherID) in [
            (SettingsContent.jellyfin, jellyfin.id, native.id),
            (SettingsContent.silo, native.id, jellyfin.id)
        ] {
            let row = try XCTUnwrap(rows.first { $0.title == "Show Libraries" })
            guard case .toggle(let get, let set, _) = row.kind else {
                return XCTFail("The actual signed-in server page must have a library toggle")
            }
            XCTAssertTrue(get())
            set(false)
            XCTAssertFalse(get())
            XCTAssertFalse(store.visibleLibraries.contains { $0.providerID == providerID })
            XCTAssertTrue(store.visibleLibraries.contains { $0.providerID == otherID })
            set(true)
            XCTAssertTrue(get())
            XCTAssertTrue(store.visibleLibraries.contains { $0.providerID == providerID })
        }
        XCTAssertEqual(UserDefaults.standard.data(forKey: JellyfinSession.accountKey), jfData)
        XCTAssertEqual(UserDefaults.standard.data(forKey: SiloSession.accountKey), siloData)
    }

    func test_displayName() {
        XCTAssertEqual(MediaProviderKind.plex.displayName, "Plex")
        XCTAssertEqual(MediaProviderKind.jellyfin.displayName, "Jellyfin")
    }

    // MARK: - Several servers (#87)

    func test_twoServers_keepTheirOwnRows_evenWhenLibraryIDsCollide() async {
        let office = StubMediaProvider(id: "plex:office", kind: .plex)
        office.libraryList = [MediaLibrary(id: "1", providerID: "plex:office", title: "Movies", kind: .movies),
                              MediaLibrary(id: "2", providerID: "plex:office", title: "Music", kind: .music)]
        office.hubsByLibrary = ["1": [MediaHub(id: "1.recentlyAdded", providerID: "plex:office", title: "Recently Added in Movies",
                                               style: .shelf, items: [JellyfinFixtures.mediaItem("o", providerID: "plex:office")])]]
        jellyfin.libraryList = [MediaLibrary(id: "1", providerID: "jellyfin:srv", title: "Films", kind: .movies)]
        jellyfin.hubsByLibrary = ["1": [MediaHub(id: "1.recentlyAdded", providerID: "jellyfin:srv", title: "Recently Added in Films",
                                                 style: .shelf, items: [JellyfinFixtures.mediaItem("j")])]]
        let store = ServerDataStore(observesRefresh: false)

        await store.load(from: jellyfin)
        await store.load(from: office)

        XCTAssertEqual(store.libraries.map(\.settingsKey), ["jellyfin:srv/1", "plex:office/1"],
                       "an extra Plex server's music stays on the selected server")
        XCTAssertEqual(store.homeRowsInSidebarOrder.map(\.id),
                       ["jellyfin:srv|1.recentlyAdded", "plex:office|1.recentlyAdded"],
                       "each server's row matches its own library, not the other's with the same id")
    }

    func test_oneServerFailing_keepsTheOthersRows() async {
        let office = StubMediaProvider(id: "plex:office", kind: .plex)
        office.libraryList = [MediaLibrary(id: "1", providerID: "plex:office", title: "Movies", kind: .movies)]
        jellyfin.libraryList = [library("m", .movies)]
        let store = ServerDataStore(observesRefresh: false)
        await store.load(from: jellyfin)
        await store.load(from: office)

        office.librariesError = URLError(.timedOut)
        await store.load(from: office)

        XCTAssertEqual(store.libraries.map(\.settingsKey), ["jellyfin:srv/m", "plex:office/1"])
    }
}

@MainActor
private final class ReloadTestProvider: MediaProvider {
    nonisolated let base: StubMediaProvider
    nonisolated let accountID: String?
    nonisolated let authorityRevision: UInt64
    nonisolated var id: String { base.id }
    nonisolated var kind: MediaProviderKind { base.kind }
    nonisolated var displayName: String { base.displayName }
    nonisolated var connectionState: ConnectionState { base.connectionState }
    nonisolated var supportsWatchlist: Bool { base.supportsWatchlist }
    let librariesEntered = XCTestExpectation(description: "Libraries requested")
    var holdLibraries = false
    var itemsError: Error?
    private var librariesContinuation: CheckedContinuation<Void, Never>?

    init(kind: MediaProviderKind, accountID: String? = nil, authorityRevision: UInt64 = 0) {
        let id = kind == .silo ? "silo:reload:profile" : "\(kind.rawValue):reload"
        base = StubMediaProvider(id: id, kind: kind)
        self.accountID = accountID
        self.authorityRevision = authorityRevision
        base.libraryList = [MediaLibrary(id: "movies", providerID: id, title: "Movies", kind: .movies)]
        base.hubsByLibrary = ["movies": [MediaHub(
            id: "movies.recentlyAdded", providerID: id, title: "Recent", style: .shelf,
            items: [JellyfinFixtures.mediaItem("movie", providerID: id)]
        )]]
    }

    func libraries() async throws -> [MediaLibrary] {
        if holdLibraries {
            await withCheckedContinuation {
                librariesContinuation = $0
                librariesEntered.fulfill()
            }
        }
        return try await base.libraries()
    }
    func releaseLibraries() {
        librariesContinuation?.resume()
        librariesContinuation = nil
    }
    func hubs() async throws -> [MediaHub] { base.hubsByLibrary["movies"] ?? [] }
    func hubs(in library: MediaLibrary) async throws -> [MediaHub] { try await base.hubs(in: library) }
    func continueWatching(limit: Int) async throws -> [MediaItem] { try await base.continueWatching(limit: limit) }
    func recentlyAdded(limit: Int) async throws -> [MediaItem] { try await base.recentlyAdded(limit: limit) }
    func items(in library: MediaLibrary, sort: SortOption, page: Page) async throws -> PagedResult<MediaItem> {
        if let itemsError { throw itemsError }
        return try await base.items(in: library, sort: sort, page: page)
    }
    func children(of itemRef: MediaItemRef) async throws -> [MediaItem] { try await base.children(of: itemRef) }
    func search(_ query: String) async throws -> [MediaItem] { try await base.search(query) }
    func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent {
        try await base.related(for: ref, kind: kind)
    }
    func allEpisodes(of showRef: MediaItemRef) async throws -> [MediaItem] { try await base.allEpisodes(of: showRef) }
    func fullDetail(for itemRef: MediaItemRef) async throws -> MediaItemDetail { try await base.fullDetail(for: itemRef) }
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?) async throws -> StreamInfo {
        try await base.resolveStream(for: itemRef, sourceID: sourceID, maxBitrate: maxBitrate)
    }
    nonisolated func progressReporter(
        for itemRef: MediaItemRef, sourceID: String?, playSessionID: String?
    ) -> any Rivulet.ProgressReporter {
        base.progressReporter(for: itemRef, sourceID: sourceID, playSessionID: playSessionID)
    }
    func setSelectedAudioTrack(_ trackID: String, source sourceID: String, of itemRef: MediaItemRef) async throws {
        try await base.setSelectedAudioTrack(trackID, source: sourceID, of: itemRef)
    }
    func setSelectedSubtitleTrack(_ trackID: String?, source sourceID: String, of itemRef: MediaItemRef) async throws {
        try await base.setSelectedSubtitleTrack(trackID, source: sourceID, of: itemRef)
    }
    func markPlayed(_ itemRef: MediaItemRef) async throws { try await base.markPlayed(itemRef) }
    func markUnplayed(_ itemRef: MediaItemRef) async throws { try await base.markUnplayed(itemRef) }
    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws {
        try await base.updateProgress(itemRef, position: position)
    }
    func isOnWatchlist(_ ref: MediaItemRef) async -> Bool { await base.isOnWatchlist(ref) }
    func addToWatchlist(_ ref: MediaItemRef) async throws { try await base.addToWatchlist(ref) }
    func removeFromWatchlist(_ ref: MediaItemRef) async throws { try await base.removeFromWatchlist(ref) }
}
