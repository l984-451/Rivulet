// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinDataStore.swift
//  Rivulet
//
//  What the browse surfaces show from the signed-in Jellyfin server: its
//  libraries (sidebar, Settings) and its Home rows. The counterpart of
//  PlexDataStore's library list and Home projection, without disk caches.
//  Rows are never merged with Plex's; Home places them beside Plex's.
//

import Combine
import Foundation

@MainActor
final class JellyfinDataStore: ObservableObject {
    static let shared = JellyfinDataStore()

    /// Mirrored from `JellyfinSession.account` so SwiftUI and Combine can
    /// observe sign-in and sign-out.
    @Published private(set) var account: JellyfinSession.Account?
    /// Every browsable library in server order. The sidebar and Home use
    /// `visibleLibraries`; Settings > Sidebar Libraries lists these.
    @Published private(set) var libraries: [MediaLibrary] = []
    /// Every row, hidden ones included: Settings > Home Rows lists them so a
    /// hidden row can be switched back on. Continue Watching first, then one
    /// Recently Added row per library in server order.
    @Published private(set) var homeRows: CachedHomeRail = []
    @Published private(set) var isLoading = false

    /// Video libraries only. Music and photo libraries render through
    /// Plex-only views; they join when those views take a provider.
    static let browsableKinds: Set<MediaLibrary.LibraryKind> = [.movies, .shows, .mixed]

    private var loadTask: Task<Void, Never>?
    private var refreshObserver: NSObjectProtocol?

    init(observesRefresh: Bool = true) {
        guard observesRefresh else { return }
        // Before the first sidebar render, so a Jellyfin-only launch never
        // flashes the signed-out welcome.
        account = JellyfinSession.account
        // Watch-state changes (detail page, tile menus, playback) post this.
        refreshObserver = NotificationCenter.default.addObserver(
            forName: .plexDataNeedsRefresh, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// The sidebar's Jellyfin section, in the user's order.
    var visibleLibraries: [MediaLibrary] {
        LibrarySettingsManager.shared.filterAndSort(libraries)
    }

    /// Continue Watching, then each visible library's row in sidebar order.
    /// Settings > Home Rows lists these, hidden rows included.
    var homeRowsInSidebarOrder: CachedHomeRail {
        let continuing = homeRows.filter(\.isContinueWatching)
        // Matched on the id's suffix, not rebuilt from `account`: the account
        // is nil in tests and for a moment during reload.
        let perLibrary = visibleLibraries.compactMap { library in
            homeRows.first { $0.id.hasSuffix("|\(library.id).recentlyAdded") }
        }
        return continuing + perLibrary
    }

    /// The rows Home draws: `homeRowsInSidebarOrder` minus rows hidden in
    /// Settings > Home Rows. Home's empty check reads this too, so a Home
    /// whose only rows are hidden takes the empty state rather than drawing
    /// nothing.
    var visibleHomeRows: CachedHomeRail {
        homeRowsInSidebarOrder.filter { !HomeRowSettings.isHidden($0.hubIdentifier) }
    }

    /// More than one source is signed in, so rows and tiles name their
    /// server. With one Jellyfin account beside Plex that is "both signed in";
    /// a second non-Plex provider would need a store per provider, keyed by
    /// provider id, and this would count the signed-in sources.
    var labelsServers: Bool {
        account != nil && PlexAuthManager.shared.hasCredentials
    }

    /// Re-reads the account and refetches. Called at launch, from
    /// `JellyfinSession.onChanged`, on `.plexDataNeedsRefresh`, and on
    /// foreground.
    // ponytail: no timed poll; content added on the server shows on the next
    // foreground or watch-state change. Add one like PlexDataStore's 30s
    // poll if that proves too slow.
    func reload() {
        loadTask?.cancel()
        // Assigned only on change: Plex-only users reach here on every launch,
        // foreground and watch-state change, and each publish redraws Home.
        update(\.account, JellyfinSession.account)
        guard let account,
              let provider = MediaProviderRegistry.shared.provider(for: account.providerID) else {
            update(\.libraries, [])
            if !homeRows.isEmpty { homeRows = [] }
            update(\.isLoading, false)
            return
        }
        // Synchronous, so the first render after sign-in shows loading, not empty.
        update(\.isLoading, true)
        loadTask = Task { await load(from: provider) }
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<JellyfinDataStore, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    /// A failed fetch keeps what was there: a server that drops off for a
    /// moment must not empty the sidebar or Home under the user.
    func load(from provider: any MediaProvider) async {
        update(\.isLoading, true)
        async let fetchedContinuing = provider.continueWatching(limit: 20)
        guard let fetched = try? await provider.libraries() else {
            _ = try? await fetchedContinuing
            if !Task.isCancelled { update(\.isLoading, false) }
            return
        }
        let browsable = fetched.filter { Self.browsableKinds.contains($0.kind) }
        var recent: [CachedHomeHub] = []
        for library in browsable {
            let suffix = "|\(library.id).recentlyAdded"
            do {
                if let hub = try await provider.recentlyAddedHub(in: library) { recent.append(Self.row(hub)) }
            } catch {
                // This library's fetch failed: keep its row.
                if let previous = homeRows.first(where: { $0.id.hasSuffix(suffix) }) { recent.append(previous) }
            }
        }
        var continuingRow: [CachedHomeHub] = []
        if let continuing = try? await fetchedContinuing {
            if !continuing.isEmpty {
                let id = Self.rowID(provider.id, "continueWatching")
                continuingRow = [CachedHomeHub(
                    id: id, title: "Continue Watching", isContinueWatching: true, hubKey: nil,
                    hubIdentifier: id, totalSize: nil, items: continuing)]
            }
        } else {
            continuingRow = homeRows.filter(\.isContinueWatching)
        }
        guard !Task.isCancelled else { return }
        update(\.libraries, browsable)
        homeRows = continuingRow + recent
        update(\.isLoading, false)
    }

    /// Provider-prefixed ids keep a Jellyfin row distinct from every Plex row
    /// in the Home snapshot and in `HomeRowSettings`.
    static func rowID(_ providerID: String, _ hubID: String) -> String { "\(providerID)|\(hubID)" }

    static func row(_ hub: MediaHub) -> CachedHomeHub {
        let id = rowID(hub.providerID, hub.id)
        return CachedHomeHub(id: id, title: hub.title, isContinueWatching: hub.id.hasSuffix(".continueWatching"),
                             hubKey: nil, hubIdentifier: id, totalSize: nil, items: hub.items)
    }
}
