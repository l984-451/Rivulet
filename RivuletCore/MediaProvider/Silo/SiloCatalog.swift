// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated private struct SiloCatalogFilters: Decodable, Sendable {
    let genres: [String]
    let studios: [String]
    let networks: [String]
    let countries: [String]
    let contentRatings: [String]
    let originalLanguages: [String]
    let authors: [String]
    let narrators: [String]
    let series: [String]
    let technical: Technical?

    nonisolated struct Technical: Decodable, Sendable {
        let resolutions: [String]
        let audioLanguages: [String]
        let subtitleLanguages: [String]
    }
}

nonisolated struct SiloCatalogRule: Encodable, Sendable {
    let field: String
    let op: String
    let value: Value

    nonisolated enum Value: Encodable, Sendable {
        case string(String), boolean(Bool), integer(Int)
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .string(let value): try container.encode(value)
            case .boolean(let value): try container.encode(value)
            case .integer(let value): try container.encode(value)
            }
        }
    }
}

nonisolated struct SiloCatalogGroup: Encodable, Sendable {
    let match: String
    let rules: [SiloCatalogRule]
}

nonisolated struct SiloCatalogQuery: Encodable, Sendable {
    let source = "query"
    let libraryId: String
    let type: String
    let sort: String
    let order: String
    let match = "all"
    let groups: [SiloCatalogGroup]
    let limit: Int
    let cursor: String?
    let seek: Int?

    func getParameters() throws -> [URLQueryItem] {
        let groupsData = try SiloJSON.encoder().encode(groups)
        var params = [URLQueryItem(name: "source", value: source), URLQueryItem(name: "library_id", value: libraryId),
                      URLQueryItem(name: "type", value: type),
                      URLQueryItem(name: "sort", value: order == "desc" ? "-\(sort)" : sort),
                      URLQueryItem(name: "match", value: match), URLQueryItem(name: "limit", value: String(limit)),
                      URLQueryItem(name: "groups", value: String(decoding: groupsData, as: UTF8.self))]
        if let cursor { params.append(URLQueryItem(name: "cursor", value: cursor)) }
        else if let seek { params.append(URLQueryItem(name: "seek", value: String(seek))) }
        return params
    }
}

/// Local state is scoped by provider (server and profile), authority-independent
/// account identity and library. Choices are rechecked against every live facet read.
nonisolated final class SiloCatalogFilterStore: Sendable {
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func key(providerID: String, accountID: String, profileID: String, libraryID: String) -> String {
        let components = [providerID, accountID, profileID, libraryID]
        return "silo.catalog.filters.v1." + components.map { Data($0.utf8).base64EncodedString() }.joined(separator: ".")
    }

    func load(providerID: String, accountID: String, profileID: String, libraryID: String) -> MediaCatalogFilter {
        let key = key(providerID: providerID, accountID: accountID, profileID: profileID, libraryID: libraryID)
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(MediaCatalogFilter.self, from: data) else {
            return MediaCatalogFilter(selectedChoices: [:])
        }
        return value
    }

    func save(_ filter: MediaCatalogFilter, providerID: String, accountID: String,
              profileID: String, libraryID: String) throws {
        let key = key(providerID: providerID, accountID: accountID, profileID: profileID, libraryID: libraryID)
        defaults.set(try JSONEncoder().encode(filter), forKey: key)
    }

    func reset(providerID: String, accountID: String, profileID: String, libraryID: String) {
        defaults.removeObject(forKey: key(providerID: providerID, accountID: accountID,
                                         profileID: profileID, libraryID: libraryID))
    }

    func reconcile(_ filter: MediaCatalogFilter, facets: [MediaCatalogFacet]) -> MediaCatalogFilter {
        let allowed = Dictionary(uniqueKeysWithValues: facets.map { ($0.id, Set($0.choices.map(\.id))) })
        return MediaCatalogFilter(selectedChoices: Dictionary(uniqueKeysWithValues: filter.selectedChoices.compactMap { key, values in
            guard let choices = allowed[key] else { return nil }
            let valid = Array(Set(values).intersection(choices)).sorted()
            return valid.isEmpty ? nil : (key, valid)
        }))
    }
}

extension SiloProvider {
    private func requireCatalogOwner() async throws {
        try Task.checkCancellation()
        let current = await MainActor.run { SiloSession.storedProvider() }
        guard current?.id == id, current?.authorityRevision == authorityRevision,
              client.profileID == profileID else { throw MediaProviderError.unauthorized }
    }

    private func requireCatalogLibrary(_ library: MediaLibrary) async throws {
        try await requireCatalogOwner()
        guard library.providerID == id, !library.id.isEmpty,
              try await libraries().contains(where: { $0.id == library.id }) else {
            throw MediaProviderError.unauthorized
        }
        try await requireCatalogOwner()
    }

    private func catalogAccountID() async throws -> String {
        try await requireCatalogOwner()
        let account = await MainActor.run { SiloSession.account }
        guard let account, account.providerID == id, !account.userID.isEmpty else {
            throw MediaProviderError.unauthorized
        }
        return account.userID
    }

