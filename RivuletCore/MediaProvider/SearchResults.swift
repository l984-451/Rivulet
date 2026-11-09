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

    enum Section: Hashable, Sendable {
        case movies, shows
        case collection(String), genre(String)
        case people, episodes
    }

    struct Group: Equatable, Sendable, Identifiable {
        /// The server, set only while several are searched.
        let providerID: String?
        let section: Section
        let items: [MediaItem]
        var people: [MediaPerson] = []
        var id: String { "\(providerID ?? "")|\(section)" }
    }

    static let kinds: Set<MediaKind> = [.movie, .show, .season, .episode]

    /// Every server's hits, the selected server's first. A failing server loses only its own
    /// results; with every server failing the first error is thrown. Titles each once.
    static func search(_ query: String, providers: [any MediaProvider]) async throws -> SearchHits {
        let answers = await withTaskGroup(of: (Int, Result<SearchHits, Error>).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    do { return (index, .success(try await provider.searchHits(query, inLibraries: nil))) } catch { return (index, .failure(error)) }
                }
            }
            return await group.reduce(into: [Int: Result<SearchHits, Error>]()) { $0[$1.0] = $1.1 }
        }
        var failures: [Error] = []
        var merged = SearchHits()
        for index in providers.indices {
            switch answers[index] {
            case .success(let hits):
                merged.titles += hits.titles
                merged.people += hits.people
                merged.shelves += hits.shelves
            case .failure(let error): failures.append(error)
            case nil: break
            }
        }
        if failures.count == providers.count, let first = failures.first { throw first }
        var seen = Set<MediaItemRef>()
        merged.titles = merged.titles.filter { kinds.contains($0.kind) && seen.insert($0.ref).inserted }
        return merged
    }

    /// Per server: Movies, TV Shows, each collection and genre shelf, People, Episodes. With
    /// several servers each server's own, in `providerOrder`. People show only under All.
    static func groups(_ hits: SearchHits, scope: Scope, providerOrder: [String]) -> [Group] {
        let visible = hits.titles.filter { scope.includes($0.kind) }
        let people = scope == .all ? hits.people : []
        let shelves = hits.shelves.compactMap { shelf -> SearchShelf? in
            var shelf = shelf
            shelf.items = shelf.items.filter { scope.includes($0.kind) }
            return shelf.items.isEmpty ? nil : shelf
        }
        func owner(of shelf: SearchShelf) -> String? { shelf.items.first?.ref.providerID }
        let present = Set(visible.map(\.ref.providerID) + people.compactMap(\.providerID) + shelves.compactMap(owner))
        let multi = present.count > 1
        func section(_ kind: MediaKind) -> Section? {
            switch kind {
            case .movie: .movies
            case .show, .season: .shows
            case .episode: .episodes
            default: nil
            }
        }
        let servers: [String?] = multi
            ? providerOrder.filter(present.contains) + present.subtracting(providerOrder).sorted()
            : [nil]
        return servers.flatMap { server -> [Group] in
            func mine(_ id: String?) -> Bool { server == nil || id == server }
            func titles(_ wanted: Section) -> Group? {
                let items = visible.filter { section($0.kind) == wanted && mine($0.ref.providerID) }
                return items.isEmpty ? nil : Group(providerID: server, section: wanted, items: items)
            }
            let named = [titles(.movies), titles(.shows)].compactMap { $0 }
            let shelfGroups = distinct(shelves.filter { mine(owner(of: $0)) },
                                       excluding: Set(named.flatMap(\.items).map(\.ref)))
                .map { Group(providerID: server, section: $0.kind == .collection ? .collection($0.name) : .genre($0.name),
                             items: $0.items) }
            let serverPeople = people.filter { mine($0.providerID) }
            let peopleGroup = serverPeople.isEmpty ? [] : [Group(providerID: server, section: .people, items: [], people: serverPeople)]
            return named + shelfGroups + peopleGroup + [titles(.episodes)].compactMap { $0 }
        }
    }

    /// Each shelf without the titles already shown above it; an emptied shelf is dropped.
    static func distinct(_ shelves: [SearchShelf], excluding shown: Set<MediaItemRef>) -> [SearchShelf] {
        var seen = shown
        return shelves.compactMap { shelf in
            var shelf = shelf
            shelf.items = shelf.items.filter { seen.insert($0.ref).inserted }
            return shelf.items.isEmpty ? nil : shelf
        }
    }
}
