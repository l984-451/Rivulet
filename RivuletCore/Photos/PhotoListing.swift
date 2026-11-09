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
    /// Changing it starts the listing over.
    var query: PhotoQuery {
        didSet { if query != oldValue { loadFirst() } }
    }
    /// The library as the last page's source gave it.
    private(set) var library: MediaLibrary?

    private let source: Source
    private let folder: MediaItemRef?
    private var nextPage: Page? = Page(offset: 0, limit: pageSize)
    private var seen = Set<MediaItemRef>()
    /// Bumped by `loadFirst`, so a page from before the reload is dropped.
    private var generation = 0

    init(folder: MediaItemRef?, query: PhotoQuery = .default, source: @escaping Source) {
        self.folder = folder
        self.query = query
        self.source = source
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
                media += (clientShuffle ? result.media.shuffled() : result.media).filter { seen.insert($0.ref).inserted }
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
}
