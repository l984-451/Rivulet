// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomeFeedTests.swift
//  RivuletTests
//
//  The iOS Home feed: what a server's fetch keeps, how servers assemble, and the loader's
//  selected-first, keep-the-last-good-rows behavior.
//

import XCTest
@testable import Rivulet

/// Counts calls in flight and keeps the highest count seen.
private actor InFlightGauge {
    private(set) var peak = 0
    private var current = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}

final class HomeFeedTests: XCTestCase {
    private func item(_ id: String, provider: String = "plex:a") -> MediaItem {
        JellyfinFixtures.mediaItem(id, providerID: provider)
    }

    private func library(_ id: String, _ kind: MediaLibrary.LibraryKind = .movies, provider: String = "plex:a",
                         pinned: Bool = true) -> MediaLibrary {
        var library = MediaLibrary(id: id, providerID: provider, title: "Lib \(id)", kind: kind)
        library.isPinnedToHome = pinned
        return library
    }

    private func hub(_ id: String, provider: String = "plex:a", promoted: Bool = false, items: [String] = ["x"]) -> MediaHub {
        MediaHub(id: id, providerID: provider, title: id, style: .shelf,
                 items: items.map { item($0, provider: provider) }, pagingKey: "/hubs/\(id)", isPromoted: promoted)
    }

    // MARK: - libraryRows

    func test_libraryRows_keepsTheServersOrderAndDropsEmptyRows() async throws {
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jf.hubsByLibrary = ["m": [hub("m.recentlyAdded", provider: "jellyfin:s"), hub("m.empty", provider: "jellyfin:s", items: []),
                                  hub("m.continueWatching", provider: "jellyfin:s")]]
        let rows = try await HomeFeed.libraryRows(jf, library("m", provider: "jellyfin:s"))
        XCTAssertEqual(rows.map(\.id), ["m.recentlyAdded", "m.continueWatching"])
    }

    // MARK: - fetch

    func test_fetchSelected_keepsPromotedHubsOfPinnedLibrariesOnly() async throws {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.libraryList = [library("1"), library("2", pinned: false), library("3", .music), library("4", .photos)]
        plex.hubsByLibrary = [
            "1": [hub("movie.recent", promoted: true), hub("movie.genre", promoted: false),
                  hub("movie.inprogress", promoted: true), hub("movie.empty", promoted: true, items: [])],
            "2": [hub("unpinned.recent", promoted: true)]
        ]
        plex.continueWatchingItems = [item("cw")]

        let rows = try await HomeFeed.fetch(plex, role: .selected)

        XCTAssertEqual(rows.libraries.map(\.id), ["1", "2"], "video libraries only, pinned or not")
        XCTAssertEqual(rows.rowsByLibrary["1"]?.map(\.id), ["plex:a|movie.recent"],
                       "promoted, not Continue Watching, not empty; ids carry the server")
        XCTAssertNil(rows.rowsByLibrary["2"], "an unpinned library contributes no rows")
        XCTAssertEqual(rows.continueWatching?.map(\.ref.itemID), ["cw"])
        XCTAssertEqual(rows.rowsByLibrary["1"]?.first?.pagingKey, "/hubs/movie.recent", "See All still pages")
    }

    func test_fetchSecondary_isContinueWatchingAndRecentlyAddedPerLibrary() async throws {
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jf.libraryList = [library("m", provider: "jellyfin:s"), library("t", .shows, provider: "jellyfin:s"),
                          library("p", .photos, provider: "jellyfin:s")]
        jf.hubsByLibrary = [
            "m": [hub("m.continueWatching", provider: "jellyfin:s"), hub("m.recentlyAdded", provider: "jellyfin:s")],
            "t": [hub("t.recentlyAdded", provider: "jellyfin:s", items: [])]
        ]
        jf.continueWatchingItems = [item("a", provider: "jellyfin:s")]

        let rows = try await HomeFeed.fetch(jf, role: .secondary)

        XCTAssertEqual(rows.rowsByLibrary["m"]?.map(\.id), ["jellyfin:s|m.recentlyAdded"])
        XCTAssertEqual(rows.rowsByLibrary["t"]?.map(\.id), [], "an empty Recently Added is an answer, not a failure")
        XCTAssertNil(rows.rowsByLibrary["p"])
        XCTAssertEqual(rows.libraries.map(\.id), ["m", "t"])
    }

    func test_fetch_recordsFailuresAsMissingNotEmpty() async throws {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.libraryList = [library("1"), library("2")]
        plex.hubsByLibrary = ["2": [hub("two", promoted: true)]]
        plex.failingHubLibraries = ["1"]
        plex.continueWatchingError = MediaProviderError.unreachable

        let rows = try await HomeFeed.fetch(plex, role: .selected)

        XCTAssertNil(rows.continueWatching, "a failed Continue Watching is nil, not empty")
        XCTAssertNil(rows.rowsByLibrary["1"], "a failed library has no entry")
        XCTAssertEqual(rows.rowsByLibrary["2"]?.count, 1)
    }