    func catalogFacets(in library: MediaLibrary) async throws -> [MediaCatalogFacet]? {
        try await requireCatalogLibrary(library)
        let type = library.kind == .movies ? "movie" : library.kind == .shows ? "series" : "video"
        let wire: SiloCatalogFilters = try await client.get("catalog/filters", [
            URLQueryItem(name: "library_id", value: library.id), URLQueryItem(name: "type", value: type)
        ])
        try await requireCatalogOwner()
        func facet(_ id: String, _ title: String, _ values: [String]) -> MediaCatalogFacet {
            MediaCatalogFacet(id: id, title: title, choices: values.map { .init(id: $0, title: $0, count: nil) })
        }
        let decade = Calendar.current.component(.year, from: Date()) / 10 * 10
        let decades = stride(from: decade, through: 1900, by: -10).map(String.init)
        return [
            facet("genre", "Genre", wire.genres), facet("decade", "Decade", decades),
            facet("watch_status", "Watch Status", ["unwatched", "watched", "in_progress", "favorited", "watchlist"]),
            facet("content_rating", "Content Rating", wire.contentRatings),
            facet("resolution", "Resolution", wire.technical?.resolutions ?? []),
            facet("dynamic_range", "Dynamic Range", ["hdr", "dolby_vision"]),
            facet("studio", "Studio", wire.studios), facet("network", "Network", wire.networks),
            facet("country", "Country", wire.countries),
            facet("audio_language", "Audio Language", wire.technical?.audioLanguages ?? []),
            facet("subtitle_language", "Subtitle Language", wire.technical?.subtitleLanguages ?? []),
            facet("original_language", "Original Language", wire.originalLanguages),
            facet("author", "Author", wire.authors), facet("narrator", "Narrator", wire.narrators),
            facet("series", "Series", wire.series)
        ].filter { !$0.choices.isEmpty }
    }

    func catalogItems(in library: MediaLibrary, filter: MediaCatalogFilter, sort: SortOption,
                      page: Page) async throws -> PagedResult<MediaItem> {
        let facets = try await catalogFacets(in: library) ?? []
        let valid = SiloCatalogFilterStore().reconcile(filter, facets: facets)
        guard valid == filter else { throw MediaProviderError.backendSpecific(underlying: "Catalog filter choices changed; reload facets.") }
        let groups = valid.selectedChoices.keys.sorted().compactMap { id -> SiloCatalogGroup? in
            guard let values = valid.selectedChoices[id], !values.isEmpty else { return nil }
            let rules: [SiloCatalogRule] = values.sorted().compactMap { value in
                switch id {
                case "decade":
                    guard let start = Int(value) else { return nil }
                    return .init(field: "decade", op: "is", value: .integer(start))
                case "dynamic_range": return .init(field: value, op: "is", value: .boolean(true))
                case "watch_status":
                    let field = ["unwatched": "watched", "watched": "watched", "in_progress": "in_progress",
                                 "favorited": "favorited", "watchlist": "in_watchlist"][value] ?? ""
                    return .init(field: field, op: "is", value: .boolean(value != "unwatched"))
                default: return .init(field: id, op: id == "genre" ? "contains" : "is", value: .string(value))
                }
            }
            return SiloCatalogGroup(match: "any", rules: rules)
        }
        let signedSort = Self.sort(sort)
        let query = SiloCatalogQuery(libraryId: library.id,
                                     type: library.kind == .movies ? "movie" : library.kind == .shows ? "series" : "video",
                                     sort: String(signedSort.drop(while: { $0 == "-" })),
                                     order: signedSort.hasPrefix("-") ? "desc" : "asc", groups: groups,
                                     limit: min(max(page.limit, 1), 100), cursor: page.cursor,
                                     seek: page.cursor == nil && page.offset > 0 ? page.offset : nil)
        let groupsData = try SiloJSON.encoder().encode(groups)
        let result: SiloCatalogPage
        if groupsData.count > 32_768 {
            result = try await client.post("catalog/query", body: query)
        } else {
            result = try await getArtwork("catalog", query.getParameters())
        }
        try await requireCatalogOwner()
        return PagedResult(items: map(result.items, libraryID: library.id), total: result.total,
                           nextPage: try nextPage(result.page, offset: page.offset + result.items.count, limit: page.limit))
    }

    func loadCatalogFilter(in library: MediaLibrary, store: SiloCatalogFilterStore = .init()) async throws -> MediaCatalogFilter {
        let facets = try await catalogFacets(in: library) ?? []
        let accountID = try await catalogAccountID()
        let saved = store.load(providerID: id, accountID: accountID, profileID: profileID, libraryID: library.id)
        let current = store.reconcile(saved, facets: facets)
        if current != saved { try store.save(current, providerID: id, accountID: accountID, profileID: profileID, libraryID: library.id) }
        return current
    }

    func saveCatalogFilter(_ filter: MediaCatalogFilter, in library: MediaLibrary,
                           store: SiloCatalogFilterStore = .init()) async throws {
        let facets = try await catalogFacets(in: library) ?? []
        guard store.reconcile(filter, facets: facets) == filter else { throw MediaProviderError.unauthorized }
        let accountID = try await catalogAccountID()
        try store.save(filter, providerID: id, accountID: accountID, profileID: profileID, libraryID: library.id)
    }

    func resetCatalogFilter(in library: MediaLibrary, store: SiloCatalogFilterStore = .init()) async throws {
        try await requireCatalogLibrary(library)
        let accountID = try await catalogAccountID()
        store.reset(providerID: id, accountID: accountID, profileID: profileID, libraryID: library.id)
    }
}
