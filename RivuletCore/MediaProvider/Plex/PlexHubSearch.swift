// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

// Plex search through `/hubs/search`: one request answers titles, music, people, collections and
// genres, scored. The legacy `/search` caps each type at 15 (measured on PMS 1.43.5).

import Foundation

nonisolated enum PlexHubSearch {
    /// The hits, and the music results the tvOS page routes from their PlexMetadata.
    struct Answer: Sendable {
        var hits: SearchHits
        var music: [PlexMetadata]
    }

    /// Per hub. "christmas" fills 44 movies and 93 episodes on a large library.
    static let hubLimit = 100

    /// `visibleSections` nil keeps every library.
    static func search(_ query: String, serverURL: String, token: String, providerID: String,
                       visibleSections: Set<Int>?, network: PlexNetworkManager = .shared) async throws -> Answer {
        let hubs = try await fetch(query, serverURL: serverURL, token: token, network: network)
        let parsed = parse(hubs, query: query, visibleSections: visibleSections)
        let headers = network.plexHeaders(authToken: token)
        let map = { (meta: PlexMetadata) in
            PlexMediaMapper.item(meta, providerID: providerID, serverURL: serverURL, authToken: token)
        }
        let shelves = await withTaskGroup(of: (Int, SearchShelf?).self) { group in
            for (index, source) in parsed.shelves.enumerated() {
                group.addTask {
                    let metas = await shelfItems(source, serverURL: serverURL, headers: headers, network: network)
                    let items = metas.filter { isVisible($0.librarySectionID, in: visibleSections) }.map(map)
                    return (index, items.isEmpty ? nil : SearchShelf(kind: source.kind, name: source.name, items: items))
                }
            }
            return await group.reduce(into: [Int: SearchShelf]()) { $0[$1.0] = $1.1 }
        }
        let hits = SearchHits(
            titles: SearchRank.ranked(parsed.titles.map(map), query: query),
            people: parsed.people.map { personTag in
                person(personTag, serverURL: serverURL, token: token, providerID: providerID)
            },
            shelves: parsed.shelves.indices.compactMap { shelves[$0] })
        return Answer(hits: hits, music: parsed.music)
    }

    static func fetch(_ query: String, serverURL: String, token: String,
                      network: PlexNetworkManager = .shared) async throws -> [Hub] {
        guard var components = URLComponents(string: "\(serverURL)/hubs/search") else { throw PlexAPIError.invalidURL }
        components.queryItems = [URLQueryItem(name: "query", value: query),
                                 URLQueryItem(name: "limit", value: String(hubLimit)),
                                 URLQueryItem(name: "includeCollections", value: "1")]
        guard let url = components.url else { throw PlexAPIError.invalidURL }
        let container: Container = try await network.request(url, headers: network.plexHeaders(authToken: token))
        return container.MediaContainer.Hub ?? []
    }

    // MARK: - Response

    struct Container: Decodable, Sendable {
        let MediaContainer: Inner
        struct Inner: Decodable, Sendable { let Hub: [Hub]? }
    }

    struct Hub: Decodable, Sendable {
        let type: String?
        let metadata: [PlexMetadata]
        /// `reason` per metadata entry: nil for a match on the title itself, else what matched
        /// ("actor", "director", "originalTitle", "section", ...).
        let reasons: [String?]
        let tags: [Tag]

        private enum Keys: String, CodingKey { case type, Metadata, Directory }
        private struct Reason: Decodable { let reason: String? }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            type = try c.decodeIfPresent(String.self, forKey: .type)
            metadata = (try? c.decodeIfPresent([PlexMetadata].self, forKey: .Metadata)) ?? []
            let reasons = (try? c.decodeIfPresent([Reason].self, forKey: .Metadata)) ?? []
            self.reasons = reasons.count == metadata.count ? reasons.map(\.reason) : metadata.map { _ in nil }
            tags = (try? c.decodeIfPresent([Tag].self, forKey: .Directory)) ?? []
        }

        init(type: String, metadata: [PlexMetadata] = [], reasons: [String?]? = nil, tags: [Tag] = []) {
            self.type = type
            self.metadata = metadata
            self.reasons = reasons ?? metadata.map { _ in nil }
            self.tags = tags
        }
    }

    /// An actor, director or genre entry. `id` is the server-wide tag id.
    struct Tag: Decodable, Sendable, Hashable {
        let id: Int?
        let tag: String?
        let tagKey: String?
        let thumb: String?
        let count: Int?
        let librarySectionID: Int?
    }

    // MARK: - Parsing (pure)

    struct GenreTag: Sendable, Hashable {
        let section: Int
        let id: Int
    }

    struct ShelfSource: Sendable, Hashable {
        let kind: SearchShelf.Kind
        let name: String
        /// A collection's ratingKey, or a genre's tag id in each library it is in.
        let collectionKey: String?
        let genreTags: [GenreTag]
    }

    struct PersonTag: Sendable, Equatable {
        let tag: Tag
        /// "actor" or "director": the library filter its titles are listed by.
        let filter: String
    }

    struct Parsed: Sendable {
        var titles: [PlexMetadata] = []
        var music: [PlexMetadata] = []
        var people: [PersonTag] = []
        var shelves: [ShelfSource] = []
    }

    /// Reasons that still mean the title itself matched.
    private static let titleReasons: Set<String> = ["originalTitle", "section"]
    private static let titleTypes: Set<String> = ["movie", "show", "season", "episode"]
    private static let musicTypes: Set<String> = ["artist", "album", "track"]
    private static let peopleTypes = ["actor", "director"]

    static func parse(_ hubs: [Hub], query: String, visibleSections: Set<Int>?) -> Parsed {
        var parsed = Parsed()
        var seenKeys = Set<String>()
        for hub in hubs {
            for (meta, reason) in zip(hub.metadata, hub.reasons) {
                guard let type = meta.type, let key = meta.ratingKey,
                      isVisible(meta.librarySectionID, in: visibleSections) else { continue }
                if titleTypes.contains(type), reason.map(titleReasons.contains) ?? true, seenKeys.insert(key).inserted {
                    parsed.titles.append(meta)
                } else if musicTypes.contains(type), reason == nil, seenKeys.insert(key).inserted {
                    parsed.music.append(meta)
                }
            }
        }
        parsed.people = people(hubs, query: query, visibleSections: visibleSections)
        parsed.shelves = collections(hubs, query: query, visibleSections: visibleSections)
            + genres(hubs, query: query, visibleSections: visibleSections)
        return parsed
    }

    /// Actors then directors, each tag once (it repeats per library) and each name once (the
    /// entry credited on more titles wins), best match first.
    private static func people(_ hubs: [Hub], query: String, visibleSections: Set<Int>?) -> [PersonTag] {
        var byID: [Int: (person: PersonTag, order: Int)] = [:]
        var order = 0
        for filter in peopleTypes {
            for hub in hubs where hub.type == filter {
                for tag in hub.tags {
                    guard let id = tag.id, let name = tag.tag, !name.isEmpty,
                          isVisible(tag.librarySectionID, in: visibleSections), byID[id] == nil else { continue }
                    byID[id] = (PersonTag(tag: tag, filter: filter), order)
                    order += 1
                }
            }
        }
        var byName: [String: (person: PersonTag, order: Int)] = [:]
        for entry in byID.values.sorted(by: { $0.order < $1.order }) {
            let name = SearchRank.normalized(entry.person.tag.tag ?? "")
            if let kept = byName[name], (kept.person.tag.count ?? 0) >= (entry.person.tag.count ?? 0) { continue }
            byName[name] = entry
        }
        return byName.values
            .map { (entry: $0, rank: SearchRank.of($0.person.tag.tag ?? "", query: query)) }
            .sorted { a, b in
                if a.rank != b.rank { return a.rank > b.rank }
                let (ca, cb) = (a.entry.person.tag.count ?? 0, b.entry.person.tag.count ?? 0)
                return ca != cb ? ca > cb : a.entry.order < b.entry.order
            }
            .prefix(SearchHits.peopleLimit)
            .map(\.entry.person)
    }

    /// Collections named like a word of the query, with members, best match first.
    private static func collections(_ hubs: [Hub], query: String, visibleSections: Set<Int>?) -> [ShelfSource] {
        hubs.filter { $0.type == "collection" }
            .flatMap(\.metadata)
            .filter { ($0.childCount ?? 1) > 0 && isVisible($0.librarySectionID, in: visibleSections) }
            .compactMap { meta -> (ShelfSource, SearchRank)? in
                guard let key = meta.ratingKey, let title = meta.title else { return nil }
                let rank = SearchRank.of(title, query: query)
                guard rank >= .wordPrefix else { return nil }
                return (ShelfSource(kind: .collection, name: title, collectionKey: key, genreTags: []), rank)
            }
            .enumerated()
            .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
            .prefix(SearchHits.collectionLimit)
            .map(\.element.0)
    }

    /// Genres named like a word of the query, one shelf per name across libraries.
    private static func genres(_ hubs: [Hub], query: String, visibleSections: Set<Int>?) -> [ShelfSource] {
        var names: [String] = []
        var tags: [String: (display: String, tags: [GenreTag], rank: SearchRank)] = [:]
        for tag in hubs.filter({ $0.type == "genre" }).flatMap(\.tags) {
            guard let id = tag.id, let section = tag.librarySectionID, let name = tag.tag,
                  isVisible(section, in: visibleSections) else { continue }
            let rank = SearchRank.of(name, query: query)
            guard rank >= .wordPrefix else { continue }
            let key = SearchRank.normalized(name)
            if tags[key] == nil { names.append(key); tags[key] = (name, [], rank) }
            tags[key]?.tags.append(GenreTag(section: section, id: id))
        }
        return names.enumerated()
            .sorted { tags[$0.element]!.rank != tags[$1.element]!.rank
                ? tags[$0.element]!.rank > tags[$1.element]!.rank : $0.offset < $1.offset }
            .prefix(SearchHits.genreLimit)
            .compactMap { tags[$0.element].map { ShelfSource(kind: .genre, name: $0.display, collectionKey: nil, genreTags: $0.tags) } }
    }

    static func isVisible(_ section: Int?, in visible: Set<Int>?) -> Bool {
        guard let visible else { return true }
        return section.map(visible.contains) ?? true
    }

    // MARK: - Shelf items

    /// A collection's members, or a genre's titles best rated first, at most `shelfItemLimit`.
    /// A genre in several libraries alternates them. A failed request is an empty shelf.
    private static func shelfItems(_ source: ShelfSource, serverURL: String, headers: [String: String],
                                   network: PlexNetworkManager) async -> [PlexMetadata] {
        func get(_ path: String, _ query: [URLQueryItem]) async -> [PlexMetadata] {
            guard var components = URLComponents(string: "\(serverURL)\(path)") else { return [] }
            components.queryItems = query
            guard let url = components.url,
                  let container: PlexMediaContainerWrapper = try? await network.request(url, headers: headers)
            else { return [] }
            return container.MediaContainer.Metadata ?? []
        }
        let page = [URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
                    URLQueryItem(name: "X-Plex-Container-Size", value: String(SearchHits.shelfItemLimit))]
        if let key = source.collectionKey {
            return await get("/library/collections/\(key)/children", page)
        }
        let lists = await withTaskGroup(of: (Int, [PlexMetadata]).self) { group in
            for (index, tag) in source.genreTags.enumerated() {
                group.addTask {
                    (index, await get("/library/sections/\(tag.section)/all",
                                      [URLQueryItem(name: "genre", value: String(tag.id)),
                                       URLQueryItem(name: "sort", value: "audienceRating:desc")] + page))
                }
            }
            return await group.reduce(into: [Int: [PlexMetadata]]()) { $0[$1.0] = $1.1 }
        }
        return Array(SearchHits.interleaved(source.genreTags.indices.map { lists[$0] ?? [] }).prefix(SearchHits.shelfItemLimit))
    }

    // MARK: - People

    static func person(_ entry: PersonTag, serverURL: String, token: String, providerID: String) -> MediaPerson {
        let tag = entry.tag
        return MediaPerson(
            id: tag.id.map(String.init) ?? (tag.tag ?? ""),
            name: tag.tag ?? "",
            role: entry.filter == "director" ? String(localized: "Director") : String(localized: "Actor"),
            imageURL: imageURL(tag.thumb, serverURL: serverURL, token: token),
            tagKey: tag.tagKey,
            originActorId: tag.id.map(String.init),
            originFilter: entry.filter,
            providerID: providerID)
    }

    /// People thumbs are absolute (the metadata CDN) or a server path.
    static func imageURL(_ thumb: String?, serverURL: String, token: String) -> URL? {
        guard let thumb, !thumb.isEmpty else { return nil }
        if thumb.hasPrefix("http://") || thumb.hasPrefix("https://") { return URL(string: thumb) }
        return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(token)")
    }

    /// The server's tag id for a person found by name: the `filter` hub's entry with exactly that name.
    static func personTagID(named name: String, filter: String, serverURL: String, token: String,
                            network: PlexNetworkManager = .shared) async -> String? {
        let target = SearchRank.normalized(name)
        guard let hubs = try? await fetch(name, serverURL: serverURL, token: token, network: network) else { return nil }
        return hubs.filter { $0.type == filter }.flatMap(\.tags)
            .first { SearchRank.normalized($0.tag ?? "") == target }?.id.map(String.init)
    }
}
