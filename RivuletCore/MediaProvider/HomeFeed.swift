// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomeFeed.swift
//  Rivulet
//
//  Home for the iOS app, built from the provider registry for every server: the selected Plex
//  server's promoted rows of its pinned libraries, each other server's Continue Watching and
//  Recently Added rows, and one libraries list. Continue Watching merges across servers in
//  `ContinueWatchingRow`. tvOS builds its own Home (`PlexDataStore`, `ServerDataStore`).
//

import Foundation

nonisolated enum HomeFeed {
    /// Rails stop here; the header's See All pages the rest.
    static let railLimit = 20
    static let continueWatchingLimit = 50
    /// The libraries Home and the Library tab list: iOS has no music or photo browser.
    static let videoKinds: Set<MediaLibrary.LibraryKind> = [.movies, .shows, .mixed]

    enum Role: Sendable {
        /// The selected Plex server: the rows its user promoted to the Plex home screen.
        case selected
        /// Every other server: its Recently Added row per library, as tvOS shows them.
        case secondary
    }

    /// One server's answer.
    struct ServerRows: Sendable, Equatable {
        var libraries: [MediaLibrary] = []
        /// Nil when its fetch failed, so the last answer stands.
        var continueWatching: [MediaItem]?
        /// Rows after Continue Watching, by library id. A library missing here failed.
        var rowsByLibrary: [String: [MediaHub]] = [:]

        /// This answer with the last good one standing wherever a fetch failed.
        func keeping(_ previous: ServerRows?) -> ServerRows {
            guard let previous else { return self }
            var merged = self
            if continueWatching == nil { merged.continueWatching = previous.continueWatching }
            for library in libraries where rowsByLibrary[library.id] == nil {
                merged.rowsByLibrary[library.id] = previous.rowsByLibrary[library.id]
            }
            return merged
        }
    }

    struct Assembled: Sendable, Equatable {
        var libraries: [MediaLibrary]
        /// Each server's Continue Watching items, the selected server first, for the merge.
        var continueWatching: [[MediaItem]]
        var shelves: [MediaHub]
        /// Servers whose fetch failed, by provider id, with the error's message. A server that failed
        /// but has older rows still has them in the lists above.
        var failures: [String: String] = [:]
    }

    static func assemble(selected: ServerRows?, others: [ServerRows]) -> Assembled {
        let servers = (selected.map { [$0] } ?? []) + others
        return Assembled(
            libraries: servers.flatMap(\.libraries),
            continueWatching: servers.map { $0.continueWatching ?? [] },
            shelves: servers.flatMap { server in server.libraries.flatMap { server.rowsByLibrary[$0.id] ?? [] } })
    }

    /// Fetches one server's Home. Only the library list can fail the call; a failed
    /// Continue Watching or library row is recorded as missing (see `ServerRows`).
    static func fetch(_ provider: any MediaProvider, role: Role) async throws -> ServerRows {
        async let continuing = try? await provider.continueWatching(limit: continueWatchingLimit)
        let libraries = try await provider.libraries().filter { videoKinds.contains($0.kind) }
        let wanted = role == .selected ? libraries.filter(\.isPinnedToHome) : libraries
        let rows = await withTaskGroup(of: (String, [MediaHub]?).self) { group in
            for library in wanted {
                group.addTask { (library.id, await libraryRows(provider, library, role: role)) }
            }
            var found: [String: [MediaHub]] = [:]
            for await (id, hubs) in group { found[id] = hubs }
            return found
        }
        return ServerRows(libraries: libraries, continueWatching: await continuing, rowsByLibrary: rows)
    }

    /// Nil when the library's fetch failed; empty when it answered with no row.
    private static func libraryRows(_ provider: any MediaProvider, _ library: MediaLibrary, role: Role) async -> [MediaHub]? {
        let hubs: [MediaHub]
        do {
            switch role {
            case .selected:
                hubs = try await provider.hubs(in: library).filter {
                    $0.isPromoted && !$0.isContinueWatchingFamily && !$0.items.isEmpty
                }
            case .secondary:
                hubs = try await provider.recentlyAddedHub(in: library).map { $0.items.isEmpty ? [] : [$0] } ?? []
            }
        } catch {
            return nil
        }
        // Two servers can share a hub id, so a row's id names its server.
        return hubs.map {
            MediaHub(id: "\(provider.id)|\($0.id)", providerID: $0.providerID, title: $0.title, style: $0.style,
                     items: $0.items, pagingKey: $0.pagingKey, isPromoted: $0.isPromoted)
        }
    }

    /// A library's own page of rows (its Recommended), in the server's order, empty rows dropped.
    static func libraryRows(_ provider: any MediaProvider, _ library: MediaLibrary) async throws -> [MediaHub] {
        try await provider.hubs(in: library).filter { !$0.items.isEmpty }
    }

    /// The merged Continue Watching row: one card per title across servers.
    @MainActor
    static func continueWatchingCards(_ rows: [[MediaItem]], row: ContinueWatchingRow? = nil) -> [ContinueWatchingMerge.Card<MediaItem>] {
        let row = row ?? .shared
        return row.cards(rows, identity: { $0.identity ?? [] }, showKey: { $0.showKey }, watched: { $0.userState.lastViewedAt })
    }
}

