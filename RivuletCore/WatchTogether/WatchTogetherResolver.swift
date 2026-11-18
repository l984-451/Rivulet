// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WatchTogetherResolver.swift
//  Rivulet
//
//  Finds this user's copies of the room's title on every server they reach, so
//  people on different servers, Plex or Jellyfin, can watch together. Each file
//  version is a candidate; the SDK picks by duration.
//

import Foundation
import OpenWatchParty

@MainActor
enum WatchTogetherResolver {
    /// Selected Plex server first, so the likeliest copy is tried first.
    static var providers: [any MediaProvider] {
        let registry = MediaProviderRegistry.shared
        return [registry.plexProvider].compactMap { $0 } + registry.secondaryProviders
    }

    static func candidates(for media: Media) async throws -> [Candidate<WatchTogetherItem>] {
        let details = await withTaskGroup(of: (Int, [MediaItemDetail]).self) { group in
            for (index, provider) in providers.enumerated() {
                group.addTask {
                    (index, await WatchTogetherSession.within(.seconds(12)) { try? await copies(of: media, on: provider) } ?? [])
                }
            }
            var found: [(Int, [MediaItemDetail])] = []
            for await result in group { found.append(result) }
            return found.sorted { $0.0 < $1.0 }.flatMap(\.1)
        }
        try Task.checkCancellation()
        var seen = Set<WatchTogetherItem>()
        var found: [Candidate<WatchTogetherItem>] = []
        for detail in details {
            for source in detail.mediaSources {
                let item = WatchTogetherItem(providerID: detail.item.ref.providerID, itemID: detail.item.ref.itemID,
                                             sourceID: source.id)
                guard seen.insert(item).inserted else { continue }
                found.append(Candidate(
                    id: "\(item.providerID):\(item.itemID):\(source.id)", ref: item,
                    durationMs: source.duration > 0 ? Int64(source.duration * 1000) : nil,
                    sizeBytes: source.fileSize))
            }
        }
        return found
    }

    /// One server's copies: the descriptor's own shortcut, its Plex guid, then a title search.
    private static func copies(of media: Media, on provider: any MediaProvider) async throws -> [MediaItemDetail] {
        func detail(_ itemID: String) async -> MediaItemDetail? {
            try? await provider.fullDetail(for: MediaItemRef(providerID: provider.id, itemID: itemID))
        }
        let serverKey = await serverKey(for: provider)
        if let shortcut = WatchTogetherSession.shortcut(in: media), shortcut.server == serverKey,
           let exact = await detail(shortcut.item) {
            return [exact]
        }
        if let plex = provider as? PlexProvider, let guid = media.ids["plex"],
           let key = try? await PlexNetworkManager.shared.findByGuid(
               serverURL: plex.serverURL, authToken: plex.authToken, guid: guid)?.ratingKey,
           let exact = await detail(key) {
            return [exact]
        }
        switch media.kind {
        case .movie:
            let hits = try await provider.search(media.title).filter { $0.kind == .movie }
            var details: [MediaItemDetail] = []
            for hit in hits where WatchTogetherSession.foldedTitle(hit.title) == WatchTogetherSession.foldedTitle(media.title) {
                guard let full = await detail(hit.ref.itemID),
                      WatchTogetherSession.sameTitle(media.title, year: media.year.map(Int.init), ids: media.ids,
                                                     as: hit.title, year: hit.year, ids: full.externalIDs)
                else { continue }
                details.append(full)
            }
            return details
        case .episode:
            guard let series = media.series, let season = media.season, let episode = media.episode else { return [] }
            let shows = try await provider.search(series.title).filter {
                $0.kind == .show && WatchTogetherSession.sameTitle(
                    series.title, year: series.year.map(Int.init), ids: [:], as: $0.title, year: $0.year, ids: [:])
            }
            var details: [MediaItemDetail] = []
            for show in shows {
                let episodes = (try? await provider.allEpisodes(of: show.ref)) ?? []
                for hit in episodes where hit.seasonNumber.map(Int64.init) == season
                    && hit.episodeNumber.map(Int64.init) == episode {
                    if let full = await detail(hit.ref.itemID) { details.append(full) }
                }
            }
            return details
        case .video:
            return []
        }
    }

    /// The room's descriptor for `ref`. Plex reads full metadata, since hub items miss the ids.
    static func describe(_ ref: MediaItemRef, durationMs: Int64) async throws -> Media {
        guard let provider = MediaProviderRegistry.shared.provider(for: ref.providerID) else {
            throw PartyError(.invalidMessage)
        }
        let server = await serverKey(for: provider)
        if let plex = provider as? PlexProvider {
            let network = PlexNetworkManager.shared
            let full = try await network.getFullMetadata(
                serverURL: plex.serverURL, authToken: plex.authToken, ratingKey: ref.itemID)
            var show: PlexMetadata?
            if full.type == "episode", let key = full.grandparentRatingKey {
                show = try? await network.getFullMetadata(serverURL: plex.serverURL, authToken: plex.authToken, ratingKey: key)
            }
            return WatchTogetherSession.media(plex: full, show: show, durationMs: durationMs, server: server)
        }
        let detail = try await provider.fullDetail(for: ref)
        var show: MediaItemDetail?
        if let showRef = detail.item.grandparentRef { show = try? await provider.fullDetail(for: showRef) }
        let item = detail.item
        return Media(
            kind: item.kind == .movie ? .movie : item.kind == .episode ? .episode : .video,
            title: item.title.isEmpty ? String(localized: "Untitled") : item.title,
            durationMs: durationMs,
            year: item.year.map(Int64.init),
            ids: detail.externalIDs,
            series: item.kind == .episode
                ? Series(title: item.seriesTitle ?? show?.item.title ?? item.title,
                         year: show?.item.year.map(Int64.init), ids: show?.externalIDs ?? [:])
                : nil,
            season: item.seasonNumber.map(Int64.init),
            episode: item.episodeNumber.map(Int64.init),
            ext: WatchTogetherSession.ext(server: server, item: item.ref.itemID))
    }

    /// What a descriptor's shortcut calls this server. Stable, unlike a restored
    /// session's provider id, which can be a hash of the URL.
    static func serverKey(for provider: any MediaProvider) async -> String {
        guard let plex = provider as? PlexProvider,
              let machineID = try? await PlexNetworkManager.shared.getMachineIdentifier(
                  serverURL: plex.serverURL, authToken: plex.authToken)
        else { return provider.id }
        return "plex:\(machineID)"
    }
}
