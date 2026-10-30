// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

extension SiloProvider {
    func hubs() async throws -> [MediaHub] {
        let layout: SiloSectionLayout = try await client.get("home/layout")
        return try await sectionHubs(layout.sections, libraryID: nil)
    }

    func hubs(in library: MediaLibrary) async throws -> [MediaHub] {
        let layout: SiloSectionLayout = try await client.get("library/\(Self.pathComponent(library.id))/layout")
        return try await sectionHubs(layout.sections, libraryID: library.id)
    }

    private func sectionHubs(_ sections: [SiloSectionEntry], libraryID: String?) async throws -> [MediaHub] {
        // Layout order is profile-configured. Featured rows stay at their exact
        // position, rather than being promoted over earlier non-featured rows.
        var hubs: [MediaHub] = []
        for section in sections {
            let route = SiloHubRoute(scope: libraryID == nil ? "home" : "library", sectionId: section.id, libraryId: libraryID)
            let suffix = section.sectionType == "continue_watching" ? "continueWatching" : section.sectionType == "recently_added" ? "recentlyAdded" : section.id
            let identifier = try route.identifier(suffix: suffix)
            let result = try await hubItems(identifier, page: Page(offset: 0, limit: min(max(section.itemLimit, 1), 200)))
            var hub = MediaHub(id: identifier, providerID: id, title: section.title,
                               style: section.featured ? .hero : .shelf, items: result.items)
            hub.total = result.total
            hub.nextPage = result.nextPage
            hubs.append(hub)
        }
        return hubs
    }

    func hubItems(_ hubID: String, page: Page) async throws -> PagedResult<MediaItem> {
        let route = try SiloHubRoute.decode(hubID)
        guard let sectionID = route.sectionId else { throw MediaProviderError.notFound }
        var query = [URLQueryItem(name: "source", value: "section"),
                     URLQueryItem(name: "scope", value: route.scope),
                     URLQueryItem(name: "section_id", value: sectionID)]
        if let libraryID = route.libraryId { query.append(URLQueryItem(name: "library_id", value: libraryID)) }
        // Decode native cards with their exact action anchors in rail context.
        guard route.scope == "home" || route.scope == "library" else {
            return try await catalog(query, page: page)
        }
        let layoutPath = route.libraryId.map { "library/\(Self.pathComponent($0))/layout" } ?? "home/layout"
        let layout: SiloSectionLayout = try await client.get(layoutPath)
        guard let section = layout.sections.first(where: { $0.id == sectionID }),
              let rail = Self.dismissalRail(section.sectionType) else {
            return try await catalog(query, page: page)
        }
        let raw: SiloCatalogPage = try await getArtwork("catalog", query + [
            URLQueryItem(name: "limit", value: String(min(max(page.limit, 1), 200)))
        ] + (page.cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ??
             (page.offset > 0 ? [URLQueryItem(name: "seek", value: String(page.offset))] : [])))
        let owner = await MainActor.run { SiloSession.storedProvider() }
        guard owner?.id == id, owner?.authorityRevision == authorityRevision,
              client.profileID == profileID else { throw MediaProviderError.unauthorized }
        let items = raw.items.map { card -> MediaItem in
            var item = SiloMediaMapper.item(card, providerID: id, baseURL: client.baseURL, libraryID: route.libraryId)
            item.dismissalMetadata = dismissalMetadata(for: card, rail: rail)
            return item
        }
        return PagedResult(items: items, total: raw.total,
                           nextPage: try nextPage(raw.page, offset: page.offset + items.count, limit: page.limit))
    }

    func discoveryHubs() async throws -> [MediaHub]? {
        let result: SiloList<SiloRecommendationRow> = try await getArtwork("recommendations/discover")
        guard result.page?.hasMore != true, result.page?.nextCursor?.isEmpty != false else {
            throw MediaProviderError.backendSpecific(underlying: "Silo returned an incomplete recommendations feed.")
        }
        // Match the native For You feed: its inline cards are authoritative.
        // Separate section reads are browse operations, not feed dependencies.
        var hubs: [MediaHub] = []
        hubs.reserveCapacity(result.items.count)
        var personalizedCount = 0
        for (index, row) in result.items.enumerated() where !row.items.isEmpty {
            let identifier = try SiloHubRoute(scope: "recommendations").identifier(suffix: "\(index).\(row.type)")
            let items = map(row.items)
            var hub = MediaHub(id: identifier, providerID: id, title: row.title, style: .shelf, items: items)
            hub.total = items.count
            hub.canBrowse = false
            if row.title.caseInsensitiveCompare("For You") == .orderedSame {
                hubs.insert(hub, at: personalizedCount)
                personalizedCount += 1
            } else {
                hubs.append(hub)
            }
        }
        return hubs
    }

    func continueWatching(limit: Int) async throws -> [MediaItem] {
        try await homeSection(type: "continue_watching", libraryID: nil, limit: limit)?.items ?? []
    }

    func recentlyAdded(limit: Int) async throws -> [MediaItem] {
        if let section = try await homeSection(type: "recently_added", libraryID: nil, limit: limit) { return section.items }
        return try await catalog([URLQueryItem(name: "type", value: "video"), URLQueryItem(name: "sort", value: "-added_at")],
                                 page: Page(offset: 0, limit: limit)).items
    }

    func recentlyAddedHub(in library: MediaLibrary) async throws -> MediaHub? {
        try await homeSection(type: "recently_added", libraryID: library.id, limit: 20)
    }

    private func homeSection(type: String, libraryID: String?, limit: Int) async throws -> MediaHub? {
        guard limit > 0 else { return nil }
        let path = libraryID.map { "library/\(Self.pathComponent($0))/layout" } ?? "home/layout"
        let layout: SiloSectionLayout = try await client.get(path)
        guard let section = layout.sections.first(where: { $0.sectionType == type }) else { return nil }
        let route = SiloHubRoute(scope: libraryID == nil ? "home" : "library", sectionId: section.id, libraryId: libraryID)
        let suffix = type == "continue_watching" ? "continueWatching" : "recentlyAdded"
        let identifier = try route.identifier(suffix: suffix)
        let result = try await hubItems(identifier, page: Page(offset: 0, limit: min(limit, 200)))
        var hub = MediaHub(id: identifier, providerID: id, title: section.title,
                           style: section.featured ? .hero : .shelf, items: result.items)
        hub.total = result.total
        hub.nextPage = result.nextPage
        return hub
    }
}
