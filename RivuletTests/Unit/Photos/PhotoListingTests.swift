// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

private final class StubPhotoProvider: PhotoProvider, @unchecked Sendable {
    var pages: [Int: Result<PhotoPage, Error>] = [:]
    var asked: [Int] = []
    var queries: [PhotoQuery] = []
    var shufflesPhotosOnServer = true
    /// Held until the test lets the page through.
    var gate: CheckedContinuation<Void, Never>?
    var holds = false
    var favorites: [(Bool, MediaItemRef)] = []
    var favoriteError: Error?
    /// Each favorite write waits here while `holdsFavorites`.
    var favoriteGate: CheckedContinuation<Void, Never>?
    var holdsFavorites = false

    var photoSorts: [PhotoQuery.Sort] { [.dateTaken] }
    var hasPhotoLocations: Bool { false }

    func photoPage(in library: MediaLibrary, folder: MediaItemRef?, query: PhotoQuery, page: Page) async throws -> PhotoPage {
        asked.append(page.offset)
        queries.append(query)
        let result = pages[page.offset] ?? .failure(MediaProviderError.notFound)
        if holds { await withCheckedContinuation { gate = $0 } }
        return try result.get()
    }

    func photoYears(in library: MediaLibrary) async throws -> [Int] { [] }

    func setPhotoFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws {
        favorites.append((favorite, ref))
        if holdsFavorites { await withCheckedContinuation { favoriteGate = $0 } }
        if let favoriteError { throw favoriteError }
    }
}

@MainActor
final class PhotoListingTests: XCTestCase {
    private let provider = StubPhotoProvider()
    private let library = MediaLibrary(id: "lib", providerID: "stub", title: "Photos", kind: .photos)
    private var changes: [PhotoListing.Change] = []

    private func item(_ id: String, _ kind: PhotoItem.Kind = .photo) -> PhotoItem {
        PhotoItem(ref: MediaItemRef(providerID: "stub", itemID: id), kind: kind, title: id, date: nil,
                  childCount: nil, thumbnail: nil, full: nil, playable: nil)
    }

    private func page(folders: [String] = [], media: [String], next: Int?) -> Result<PhotoPage, Error> {
        .success(PhotoPage(folders: folders.map { item($0, .folder) }, media: media.map { item($0) },
                           nextPage: next.map { Page(offset: $0, limit: PhotoListing.pageSize) }))
    }

    private func listing() -> PhotoListing {
        let listing = PhotoListing(folder: nil) { [provider, library] in (provider, library) }
        listing.onChange = { [weak self] in self?.changes.append($0) }
        return listing
    }

    func test_pagesAppendInOrder_andEndWhenThereIsNoNextPage() async {
        provider.pages = [0: page(folders: ["f1"], media: ["a", "b"], next: 200), 200: page(media: ["c"], next: nil)]
        let listing = listing()

        await listing.loadFirst()?.value
        XCTAssertEqual(listing.media.map(\.title), ["a", "b"])
        XCTAssertTrue(listing.hasMore)

        await listing.loadMore()?.value
        XCTAssertEqual(listing.media.map(\.title), ["a", "b", "c"])
        XCTAssertEqual(listing.folders.map(\.title), ["f1"])
        XCTAssertFalse(listing.hasMore)
        XCTAssertNil(listing.loadMore(), "nothing left to ask for")
        XCTAssertEqual(provider.asked, [0, 200])

        guard case .appended(let folders, let media)? = changes.last else { return XCTFail("no append reported") }
        XCTAssertEqual(folders, 1..<1)
        XCTAssertEqual(media, 2..<3, "the grid inserts exactly these rows")
    }

    func test_aRefSeenTwice_isKeptOnce() async {
        provider.pages = [0: page(media: ["a", "b"], next: 200), 200: page(media: ["b", "c"], next: nil)]
        let listing = listing()
        await listing.loadFirst()?.value
        await listing.loadMore()?.value
        XCTAssertEqual(listing.media.map(\.title), ["a", "b", "c"], "a duplicate row would crash the data source")
    }

    func test_foldersFromALaterPage_joinTheFolderList() async {
        provider.pages = [0: page(folders: ["f1"], media: ["a"], next: 200),
                          200: page(folders: ["f2"], media: ["b"], next: nil)]
        let listing = listing()
        await listing.loadFirst()?.value
        await listing.loadMore()?.value
        XCTAssertEqual(listing.folders.map(\.title), ["f1", "f2"])
    }