    func test_fetch_capsLibraryRequestsInFlight() async throws {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.libraryList = (1...12).map { library("\($0)") }
        let gauge = InFlightGauge()
        plex.hubsGate = {
            await gauge.enter()
            try await Task.sleep(for: .milliseconds(20))
            await gauge.leave()
        }

        let rows = try await HomeFeed.fetch(plex, role: .selected)

        XCTAssertEqual(rows.rowsByLibrary.count, 12, "every library still answers")
        let peak = await gauge.peak
        XCTAssertEqual(peak, BoundedFanOut.libraryRequests, "never more library requests at once than the width")
    }

    func test_fetch_throwsWhenLibrariesFail() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.librariesError = MediaProviderError.unreachable
        do {
            _ = try await HomeFeed.fetch(plex, role: .selected)
            XCTFail("expected a throw")
        } catch {}
    }

    // MARK: - keeping

    func test_keeping_fillsOnlyWhatFailed() {
        let old = HomeFeed.ServerRows(libraries: [library("1"), library("2")], continueWatching: [item("old")],
                                      rowsByLibrary: ["1": [hub("old1")], "2": [hub("old2")]])
        let fresh = HomeFeed.ServerRows(libraries: [library("1"), library("2")], continueWatching: nil,
                                        rowsByLibrary: ["2": [hub("new2")]])

        let merged = fresh.keeping(old)

        XCTAssertEqual(merged.continueWatching?.map(\.ref.itemID), ["old"])
        XCTAssertEqual(merged.rowsByLibrary["1"]?.map(\.id), ["old1"], "the failed library keeps its last rows")
        XCTAssertEqual(merged.rowsByLibrary["2"]?.map(\.id), ["new2"], "an answered library takes the new rows")
    }

    func test_keeping_anEmptyAnswerReplacesTheOldRow() {
        let old = HomeFeed.ServerRows(libraries: [library("1")], continueWatching: [item("old")], rowsByLibrary: [:])
        let fresh = HomeFeed.ServerRows(libraries: [library("1")], continueWatching: [], rowsByLibrary: [:])
        XCTAssertEqual(fresh.keeping(old).continueWatching, [])
    }

    func test_keeping_dropsLibrariesTheServerNoLongerHas() {
        let old = HomeFeed.ServerRows(libraries: [library("gone")], continueWatching: nil, rowsByLibrary: ["gone": [hub("g")]])
        let fresh = HomeFeed.ServerRows(libraries: [library("1")], continueWatching: nil, rowsByLibrary: [:])
        XCTAssertNil(fresh.keeping(old).rowsByLibrary["gone"])
    }

    // MARK: - assemble

    func test_assemble_selectedRowsThenEachOtherServerInOrder() {
        let selected = HomeFeed.ServerRows(
            libraries: [library("1"), library("2")], continueWatching: [item("c1")],
            rowsByLibrary: ["1": [hub("a")], "2": [hub("b")]])
        let other = HomeFeed.ServerRows(
            libraries: [library("m", provider: "jellyfin:s")], continueWatching: [item("c2", provider: "jellyfin:s")],
            rowsByLibrary: ["m": [hub("r", provider: "jellyfin:s")]])
        let second = HomeFeed.ServerRows(libraries: [library("e", provider: "emby:e")], continueWatching: nil,
                                         rowsByLibrary: ["e": [hub("q", provider: "emby:e")]])

        let home = HomeFeed.assemble(selected: selected, others: [other, second])

        XCTAssertEqual(home.shelves.map(\.id), ["a", "b", "r", "q"], "library order within a server, servers in order")
        XCTAssertEqual(home.libraries.map(\.id), ["1", "2", "m", "e"])
        XCTAssertEqual(home.continueWatching.map { $0.map(\.ref.itemID) }, [["c1"], ["c2"], []],
                       "one Continue Watching row per server, the selected first")
    }

    func test_assemble_keepsPhotoLibrariesApartInServerOrder() {
        let selected = HomeFeed.ServerRows(libraries: [library("1")], photoLibraries: [library("p1", .photos)])
        let other = HomeFeed.ServerRows(libraries: [library("m", provider: "jellyfin:s")],
                                        photoLibraries: [library("p2", .photos, provider: "jellyfin:s")])
        let home = HomeFeed.assemble(selected: selected, others: [other])
        XCTAssertEqual(home.libraries.map(\.id), ["1", "m"])
        XCTAssertEqual(home.photoLibraries.map(\.id), ["p1", "p2"])
    }

    func test_assemble_leavesHiddenLibrariesRowsOffHome() {
        let selected = HomeFeed.ServerRows(libraries: [library("1"), library("2")],
                                           rowsByLibrary: ["1": [hub("a")], "2": [hub("b")]])
        let other = HomeFeed.ServerRows(libraries: [library("m", provider: "jellyfin:s")],
                                        rowsByLibrary: ["m": [hub("r", provider: "jellyfin:s")]])
        let home = HomeFeed.assemble(selected: selected, others: [other], hiddenLibraries: ["plex:a/2", "jellyfin:s/m"])
        XCTAssertEqual(home.shelves.map(\.id), ["a"])
        XCTAssertEqual(home.libraries.map(\.id), ["1", "2", "m"], "hidden libraries are still listed for Settings")
    }

    func test_assemble_withoutASelectedServer() {
        let other = HomeFeed.ServerRows(libraries: [library("m", provider: "jellyfin:s")], continueWatching: [],
                                        rowsByLibrary: ["m": [hub("r", provider: "jellyfin:s")]])
        let home = HomeFeed.assemble(selected: nil, others: [other])
        XCTAssertEqual(home.shelves.map(\.id), ["r"])
        XCTAssertEqual(home.continueWatching.count, 1)
    }

    // MARK: - loader

    @MainActor
    func test_loader_publishesNothingUntilTheSelectedServerAnswers() async throws {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.libraryList = [library("1")]
        plex.hubsByLibrary = ["1": [hub("a", promoted: true)]]
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jf.libraryList = [library("m", provider: "jellyfin:s")]
        jf.hubsByLibrary = ["m": [hub("m.recentlyAdded", provider: "jellyfin:s")]]
        let loader = HomeFeedLoader()
        var published: [HomeFeed.Assembled] = []
        loader.onChange = { published.append($0) }

        try await loader.load(selected: plex, secondary: [jf])
        await loader.finishSecondary()

        XCTAssertFalse(published.isEmpty)
        XCTAssertEqual(published.first?.shelves.first?.id, "plex:a|a", "the first publish already has the selected server")
        XCTAssertEqual(published.last?.shelves.map(\.id), ["plex:a|a", "jellyfin:s|m.recentlyAdded"])
        XCTAssertFalse(loader.isLoadingSecondary)
    }

    @MainActor
    func test_loader_throwsTheSelectedServersFailure() async {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.librariesError = MediaProviderError.unreachable
        let loader = HomeFeedLoader()
        do {
            try await loader.load(selected: plex, secondary: [])
            XCTFail("expected a throw")
        } catch {}
    }

    @MainActor
    func test_loader_aSecondaryFailureKeepsItsLastRowsAndDoesNotThrow() async throws {
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jf.libraryList = [library("m", provider: "jellyfin:s")]
        jf.hubsByLibrary = ["m": [hub("m.recentlyAdded", provider: "jellyfin:s")]]
        let loader = HomeFeedLoader()
        var latest: HomeFeed.Assembled?
        loader.onChange = { latest = $0 }

        try await loader.load(selected: nil, secondary: [jf])
        XCTAssertEqual(latest?.shelves.count, 1)

        jf.librariesError = MediaProviderError.unreachable
        try await loader.load(selected: nil, secondary: [jf])
        XCTAssertEqual(latest?.shelves.count, 1, "the server dropped off for a moment; its rows stay")
    }

    @MainActor
    func test_loader_aServerThatLeavesTakesItsRowsWithIt() async throws {
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jf.libraryList = [library("m", provider: "jellyfin:s")]
        jf.hubsByLibrary = ["m": [hub("m.recentlyAdded", provider: "jellyfin:s")]]
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.libraryList = [library("1")]
        let loader = HomeFeedLoader()
        var latest: HomeFeed.Assembled?
        loader.onChange = { latest = $0 }

        try await loader.load(selected: plex, secondary: [jf])
        await loader.finishSecondary()
        XCTAssertEqual(latest?.shelves.count, 1)

        try await loader.load(selected: plex, secondary: [])
        XCTAssertEqual(latest?.shelves.count, 0)
    }

    @MainActor
    func test_loader_aNewerLoadCancelsTheSelectedServersOldFetch() async throws {
        let plex = StubMediaProvider(id: "plex:a", kind: .plex)
        plex.libraryList = [library("1")]
        let cancelled = InFlightGauge()
        plex.hubsGate = {
            do { try await Task.sleep(for: .seconds(30)) } catch { await cancelled.enter(); throw error }
        }
        let loader = HomeFeedLoader()
        let first = Task { try await loader.load(selected: plex, secondary: []) }
        try await Task.sleep(for: .milliseconds(50))

        plex.hubsGate = nil
        try await loader.load(selected: plex, secondary: [])
        _ = try? await first.value

        let count = await cancelled.peak
        XCTAssertEqual(count, 1, "the superseded fetch's library request was cancelled, not left to run")
    }

    @MainActor
    func test_loader_onlySecondaryServersAllFailing_throws() async {
        let jf = StubMediaProvider(id: "jellyfin:s", kind: .jellyfin)
        jf.librariesError = MediaProviderError.unauthorized
        let loader = HomeFeedLoader()
        do {
            try await loader.load(selected: nil, secondary: [jf])
            XCTFail("expected a throw")
        } catch {}
    }
}
