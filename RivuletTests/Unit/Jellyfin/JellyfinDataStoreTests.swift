// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import XCTest
@testable import Rivulet

@MainActor
final class JellyfinDataStoreTests: XCTestCase {
    private let jellyfin = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
    private let settings = LibrarySettingsManager.shared
    private var savedOrder: [String] = []
    private var savedHidden: Set<String> = []
    private var savedAccount: Data?

    override func setUp() async throws {
        try await super.setUp()
        savedOrder = settings.libraryOrder
        savedHidden = settings.hiddenLibraryKeys
        savedAccount = UserDefaults.standard.data(forKey: JellyfinSession.accountKey)
    }

    override func tearDown() async throws {
        settings.libraryOrder = savedOrder
        settings.hiddenLibraryKeys = savedHidden
        if let savedAccount {
            UserDefaults.standard.set(savedAccount, forKey: JellyfinSession.accountKey)
        } else {
            UserDefaults.standard.removeObject(forKey: JellyfinSession.accountKey)
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

    func test_load_keepsVideoLibrariesOnly() async {
        jellyfin.libraryList = [library("m", .movies), library("t", .shows), library("mu", .music),
                                library("p", .photos), library("x", .mixed), library("l", .liveTV)]
        let store = JellyfinDataStore(observesRefresh: false)

        await store.load(from: jellyfin)

        XCTAssertEqual(store.libraries.map(\.id), ["m", "t", "x"])
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
        let store = JellyfinDataStore(observesRefresh: false)

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
        let store = JellyfinDataStore(observesRefresh: false)
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
        let store = JellyfinDataStore(observesRefresh: false)
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
        let store = JellyfinDataStore(observesRefresh: false)
        await store.load(from: jellyfin)

        jellyfin.hubsError = URLError(.timedOut)
        await store.load(from: jellyfin)

        XCTAssertEqual(store.homeRows.map(\.id), ["jellyfin:srv|m.recentlyAdded"])

        jellyfin.hubsError = nil
        jellyfin.hubsByLibrary = ["m": []]
        await store.load(from: jellyfin)
        XCTAssertEqual(store.homeRows.map(\.id), [], "a library with nothing new drops its row")
    }

    func test_reload_withoutAccount_clearsEverything() async {
        UserDefaults.standard.removeObject(forKey: JellyfinSession.accountKey)
        jellyfin.libraryList = [library("m", .movies)]
        jellyfin.hubsByLibrary = ["m": [recentlyAdded("m", "b")]]
        let store = JellyfinDataStore(observesRefresh: false)
        await store.load(from: jellyfin)
        XCTAssertFalse(store.homeRows.isEmpty)

        store.reload()

        XCTAssertTrue(store.libraries.isEmpty)
        XCTAssertTrue(store.homeRows.isEmpty)
        XCTAssertFalse(store.isLoading)
    }

    func test_reload_withoutAccount_publishesNothingWhenAlreadyEmpty() {
        UserDefaults.standard.removeObject(forKey: JellyfinSession.accountKey)
        let store = JellyfinDataStore(observesRefresh: false)
        var publishes = 0
        let sub = store.objectWillChange.sink { publishes += 1 }
        store.reload()
        store.reload()
        sub.cancel()
        XCTAssertEqual(publishes, 0, "a Plex-only user's every foreground would redraw Home")
    }

    func test_visibleHomeRows_followRowAndLibraryVisibility() async {
        jellyfin.libraryList = [library("m", .movies), library("t", .shows)]
        jellyfin.continueWatchingItems = [JellyfinFixtures.mediaItem("a")]
        jellyfin.hubsByLibrary = ["m": [recentlyAdded("m", "b")], "t": [recentlyAdded("t", "c")]]
        let store = JellyfinDataStore(observesRefresh: false)
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
        let store = JellyfinDataStore(observesRefresh: false)
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

    func test_labelsServers_falseWithoutAJellyfinAccount() {
        XCTAssertFalse(JellyfinDataStore(observesRefresh: false).labelsServers)
    }

    func test_displayName() {
        XCTAssertEqual(MediaProviderKind.plex.displayName, "Plex")
        XCTAssertEqual(MediaProviderKind.jellyfin.displayName, "Jellyfin")
    }
}