    func test_aFailedLaterPage_keepsWhatIsLoaded_andCanBeRetried() async {
        provider.pages = [0: page(media: ["a"], next: 200)]
        let listing = listing()
        await listing.loadFirst()?.value

        await listing.loadMore()?.value
        XCTAssertNotNil(listing.error)
        XCTAssertEqual(listing.media.map(\.title), ["a"])
        XCTAssertTrue(listing.hasMore)
        XCTAssertFalse(listing.isLoading)

        provider.pages[200] = page(media: ["b"], next: nil)
        await listing.loadMore()?.value
        XCTAssertNil(listing.error)
        XCTAssertEqual(listing.media.map(\.title), ["a", "b"])
    }

    func test_loadFirst_startsOver() async {
        provider.pages = [0: page(media: ["a"], next: nil)]
        let listing = listing()
        await listing.loadFirst()?.value
        provider.pages = [0: page(media: ["z"], next: nil)]
        await listing.loadFirst()?.value
        XCTAssertEqual(listing.media.map(\.title), ["z"])
    }

    func test_loadFirst_announcesTheReloadAsLoading_withTheOldErrorCleared() async {
        let listing = listing()
        await listing.loadFirst()?.value
        XCTAssertNotNil(listing.error)

        var seen: [(loading: Bool, failed: Bool)] = []
        listing.onChange = { [unowned listing] change in
            if case .reloaded = change { seen.append((listing.isLoading, listing.error != nil)) }
        }
        await listing.loadFirst()?.value
        XCTAssertEqual(seen.map(\.loading), [true], "an empty, idle listing reads as No Content")
        XCTAssertEqual(seen.map(\.failed), [false])
    }

    func test_queryChangeDropsInFlightPage() async throws {
        provider.pages = [0: page(media: ["old"], next: nil)]
        provider.holds = true
        let listing = listing()
        let stale = listing.loadFirst()
        while provider.gate == nil { await Task.yield() }

        provider.holds = false
        provider.pages = [0: page(media: ["new"], next: nil)]
        listing.query = PhotoQuery(sort: .name)
        provider.gate?.resume()
        await stale?.value
        while listing.isLoading { await Task.yield() }

        XCTAssertEqual(listing.media.map(\.title), ["new"], "the page asked for under the old query never lands")
        XCTAssertEqual(provider.queries.last?.sort, .name)
    }

    func test_clientShuffleKeepsEachPhotoOnce() async {
        provider.shufflesPhotosOnServer = false
        provider.pages = [0: page(folders: ["f"], media: (1...6).map(String.init), next: 200),
                          200: page(media: (4...10).map(String.init), next: nil)]
        let listing = PhotoListing(folder: nil, query: PhotoQuery(shuffled: true)) { [provider, library] in (provider, library) }
        await listing.loadFirst()?.value
        await listing.loadMore()?.value
        XCTAssertEqual(listing.media.compactMap { Int($0.title) }.sorted(), Array(1...10))
        XCTAssertTrue(listing.folders.isEmpty, "a shuffled listing is photos alone")
        XCTAssertEqual(listing.library?.id, "lib")
    }

    func test_withNoProvider_reportsAFailure() async {
        let listing = PhotoListing(folder: nil) { nil }
        await listing.loadFirst()?.value
        XCTAssertNotNil(listing.error)
        XCTAssertTrue(listing.media.isEmpty)
    }

    func test_savedQuery_waitsForTheSource_thenAppliesBeforeTheFirstPage() async {
        provider.pages = [0: page(media: ["a"], next: nil)]
        var registered = false
        var saved = PhotoQuery()
        saved.sort = .name
        let listing = PhotoListing(folder: nil, savedQuery: { _ in saved }) { [provider, library] in
            registered ? (provider, library) : nil
        }
        await listing.loadFirst()?.value
        XCTAssertNotNil(listing.error, "no source yet")
        XCTAssertEqual(listing.query, .default)

        registered = true
        await listing.loadMore()?.value
        XCTAssertEqual(listing.query.sort, .name)
        XCTAssertEqual(provider.queries.map(\.sort), [.name], "the first page asked for the saved sort")
        XCTAssertEqual(listing.media.map(\.title), ["a"])
    }

