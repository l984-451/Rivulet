// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PhotoListing.swift
//  Rivulet
//
//  One folder level's paged contents. The grid and the viewer it opens share
//  an instance, so the viewer pages through exactly what the grid shows.
//

import Foundation

@MainActor
final class PhotoListing {
    /// The provider and the library as it knows it; nil until one is registered.
    typealias Source = @MainActor () -> (provider: any PhotoProvider, library: MediaLibrary)?

    enum Change {
        case reloaded
        case appended(folders: Range<Int>, media: Range<Int>)
        case failed
        /// One photo changed in place (its favorite).
        case updated(media: Int)
    }

    static let pageSize = 200

    /// The source a library's listing reads, shared by every app.
    static func source(for library: MediaLibrary) -> Source {
        {
            (MediaProviderRegistry.shared.provider(for: library.providerID) as? any PhotoProvider)
                .map { ($0, library) }
        }
    }

    private(set) var folders: [PhotoItem] = []
    private(set) var media: [PhotoItem] = []
    private(set) var isLoading = false
    private(set) var error: Error?
    var hasMore: Bool { nextPage != nil }
    var onChange: ((Change) -> Void)?
    /// Changing it starts the listing over, and drops a pending `savedQuery`.
    var query: PhotoQuery {
        get { currentQuery }
        set {
            savedQuery = nil
            guard newValue != currentQuery else { return }
            currentQuery = newValue
            loadFirst()
        }
    }
    private var currentQuery: PhotoQuery
    /// The library's saved query, applied before the first page once the source knows the library.
    private var savedQuery: (@MainActor (MediaLibrary) -> PhotoQuery)?
    /// The library as the last page's source gave it.
    private(set) var library: MediaLibrary?

    let source: Source
    let folder: MediaItemRef?
    private var nextPage: Page? = Page(offset: 0, limit: pageSize)
    private var seen = Set<MediaItemRef>()
    /// Bumped by `loadFirst`, so a page from before the reload is dropped.
    private var generation = 0

    init(folder: MediaItemRef?, query: PhotoQuery = .default,
         savedQuery: (@MainActor (MediaLibrary) -> PhotoQuery)? = nil, source: @escaping Source) {
        self.folder = folder
        self.currentQuery = query
        self.savedQuery = savedQuery
        self.source = source
        PhotoFavoriteWrites.shared.register(self)
    }

    @discardableResult
    func loadFirst() -> Task<Void, Never>? {
        generation += 1
        folders = []
        media = []
        seen = []
        isLoading = false
        nextPage = Page(offset: 0, limit: Self.pageSize)
        // Start the page first, so the reset is announced as loading rather than empty.
        let task = loadMore()
        onChange?(.reloaded)
        return task
    }

    /// Appends the next page. A failed page keeps what is loaded and can be asked for again.
    @discardableResult
    func loadMore() -> Task<Void, Never>? {
        guard !isLoading, let page = nextPage else { return nil }
        // A source can be empty at first (the registry not yet filled), so this waits for one that answers.
        if let savedQuery, let library = source()?.library {
            self.savedQuery = nil
            currentQuery = savedQuery(library)
        }
        isLoading = true
        error = nil
        let generation = generation, query = query
        return Task {
            do {
                guard let (provider, library) = source() else { throw MediaProviderError.unreachable }
                let result = try await provider.photoPage(in: library, folder: folder, query: query, page: page)
                guard generation == self.generation else { return }
                self.library = library
                let firstFolder = folders.count, firstMedia = media.count
                // ponytail: shuffles each page as it lands, so early pages lead; load every id first if users notice.
                let clientShuffle = query.shuffled && !provider.shufflesPhotosOnServer
                if !query.shuffled { folders += result.folders.filter { seen.insert($0.ref).inserted } }
                let pending = PhotoFavoriteWrites.shared.pending
                media += (clientShuffle ? result.media.shuffled() : result.media)
                    .filter { seen.insert($0.ref).inserted }
                    .map { item in
                        // A write the server may not have applied yet outranks what the page says.
                        var item = item
                        if let favorite = pending[item.ref] { item.isFavorite = favorite }
                        return item
                    }
                nextPage = result.nextPage
                isLoading = false
                onChange?(.appended(folders: firstFolder..<folders.count, media: firstMedia..<media.count))
            } catch {
                guard generation == self.generation else { return }
                self.error = error
                isLoading = false
                onChange?(.failed)
            }
        }
    }

    /// Sets one photo's favorite at once on every listing, and puts it back if the server refuses.
    /// The returned task ends once every write queued for the photo has settled.
    @discardableResult
    func setFavorite(_ favorite: Bool, at index: Int) -> Task<Void, Never>? {
        guard media.indices.contains(index), media[index].isFavorite != favorite,
              let provider = source()?.provider else { return nil }
        let item = media[index]
        return PhotoFavoriteWrites.shared.set(favorite, for: item.ref, was: item.isFavorite, provider: provider)
    }

    /// A favorite changed somewhere: the photo stays where it is, even in a Favorites grid.
    fileprivate func applyFavorite(_ favorite: Bool, ref: MediaItemRef) {
        guard let index = media.firstIndex(where: { $0.ref == ref }), media[index].isFavorite != favorite else { return }
        media[index].isFavorite = favorite
        onChange?(.updated(media: index))
    }
}

/// Favorite writes for every listing: one request at a time per photo, the latest choice winning,
/// and every live listing holding the photo told of each change.
@MainActor
final class PhotoFavoriteWrites {
    static let shared = PhotoFavoriteWrites()
    private let listings = NSHashTable<PhotoListing>.weakObjects()
    /// The latest choice per photo the server has not confirmed yet.
    private(set) var pending: [MediaItemRef: Bool] = [:]
    private var running: [MediaItemRef: Task<Void, Never>] = [:]

    func register(_ listing: PhotoListing) { listings.add(listing) }

    /// `current` is the server's value when no write for the photo is running.
    func set(_ favorite: Bool, for ref: MediaItemRef, was current: Bool,
             provider: any PhotoProvider) -> Task<Void, Never> {
        pending[ref] = favorite
        broadcast(favorite, ref: ref)
        if let task = running[ref] { return task }
        let task = Task {
            var onServer = current
            while let wanted = pending[ref], wanted != onServer {
                do {
                    try await provider.setPhotoFavorite(wanted, for: ref)
                    onServer = wanted
                } catch {
                    // A newer choice is tried next; otherwise this one is put back.
                    if pending[ref] == wanted { pending[ref] = nil }
                }
            }
            pending[ref] = nil
            running[ref] = nil
            broadcast(onServer, ref: ref)
        }
        running[ref] = task
        return task
    }

    private func broadcast(_ favorite: Bool, ref: MediaItemRef) {
        for listing in listings.allObjects { listing.applyFavorite(favorite, ref: ref) }
    }
}
