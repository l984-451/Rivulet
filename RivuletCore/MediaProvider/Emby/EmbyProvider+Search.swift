// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

// Search hits and people. `SearchTerm` matches the start of a word in a name only, so people,
// collections and genres are separate name searches and their titles follow by id.

import Foundation

extension EmbyProvider {
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

    private var user: URLQueryItem { URLQueryItem(name: "UserId", value: userID) }

    /// Anyone credited on the server whose name matches. A failed lookup is none.
    private func searchPeople(_ query: String) async -> [MediaPerson] {
        let result: EmbyQueryResult? = try? await client.get("Persons", [
            user, URLQueryItem(name: "SearchTerm", value: query), URLQueryItem(name: "Limit", value: "50")
        ])
        let people = (result?.items ?? []).compactMap { dto -> MediaPerson? in
            guard !dto.name.isEmpty else { return nil }
            return MediaPerson(id: dto.id.value, name: dto.name, role: nil,
                               imageURL: EmbyMediaMapper.imageURL(baseURL, itemID: dto.id, type: "Primary",
                                                                  tag: dto.imageTags?["Primary"]),
                               providerID: self.id)
        }
        return SearchRank.matching(people, query: query, minimum: .contains, limit: SearchHits.peopleLimit) { $0.name }
    }

    /// Box sets named like a word of the query, with their members.
    private func searchCollections(_ query: String) async -> [SearchShelf] {
        let result: EmbyQueryResult? = try? await client.get(itemsPath, [
            URLQueryItem(name: "SearchTerm", value: query),
            URLQueryItem(name: "IncludeItemTypes", value: "BoxSet"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: "20")
        ])
        let boxes = SearchRank.matching(result?.items ?? [], query: query, limit: SearchHits.collectionLimit) { $0.name }
        return await shelves(boxes.map { ($0.name, $0.id.value) }, kind: .collection) { boxID in
            [[URLQueryItem(name: "ParentId", value: boxID)]]
        }
    }

    /// Movie and show genres named like a word of the query, each with its best rated titles,
    /// alternating the visible libraries when some are hidden.
    private func searchGenres(_ query: String, libraryIDs: [String]?) async -> [SearchShelf] {
        let result: EmbyNamedResult? = try? await client.get("Genres", [
            user, URLQueryItem(name: "SearchTerm", value: query),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Limit", value: "20")
        ])
        let rows = (result?.items ?? []).compactMap { row in row.id.map { (name: row.name ?? "", id: $0.value) } }
        let genres = SearchRank.matching(rows, query: query, limit: SearchHits.genreLimit) { $0.name }
        return await shelves(genres, kind: .genre) { genreID in
            let base = [URLQueryItem(name: "GenreIds", value: genreID),
                        URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
                        URLQueryItem(name: "Recursive", value: "true"),
                        URLQueryItem(name: "SortBy", value: "CommunityRating,SortName"),
                        URLQueryItem(name: "SortOrder", value: "Descending")]
            return libraryIDs.map { $0.map { base + [URLQueryItem(name: "ParentId", value: $0)] } } ?? [base]
        }
    }

    /// One shelf per (name, id), its items from each listing `queries` gives, alternated. A shelf
    /// whose listings fail or come back empty is dropped.
    private func shelves(_ sources: [(name: String, id: String)], kind: SearchShelf.Kind,
                         queries: @escaping @Sendable (String) -> [[URLQueryItem]]) async -> [SearchShelf] {
        let limit = URLQueryItem(name: "Limit", value: String(SearchHits.shelfItemLimit))
        let found = await withTaskGroup(of: (Int, [MediaItem]).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    var lists: [[MediaItem]] = []
                    for query in queries(source.id) {
                        let result: EmbyQueryResult? = try? await self.client.get(self.itemsPath, query + [limit, Self.listFields])
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
        let result: EmbyQueryResult = try await client.get(itemsPath, [
            URLQueryItem(name: "PersonIds", value: personID),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "ProductionYear,SortName"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            Self.listFields
        ])
        return (result.items ?? []).map { dto in
            FilmographyEntry(item: EmbyMediaMapper.item(dto, providerID: id, baseURL: baseURL), isOnServer: true,
                             tmdbId: dto.providerID("Tmdb").flatMap { Int($0) })
        }
    }

    func biography(of person: MediaPerson) async -> String? {
        guard let personID = await personID(for: person),
              let dto: EmbyItem = try? await client.get("\(itemsPath)/\(personID)") else { return nil }
        return dto.overview
    }

    /// The person's id here: their own when they are this server's, else the person with exactly
    /// that name.
    private func personID(for person: MediaPerson) async -> String? {
        if person.providerID == id { return person.id }
        let result: EmbyQueryResult? = try? await client.get("Persons", [
            user, URLQueryItem(name: "SearchTerm", value: person.name), URLQueryItem(name: "Limit", value: "10")
        ])
        let target = SearchRank.normalized(person.name)
        return result?.items?.first { SearchRank.normalized($0.name) == target }?.id.value
    }
}
