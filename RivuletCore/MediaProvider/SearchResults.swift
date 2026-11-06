// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SearchResults.swift
//  Rivulet
//
//  Search over every server at once and the sections its results fall into.
//

import Foundation

nonisolated enum SearchResults {
    enum Scope: CaseIterable, Sendable {
        case all, movies, shows

        func includes(_ kind: MediaKind) -> Bool {
            switch self {
            case .all: true
            case .movies: kind == .movie
            case .shows: kind != .movie
            }
        }
    }

    enum Section: Int, Sendable { case movies, shows, episodes }

    struct Group: Equatable, Sendable, Identifiable {
        /// The server, set only while several are searched.
        let providerID: String?
        let section: Section
        let items: [MediaItem]
        var id: String { "\(providerID ?? "")|\(section.rawValue)" }
    }

    static let kinds: Set<MediaKind> = [.movie, .show, .season, .episode]

    /// Every server's matches, the selected server's first. A failing server loses only its own
    /// results; with every server failing the first error is thrown. Titles only, each once.
    static func search(_ query: String, providers: [any MediaProvider]) async throws -> [MediaItem] {
        let answers = await withTaskGroup(of: (Int, Result<[MediaItem], Error>).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    do { return (index, .success(try await provider.search(query))) } catch { return (index, .failure(error)) }
                }
            }
            return await group.reduce(into: [Int: Result<[MediaItem], Error>]()) { $0[$1.0] = $1.1 }
        }
        var failures: [Error] = []
        var results: [MediaItem] = []
        for index in providers.indices {
            switch answers[index] {
            case .success(let items): results += items
            case .failure(let error): failures.append(error)
            case nil: break
            }
        }
        if failures.count == providers.count, let first = failures.first { throw first }
        var seen = Set<MediaItemRef>()
        return results.filter { kinds.contains($0.kind) && seen.insert($0.ref).inserted }
    }

    /// Movies, TV Shows and Episodes; with several servers each server's own, in `providerOrder`.
    static func groups(_ results: [MediaItem], scope: Scope, providerOrder: [String]) -> [Group] {
        let visible = results.filter { scope.includes($0.kind) }
        let multi = Set(results.map(\.ref.providerID)).count > 1
        func section(_ kind: MediaKind) -> Section? {
            switch kind {
            case .movie: .movies
            case .show, .season: .shows
            case .episode: .episodes
            default: nil
            }
        }
        let servers: [String?] = multi
            ? providerOrder.filter { id in visible.contains { $0.ref.providerID == id } }
                + Set(visible.map(\.ref.providerID)).subtracting(providerOrder).sorted()
            : [nil]
        return servers.flatMap { server in
            [Section.movies, .shows, .episodes].compactMap { wanted in
                let items = visible.filter { section($0.kind) == wanted && (server == nil || $0.ref.providerID == server) }
                return items.isEmpty ? nil : Group(providerID: server, section: wanted, items: items)
            }
        }
    }
}
