// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  FolderListing.swift
//  Rivulet
//
//  One folder level's paged contents, folders first, then files.
//

import Foundation

@MainActor
final class FolderListing {
    /// The provider and the library as it knows it; nil until one is registered.
    typealias Source = @MainActor () -> (any FolderProvider, MediaLibrary)?

    enum Change {
        case reloaded
        case appended(Range<Int>)
        case failed
    }

    static let pageSize = 100

    let folder: MediaItemRef?
    private(set) var entries: [FolderEntry] = []
    private(set) var isLoading = false {
        didSet { if !isLoading, pendingRefresh { pendingRefresh = false; refresh() } }
    }
    /// A refresh asked for mid-load; runs when the load ends.
    private var pendingRefresh = false
    private(set) var error: Error?
    var hasMore: Bool { nextPage != nil }
    var onChange: ((Change) -> Void)?

    let source: Source
    private var nextPage: Page? = Page(offset: 0, limit: pageSize)
    private var seen = Set<MediaItemRef>()
    /// Bumped by `loadFirst` and `refresh`, so a page from before them is dropped.
    private var generation = 0

    init(folder: MediaItemRef?, source: @escaping Source) {
        self.folder = folder
        self.source = source
    }

    @discardableResult
    func loadFirst() -> Task<Void, Never>? {
        generation += 1
        pendingRefresh = false
        entries = []
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
        let generation = generation
        return Task {
            do {
                let result = try await fetch(page)
                guard generation == self.generation else { return }
                let first = entries.count
                entries += result.entries.filter { seen.insert($0.id).inserted }
                nextPage = result.nextPage
                isLoading = false
                onChange?(.appended(first..<entries.count))
            } catch {
                guard generation == self.generation else { return }
                self.error = error
                isLoading = false
                onChange?(.failed)
            }
        }
    }

    /// Re-reads everything loaded in one request and swaps it in whole, so the
    /// rows (and focus) stay put meanwhile. A failed refresh keeps the old rows.
    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard !entries.isEmpty else { return loadFirst() }
        guard !isLoading else { pendingRefresh = true; return nil }
        generation += 1
        isLoading = true
        let generation = generation
        let page = Page(offset: 0, limit: max(Self.pageSize, entries.count))
        return Task {
            let result = try? await fetch(page)
            guard generation == self.generation else { return }
            isLoading = false
            guard let result else { return }
            var seen = Set<MediaItemRef>()
            entries = result.entries.filter { seen.insert($0.id).inserted }
            self.seen = seen
            nextPage = result.nextPage.map { Page(offset: $0.offset, limit: Self.pageSize, cursor: $0.cursor) }
            error = nil
            onChange?(.reloaded)
        }
    }

    /// Swaps a refreshed video in place; the caller reconfigures its row.
    func replace(_ item: MediaItem) {
        guard let index = entries.firstIndex(where: { $0.id == item.ref }),
              case .video = entries[index].content else { return }
        entries[index] = FolderEntry(id: item.ref, title: entries[index].title, content: .video(item))
    }

    private func fetch(_ page: Page) async throws -> FolderPage {
        guard let (provider, library) = source() else { throw MediaProviderError.unreachable }
        return try await provider.folderPage(in: library, folder: folder, page: page)
    }
}

/// The trailing text on a folder row.
enum FolderRowDetail {
    static func text(for entry: FolderEntry) -> String {
        switch entry.content {
        case .folder: return "›"
        case .photo: return ""
        case .video(let item):
            // A resume point outranks the watched flag (CLAUDE.md "Watch State").
            if item.isInProgress, let runtime = item.runtime {
                return "\(length(runtime - item.userState.viewOffset)) left"
            }
            if item.isWatched { return "✓" }
            return item.runtime.map { length($0) } ?? ""
        }
    }

    /// "11 min", "1 hr 32 min": rounded to the minute, never under one.
    static func length(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        guard minutes >= 60 else { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) hr" : "\(minutes / 60) hr \(minutes % 60) min"
    }
}