extension MediaHub {
    /// Continue Watching, On Deck and in-progress rows, matched on the identifier like tvOS
    /// `PlexDataStore.isContinueWatchingFamily`, never on the localized title.
    nonisolated var isContinueWatchingFamily: Bool {
        let id = id.lowercased()
        return id.contains("continue") || id.contains("inprogress") || id.contains("ondeck")
    }
}

/// Loads `HomeFeed` for the providers in play and keeps each server's last good answer. The
/// selected server loads first; the others fill in behind it. A server that fails is reported in
/// `Assembled.failures` and keeps its old rows; the servers that answered are shown regardless.
/// `load` throws only when there is no other server to show (the selected server alone failed).
@MainActor
final class HomeFeedLoader {
    private(set) var servers: [String: HomeFeed.ServerRows] = [:]
    private(set) var failures: [String: String] = [:]
    private(set) var isLoadingSecondary = false
    /// Called with the latest home as each server answers.
    var onChange: ((HomeFeed.Assembled) -> Void)?
    /// Called once the secondary servers have all answered.
    var onSecondaryFinished: (() -> Void)?

    private var selectedID: String?
    private var secondaryIDs: [String] = []
    private var generation = 0
    private var secondaryTask: Task<Void, Never>?

    /// Forgets every answer: a different server or profile.
    func reset() {
        generation += 1
        secondaryTask?.cancel()
        servers = [:]
        failures = [:]
        isLoadingSecondary = false
    }

    /// Awaits the secondary servers, for tests and callers that need them all.
    func finishSecondary() async {
        await secondaryTask?.value
    }

    func load(selected: (any MediaProvider)?, secondary: [any MediaProvider]) async throws {
        secondaryTask?.cancel()
        generation += 1
        let current = generation
        selectedID = selected?.id
        secondaryIDs = secondary.map(\.id)
        let present = Set(secondaryIDs + [selected?.id].compactMap { $0 })
        let gone = servers.keys.contains { !present.contains($0) } || failures.keys.contains { !present.contains($0) }
        servers = servers.filter { present.contains($0.key) }
        failures = failures.filter { present.contains($0.key) }
        isLoadingSecondary = !secondary.isEmpty
        if gone { publish() }

        let task = Task { [weak self] in
            await withTaskGroup(of: (String, Result<HomeFeed.ServerRows, Error>).self) { group in
                for provider in secondary {
                    group.addTask {
                        do { return (provider.id, .success(try await HomeFeed.fetch(provider, role: .secondary))) } catch {
                            return (provider.id, .failure(error))
                        }
                    }
                }
                for await (id, result) in group {
                    guard let self, self.generation == current else { return group.cancelAll() }
                    self.record(result, for: id)
                    self.publish()
                }
            }
            guard let self, self.generation == current else { return }
            self.isLoadingSecondary = false
            self.onSecondaryFinished?()
        }
        secondaryTask = task

        guard let selected else {
            await task.value
            if servers.isEmpty, let message = failures.values.first { throw HomeFeedError(message: message) }
            return
        }
        do {
            let rows = try await HomeFeed.fetch(selected, role: .selected)
            guard generation == current else { return }
            record(.success(rows), for: selected.id)
            publish()
        } catch {
            guard generation == current else { return }
            guard !secondary.isEmpty else {
                task.cancel()
                throw error
            }
            record(.failure(error), for: selected.id)
            publish()
        }
    }

    private func record(_ result: Result<HomeFeed.ServerRows, Error>, for id: String) {
        switch result {
        case .success(let rows):
            servers[id] = rows.keeping(servers[id])
            failures[id] = nil
        case .failure(let error):
            failures[id] = error.localizedDescription
        }
    }

    /// Waits for the selected server's first answer, or its failure, then publishes everything known.
    private func publish() {
        if let selectedID, servers[selectedID] == nil, failures[selectedID] == nil { return }
        var home = HomeFeed.assemble(selected: selectedID.flatMap { servers[$0] },
                                     others: secondaryIDs.compactMap { servers[$0] })
        home.failures = failures
        onChange?(home)
    }
}

/// A failure known only by its message, thrown when no server answered.
struct HomeFeedError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
