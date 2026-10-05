// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexWatchlistService.swift
//  Rivulet
//
//  Account-level Plex Watchlist with optimistic writes and disk cache.
//

import Foundation
import Combine
import os.log

private let watchlistLog = Logger(subsystem: "com.rivulet.app", category: "PlexWatchlist")

@MainActor
final class PlexWatchlistService: ObservableObject {
    static let shared = PlexWatchlistService(
        api: PlexWatchlistAPI(),
        cache: FileWatchlistCache(),
        // Watchlist lives on metadata.provider.plex.tv (the account-wide
        // Discover API), so it requires the owner's authToken — NOT the
        // server-specific selectedServerToken.
        tokenProvider: { PlexAuthManager.shared.authToken }
    )

    @Published private(set) var watchlistItems: [PlexWatchlistItem] = []
    @Published private(set) var watchlistGUIDs: Set<String> = []
    @Published private(set) var lastFetchError: Error?

    /// A user-facing message surfaced when the most recent write optimistically
    /// reverted. Views observe this to show a transient toast; setter auto-clears
    /// after a short delay so consumers don't need to manage the lifecycle.
    @Published private(set) var transientWriteError: String?

    private let api: PlexWatchlistAPIProtocol
    private let cache: WatchlistCacheProtocol
    private let tokenProvider: @MainActor () -> String?
    private var lastFetched: Date?

    // 60s balances responsiveness with network traffic — fresh enough that
    // changes made on another Plex client appear quickly on Home, but not so
    // aggressive that idle screens hammer the API.
    private let staleAfter: TimeInterval = 60
    private let transientErrorDuration: TimeInterval = 3

    init(
        api: PlexWatchlistAPIProtocol,
        cache: WatchlistCacheProtocol,
        tokenProvider: @escaping @MainActor () -> String? = { "test-token" }
    ) {
        self.api = api
        self.cache = cache
        self.tokenProvider = tokenProvider

        if let cached = cache.load() {
            watchlistItems = cached
            watchlistGUIDs = Set(cached.flatMap(\.guids))
        }
    }

    func fetchWatchlist(force: Bool = false) async {
        if !force, let lastFetched, Date().timeIntervalSince(lastFetched) < staleAfter {
            watchlistLog.debug("fetchWatchlist skipped: cache age <\(self.staleAfter)s")
            return
        }
        guard let token = tokenProvider() else {
            watchlistLog.warning("fetchWatchlist aborted: no Plex token")
            return
        }
        do {
            let items = try await api.fetchAll(token: token)
            watchlistItems = items
            watchlistGUIDs = Set(items.flatMap(\.guids))
            cache.save(items)
            lastFetched = Date()
            lastFetchError = nil
            watchlistLog.info("fetchWatchlist success: \(items.count) items")
        } catch {
            lastFetchError = error
            watchlistLog.error("fetchWatchlist failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func add(guid: String, item: PlexWatchlistItem) async {
        guard let token = tokenProvider() else {
            surface("Sign in to use Watchlist")
            return
        }

        let snapshotItems = watchlistItems
        let snapshotGUIDs = watchlistGUIDs

        // Optimistic update
        watchlistItems.insert(item, at: 0)
        watchlistGUIDs.formUnion(item.guids)

        do {
            try await api.add(guids: [guid], type: item.type, token: token)
            cache.save(watchlistItems)
            watchlistLog.info("add succeeded: \(guid, privacy: .public)")
        } catch {
            watchlistItems = snapshotItems
            watchlistGUIDs = snapshotGUIDs
            lastFetchError = error
            watchlistLog.error("add failed for \(guid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            surface("Couldn't update Watchlist")
        }
    }

    func remove(guid: String) async {
        guard let token = tokenProvider() else {
            surface("Sign in to use Watchlist")
            return
        }

        let snapshotItems = watchlistItems
        let snapshotGUIDs = watchlistGUIDs

        // The item we're dropping knows whether it's a movie or a show, which is
        // what disambiguates the Discover match (see PlexWatchlistAPI).
        let type = watchlistItems.first { $0.guids.contains(guid) }?.type

        // Optimistic update: remove matching items and ALL their associated GUIDs
        let removedItems = watchlistItems.filter { $0.guids.contains(guid) }
        let removedGuids = Set(removedItems.flatMap(\.guids))
        watchlistItems.removeAll { $0.guids.contains(guid) }
        watchlistGUIDs.subtract(removedGuids)

        do {
            try await api.remove(guid: guid, type: type, token: token)
            cache.save(watchlistItems)
            watchlistLog.info("remove succeeded: \(guid, privacy: .public)")
        } catch {
            watchlistItems = snapshotItems
            watchlistGUIDs = snapshotGUIDs
            lastFetchError = error
            watchlistLog.error("remove failed for \(guid, privacy: .public): \(error.localizedDescription, privacy: .public)")
            surface("Couldn't update Watchlist")
        }
    }

    func contains(guid: String) -> Bool {
        watchlistGUIDs.contains(guid)
    }

    func contains(tmdbId: Int) -> Bool {
        watchlistGUIDs.contains("tmdb://\(tmdbId)")
    }

    func reset() {
        watchlistItems = []
        watchlistGUIDs = []
        lastFetched = nil
        cache.clear()
    }

    private func surface(_ message: String) {
        transientWriteError = message
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(transientErrorDuration))
            guard let self else { return }
            if self.transientWriteError == message {
                self.transientWriteError = nil
            }
        }
    }
}
