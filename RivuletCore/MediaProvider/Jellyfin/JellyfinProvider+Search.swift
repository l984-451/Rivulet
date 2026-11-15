// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

// Search hits and people. `searchTerm` matches names only (never genres or tags), so people,
// collections and genres are separate name searches and their titles follow by id.

import Foundation

extension JellyfinProvider {
    func searchHits(_ query: String, inLibraries libraryIDs: [String]?) async throws -> SearchHits {
        async let people = searchPeople(query)
        async let collections = searchCollections(query)
        async let genres = searchGenres(query, libraryIDs: libraryIDs)
        let titles: [MediaItem]
        if let libraryIDs { titles = try await search(query, inLibraries: libraryIDs) } else { titles = try await search(query) }
        return SearchHits(titles: SearchRank.ranked(titles, query: query),
                          people: await people,
                          shelves: await collections + genres)
    }

    /// Anyone credited on the server whose name matches. A failed lookup is none.
    private func searchPeople(_ query: String) async -> [MediaPerson] {
        let result: JFQueryResult? = try? await client.get("Persons", [
            URLQueryItem(name: "searchTerm", value: query),
            URLQueryItem(name: "limit", value: "50")
        ])
        let people = (result?.items ?? []).compactMap { dto -> MediaPerson? in
            guard let id = dto.id, let name = dto.name, !name.isEmpty else { return nil }
            return MediaPerson(id: id, name: name, role: nil,
                               imageURL: JellyfinMediaMapper.imageURL(baseURL, itemID: id, type: "Primary",
                                                                     tag: dto.imageTags?["Primary"]),
                               providerID: self.id)
        }
        return SearchRank.matching(people, query: query, minimum: .contains, limit: SearchHits.peopleLimit) { $0.name }
    }

    /// Box sets named like a word of the query, with their members.
    private func searchCollections(_ query: String) async -> [SearchShelf] {
        let result: JFQueryResult? = try? await client.get("Items", [
            URLQueryItem(name: "searchTerm", value: query),
            URLQueryItem(name: "includeItemTypes", value: "BoxSet"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "limit", value: "20")
        ])
        let boxes = SearchRank.matching(result?.items ?? [], query: query, limit: SearchHits.collectionLimit) { $0.name ?? "" }
        return await shelves(boxes.compactMap { box in box.id.map { (box.name ?? "", $0) } }, kind: .collection) { boxID in
            [[URLQueryItem(name: "parentId", value: boxID)]]
        }
    }

    /// Movie and show genres named like a word of the query, each with its best rated titles,
    /// alternating the visible libraries when some are hidden.
    private func searchGenres(_ query: String, libraryIDs: [String]?) async -> [SearchShelf] {
        let result: JFQueryResult? = try? await client.get("Genres", [
            URLQueryItem(name: "searchTerm", value: query),
            URLQueryItem(name: "includeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "limit", value: "20")
        ])
        let genres = SearchRank.matching(result?.items ?? [], query: query, limit: SearchHits.genreLimit) { $0.name ?? "" }
        return await shelves(genres.compactMap { genre in genre.id.map { (genre.name ?? "", $0) } }, kind: .genre) { genreID in
            let base = [URLQueryItem(name: "genreIds", value: genreID),
                        URLQueryItem(name: "includeItemTypes", value: "Movie,Series"),
                        URLQueryItem(name: "recursive", value: "true"),
                        URLQueryItem(name: "sortBy", value: "CommunityRating,SortName"),
                        URLQueryItem(name: "sortOrder", value: "Descending,Ascending")]
            return libraryIDs.map { $0.map { base + [URLQueryItem(name: "parentId", value: $0)] } } ?? [base]
        }
    }

    /// One shelf per (name, id), its items from each listing `queries` gives, alternated. A shelf
    /// whose listings fail or come back empty is dropped.
    private func shelves(_ sources: [(name: String, id: String)], kind: SearchShelf.Kind,
                         queries: @escaping @Sendable (String) -> [[URLQueryItem]]) async -> [SearchShelf] {
        let limit = URLQueryItem(name: "limit", value: String(SearchHits.shelfItemLimit))
        let found = await withTaskGroup(of: (Int, [MediaItem]).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    var lists: [[MediaItem]] = []
                    for query in queries(source.id) {
                        let result: JFQueryResult? = try? await self.client.get("Items", query + [limit, Self.listFields])
                        lists.append(self.map(result?.items))
                    }
                    return (index, Array(SearchHits.interleaved(lists).prefix(SearchHits.shelfItemLimit)))
                }
            }
            return await group.reduce(into: [Int: [MediaItem]]()) { $0[$1.0] = $1.1 }
        }
        return sources.indices.compactMap { index in
            guard let items = found[index], !items.isEmpty else { return nil }
            return SearchShelf(kind: kind, name: sources[index].name, items: items)
        }
    }

    // MARK: - People

    func filmography(of person: MediaPerson) async throws -> [FilmographyEntry] {
        guard let personID = await personID(for: person) else { return [] }
        let result: JFQueryResult = try await client.get("Items", [
            URLQueryItem(name: "personIds", value: personID),
            URLQueryItem(name: "includeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "recursive", value: "true"),
            URLQueryItem(name: "sortBy", value: "ProductionYear,SortName"),
            URLQueryItem(name: "sortOrder", value: "Descending,Ascending"),
            Self.listFields
        ])
        return (result.items ?? []).map { dto in
            FilmographyEntry(item: JellyfinMediaMapper.item(dto, providerID: id, baseURL: baseURL), isOnServer: true,
                             tmdbId: dto.providerIds?["Tmdb"].flatMap { Int($0) })
        }
    }

    func biography(of person: MediaPerson) async -> String? {
        guard let personID = await personID(for: person),
              let dto: JFItem = try? await client.get("Items/\(personID)") else { return nil }
        return dto.overview
    }

    /// The person's id here: their own when they are this server's, else the person with exactly
    /// that name.
    private func personID(for person: MediaPerson) async -> String? {
        if person.providerID == id { return person.id }
        let result: JFQueryResult? = try? await client.get("Persons", [
            URLQueryItem(name: "searchTerm", value: person.name),
            URLQueryItem(name: "limit", value: "10")
        ])
        let target = SearchRank.normalized(person.name)
        return result?.items?.first { SearchRank.normalized($0.name ?? "") == target }?.id
    }
}
