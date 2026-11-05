// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Which of several Plex servers owns each plex:// guid, and which copy to open: one
/// `/library/all?guid=a,b,…` per server, all at once, then the best-quality copy wins.
enum PlexOwnedLookup {
    struct Server: Sendable, Equatable {
        let id: String
        let url: String
        let token: String
    }

    struct Match: Sendable {
        let server: Server
        let item: PlexMetadata
    }

    /// Every server's copy of each guid, in `servers` order.
    static func owners(of guids: [String], on servers: [Server]) async -> [String: [Match]] {
        guard !guids.isEmpty, !servers.isEmpty else { return [:] }
        let answers = await withTaskGroup(of: (Int, [PlexMetadata]).self) { group in
            for (index, server) in servers.enumerated() {
                group.addTask {
                    // A server that fails to answer owns nothing here.
                    let owned = (try? await PlexNetworkManager.shared.findByGuids(
                        serverURL: server.url, authToken: server.token, guids: guids)) ?? []
                    return (index, owned)
                }
            }
            return await group.reduce(into: [Int: [PlexMetadata]]()) { $0[$1.0] = $1.1 }
        }
        return copies(of: guids, servers: servers, answers: answers)
    }

    /// Pure merge of each server's answer, keyed by its index in `servers`.
    static func copies(of guids: [String], servers: [Server],
                       answers: [Int: [PlexMetadata]]) -> [String: [Match]] {
        let wanted = Set(guids)
        var found: [String: [Match]] = [:]
        for (index, server) in servers.enumerated() {
            var seen = Set<String>()
            for item in answers[index] ?? [] {
                guard let guid = item.guid, wanted.contains(guid), seen.insert(guid).inserted else { continue }
                found[guid, default: []].append(Match(server: server, item: item))
            }
        }
        return found
    }

    /// The copy with the best file by `VersionRanking` (resolution, dynamic range, bitrate).
    /// Ties, and items with no file info (a show), go to the earliest candidate.
    static func best(_ candidates: [Match]) -> Match? {
        var winner: (match: Match, key: VersionRanking.Key?)?
        for candidate in candidates {
            let key = bestFile(candidate.item)
            guard let current = winner else { winner = (candidate, key); continue }
            if let key, current.key.map({ key > $0 }) ?? true { winner = (candidate, key) }
        }
        return winner?.match
    }

    /// The other server's copy to open instead of the selected server's: the best of all of them,
    /// when that is not the selected one. Ties stay on the selected server.
    static func betterElsewhere(selected: Match?, elsewhere: [Match]) -> Match? {
        guard let winner = best((selected.map { [$0] } ?? []) + elsewhere),
              winner.server != selected?.server else { return nil }
        return winner
    }

    /// Two titles are the same when they share an external id ("tmdb", "tvdb", "imdb" keys).
    /// The fallback for a server whose library uses a legacy agent: it stores the agent's own
    /// guid, which a plex:// lookup cannot match.
    static func sharesExternalID(_ a: [String: String], _ b: [String: String]) -> Bool {
        a.contains { key, value in !value.isEmpty && b[key] == value }
    }

    private static func bestFile(_ item: PlexMetadata) -> VersionRanking.Key? {
        item.Media?.map(VersionRanking.key).max()
    }
}
