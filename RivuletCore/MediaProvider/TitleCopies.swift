// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The same movie or episode in the account's other Plex libraries and servers, with their
/// files: what the detail page's Versions button lists beside the item on screen.
///
/// Plex only: Jellyfin and Emby items get no copies (the guid and external-id matching here is
/// Plex's). The tvOS detail page is the only caller; the iOS and Mac detail pages list the
/// item's own versions only.
@MainActor
enum TitleCopies {
    /// Which server holds each plex:// guid. `PlexOwnedLookup.owners` outside tests.
    typealias Owners = @Sendable ([String], [PlexOwnedLookup.Server]) async -> PlexOwnedLookup.Owned

    /// The copies other than the subject, the library the subject itself was found in, and
    /// whether every request answered (only a complete result is cached).
    struct Result: Sendable {
        var copies: [VersionPicker.Copy] = []
        var library: String?
        var complete = true
    }

    struct Found: Sendable, Equatable {
        let ref: MediaItemRef
        let library: String?
    }

    /// Complete results by title and server set, for the session. A failed request leaves its
    /// title out, so the next open asks again.
    final class Cache {
        static let shared = Cache()
        private var results: [String: Result] = [:]

        func result(for key: String) -> Result? { results[key] }

        func store(_ result: Result, for key: String) {
            guard result.complete else { return }
            // A session opens far fewer titles than this; the cap only bounds a pathological one.
            if results.count >= 200 { results.removeAll() }
            results[key] = result
        }
    }

    /// A movie: its copies found by guid or confirmed external id, each with its files.
    static func movie(_ subject: MediaItem, guid: String, externalIDs: [String: String],
                      on servers: [PlexOwnedLookup.Server], registry: MediaProviderRegistry? = nil,
                      cache: Cache? = nil,
                      owners: @escaping Owners = PlexOwnedLookup.owners(of:on:)) async -> Result {
        let registry = registry ?? .shared, cache = cache ?? .shared
        let key = cacheKey(subject, servers)
        if let cached = cache.result(for: key) { return cached }
        let found = await titles(guid: guid, of: subject, externalIDs: externalIDs,
                                 on: servers, registry: registry, owners: owners)
        var result = Result(library: found.found.first { $0.ref == subject.ref }?.library, complete: found.complete)
        let others = found.found.filter { $0.ref != subject.ref }
        let copies = await inParallel(others) { found in
            await copy(found.ref, library: found.library, registry: registry)
        }
        for answer in copies {
            switch answer {
            case .some(.some(let copy)): result.copies.append(copy)
            case .some(.none): break
            case .none: result.complete = false
            }
        }
        cache.store(result, for: key)
        return result
    }

    /// An episode: `/library/all?guid=` matches only movies and shows, never an episode, so find
    /// the show on each server and walk to the same season and episode number there.
    static func episode(_ episode: MediaItem, of show: MediaItem, showDetail: MediaItemDetail,
                        on servers: [PlexOwnedLookup.Server], registry: MediaProviderRegistry? = nil,
                        cache: Cache? = nil,
                        owners: @escaping Owners = PlexOwnedLookup.owners(of:on:)) async -> Result {
        guard let seasonNumber = episode.seasonNumber, let episodeNumber = episode.episodeNumber else { return Result() }
        let registry = registry ?? .shared, cache = cache ?? .shared
        let key = cacheKey(episode, servers)
        if let cached = cache.result(for: key) { return cached }
        let found = await titles(guid: showDetail.plexGUID, of: show, externalIDs: showDetail.externalIDs,
                                 on: servers, registry: registry, owners: owners)
        var result = Result(library: found.found.first { $0.ref == show.ref }?.library, complete: found.complete)
        let others: [(found: Found, provider: any MediaProvider)] = found.found.compactMap { found in
            guard found.ref != show.ref, let provider = registry.provider(for: found.ref.providerID) else { return nil }
            return (found, provider)
        }
        let walked = await inParallel(others) { other -> MediaItemRef?? in
            do {
                let seasons = try await other.provider.children(of: other.found.ref)
                guard let season = seasons.first(where: { $0.seasonNumber == seasonNumber }) else { return .some(nil) }
                let episodes = try await other.provider.children(of: season.ref)
                return .some(episodes.first { $0.episodeNumber == episodeNumber }?.ref)
            } catch {
                return .none
            }
        }
        for (other, answer) in zip(others, walked) {
            switch answer {
            case .some(.some(let ref)):
                switch await copy(ref, library: other.found.library, registry: registry) {
                case .some(.some(let copy)): result.copies.append(copy)
                case .some(.none): break
                case .none: result.complete = false
                }
            case .some(.none): break
            case .none: result.complete = false
            }
        }
        cache.store(result, for: key)
        return result
    }