    func test_aQueryChosenBeforeTheSourceAnswers_winsOverTheSavedOne() async {
        provider.pages = [0: page(media: ["a"], next: nil)]
        var registered = false
        var saved = PhotoQuery()
        saved.sort = .name
        let listing = PhotoListing(folder: nil, savedQuery: { _ in saved }) { [provider, library] in
            registered ? (provider, library) : nil
        }
        var chosen = PhotoQuery()
        chosen.show = .videos
        listing.query = chosen
        registered = true
        await listing.loadFirst()?.value
        XCTAssertEqual(listing.query, chosen)
        XCTAssertFalse(provider.queries.isEmpty)
        XCTAssertTrue(provider.queries.allSatisfy { $0 == chosen }, "the saved sort never applied")
    }

    func test_setFavoriteUpdatesThenRollsBack() async {
        provider.pages = [0: page(media: ["a", "b"], next: nil)]
        provider.favoriteError = MediaProviderError.unreachable
        let listing = listing()
        await listing.loadFirst()?.value
        changes = []

        let task = listing.setFavorite(true, at: 1)
        XCTAssertTrue(listing.media[1].isFavorite, "the tile changes before the server answers")
        await task?.value
        XCTAssertFalse(listing.media[1].isFavorite, "a refused favorite is put back")
        let updated = changes.compactMap { change -> Int? in
            if case .updated(let media) = change { return media } else { return nil }
        }
        XCTAssertEqual(updated, [1, 1])
    }

    func test_setFavoriteSucceeds() async {
        provider.pages = [0: page(media: ["a", "b"], next: nil)]
        let listing = listing()
        await listing.loadFirst()?.value

        await listing.setFavorite(true, at: 0)?.value
        XCTAssertTrue(listing.media[0].isFavorite)
        XCTAssertEqual(provider.favorites.map(\.0), [true])
        XCTAssertEqual(provider.favorites.map(\.1), [listing.media[0].ref])
        XCTAssertNil(listing.setFavorite(true, at: 0), "already a favorite: nothing to send")
    }

    /// Lets the held favorite write through, and stops holding later ones.
    private func releaseFavorite() async {
        while provider.favoriteGate == nil { await Task.yield() }
        provider.holdsFavorites = false
        let gate = provider.favoriteGate
        provider.favoriteGate = nil
        gate?.resume()
    }

    func test_reloadDuringAPendingWrite_keepsTheNewState() async {
        provider.pages = [0: page(media: ["a", "b"], next: nil)]
        provider.holdsFavorites = true
        let listing = listing()
        await listing.loadFirst()?.value

        let task = listing.setFavorite(true, at: 0)
        await listing.loadFirst()?.value
        XCTAssertTrue(listing.media[0].isFavorite, "the page predates the write and must not undo it")
        await releaseFavorite()
        await task?.value
        XCTAssertTrue(listing.media[0].isFavorite)
    }

    func test_onOffOn_endsOnWithoutARollback() async {
        provider.pages = [0: page(media: ["a"], next: nil)]
        provider.holdsFavorites = true
        let listing = listing()
        await listing.loadFirst()?.value
        changes = []

        let task = listing.setFavorite(true, at: 0)
        listing.setFavorite(false, at: 0)
        listing.setFavorite(true, at: 0)
        await releaseFavorite()
        await task?.value
        XCTAssertTrue(listing.media[0].isFavorite)
        XCTAssertEqual(provider.favorites.map(\.0), [true], "one write at a time; the last choice was already sent")
        let updates = changes.filter { if case .updated = $0 { true } else { false } }
        XCTAssertEqual(updates.count, 3, "on, off, on, and no rollback after")
    }

    func test_aSecondListingOfTheSamePhoto_updatesOnSuccess() async {
        provider.pages = [0: page(media: ["a", "b"], next: nil)]
        let first = listing()
        let second = PhotoListing(folder: nil, query: PhotoQuery(favoritesOnly: true)) { [provider, library] in
            (provider, library)
        }
        var secondChanges: [PhotoListing.Change] = []
        second.onChange = { secondChanges.append($0) }
        await first.loadFirst()?.value
        await second.loadFirst()?.value
        secondChanges = []

        await first.setFavorite(true, at: 1)?.value
        XCTAssertTrue(second.media[1].isFavorite)
        guard case .updated(let index)? = secondChanges.last else { return XCTFail("no update reported") }
        XCTAssertEqual(index, 1)

        await second.setFavorite(false, at: 1)?.value
        XCTAssertFalse(first.media[1].isFavorite)
        XCTAssertEqual(second.media.count, 2, "unfavoriting leaves the photo in place")
    }
}