    /// Every server's copy of `title` (the shown one included), in `servers` order: by plex guid,
    /// then by a title search confirmed on a shared tmdb/tvdb/imdb id. A server is searched only
    /// when the guid lookup found nothing there but the shown item: a library on a legacy agent
    /// stores that agent's own guid, which a plex:// lookup cannot match, and it can sit beside
    /// a modern library on the same server.
    static func titles(guid: String?, of title: MediaItem, externalIDs: [String: String],
                       on servers: [PlexOwnedLookup.Server], registry: MediaProviderRegistry? = nil,
                       owners: @escaping Owners = PlexOwnedLookup.owners(of:on:)) async -> (found: [Found], complete: Bool) {
        let registry = registry ?? .shared
        var found: [Found] = []
        var complete = true
        if let guid {
            let owned = await owners([guid], servers)
            complete = owned.failed.isEmpty
            for match in owned.matches[guid] ?? [] {
                guard let ratingKey = match.item.ratingKey else { continue }
                found.append(Found(ref: MediaItemRef(providerID: match.server.id, itemID: ratingKey),
                                   library: match.item.librarySectionTitle))
            }
        }
        guard !externalIDs.isEmpty else { return (found, complete) }
        let known = Set(found.map(\.ref)).union([title.ref])
        let searched: [any MediaProvider] = servers.compactMap { server in
            let copyThere = found.contains { $0.ref.providerID == server.id && $0.ref != title.ref }
            return copyThere ? nil : registry.provider(for: server.id)
        }
        let kind = title.kind
        let name = title.title
        let answers = await inParallel(searched) { provider -> [Found]? in
            await search(provider, for: name, kind: kind, externalIDs: externalIDs, excluding: known)
        }
        for answer in answers {
            guard let answer else { complete = false; continue }
            found += answer
        }
        return (found, complete)
    }

    /// One server's same-titled items of the same kind that share an external id; nil when a
    /// request failed. A handful at most: the search ranks the exact title first.
    private nonisolated static func search(_ provider: any MediaProvider, for name: String, kind: MediaKind,
                                           externalIDs: [String: String],
                                           excluding known: Set<MediaItemRef>) async -> [Found]? {
        guard let results = try? await provider.search(name) else { return nil }
        let candidates = results.filter {
            $0.kind == kind && !known.contains($0.ref)
                && $0.title.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
        var found: [Found] = []
        for candidate in candidates.prefix(4) {
            guard let detail = try? await provider.fullDetail(for: candidate.ref) else { return nil }
            if PlexOwnedLookup.sharesExternalID(detail.externalIDs, externalIDs) {
                found.append(Found(ref: candidate.ref, library: nil))
            }
        }
        return found
    }

    /// The item at `ref` with its files, named by its server: nil when the request failed,
    /// `.some(nil)` when it has no files.
    static func copy(_ ref: MediaItemRef, library: String?,
                     registry: MediaProviderRegistry? = nil) async -> VersionPicker.Copy?? {
        guard let provider = (registry ?? .shared).provider(for: ref.providerID) else { return .some(nil) }
        guard let detail = try? await provider.fullDetail(for: ref) else { return .none }
        guard !detail.mediaSources.isEmpty else { return .some(nil) }
        return .some(.init(item: detail.item, server: provider.displayName, sources: detail.mediaSources,
                           library: library ?? detail.library))
    }

    private static func cacheKey(_ subject: MediaItem, _ servers: [PlexOwnedLookup.Server]) -> String {
        ([subject.ref.providerID + "/" + subject.ref.itemID] + servers.map(\.id)).joined(separator: "|")
    }

    /// `body` over every element at once; answers in `elements` order.
    private static func inParallel<Element: Sendable, Answer: Sendable>(
        _ elements: [Element], _ body: @escaping @Sendable (Element) async -> Answer
    ) async -> [Answer] {
        await withTaskGroup(of: (Int, Answer).self) { group in
            for (index, element) in elements.enumerated() {
                group.addTask { (index, await body(element)) }
            }
            var answers: [(Int, Answer)] = []
            for await answer in group { answers.append(answer) }
            return answers.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }
}
