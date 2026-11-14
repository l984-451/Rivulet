// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Which of several Plex servers owns each plex:// guid: one `/library/all?guid=a,b,…` per
/// server, all at once.
nonisolated enum PlexOwnedLookup {
    struct Server: Sendable, Equatable {
        let id: String
        let url: String
        let token: String
    }

    struct Match: Sendable {
        let server: Server
        let item: PlexMetadata
    }

    /// Every server's copy of each guid, in `servers` order, and the servers that failed to answer
    /// (their copies are unknown, not absent).
    struct Owned: Sendable {
        var matches: [String: [Match]] = [:]
        var failed: Set<String> = []
    }

    static func owners(of guids: [String], on servers: [Server]) async -> Owned {
        guard !guids.isEmpty, !servers.isEmpty else { return Owned() }
        let answers = await withTaskGroup(of: (Int, [PlexMetadata]?).self) { group in
            for (index, server) in servers.enumerated() {
                group.addTask {
                    let owned = try? await PlexNetworkManager.shared.findByGuids(
                        serverURL: server.url, authToken: server.token, guids: guids)
                    return (index, owned)
                }
            }
            return await group.reduce(into: [Int: [PlexMetadata]?]()) { $0[$1.0] = $1.1 }
        }
        let failed = Set(answers.filter { $0.value == nil }.map { servers[$0.key].id })
        return Owned(matches: copies(of: guids, servers: servers, answers: answers.compactMapValues { $0 }),
                     failed: failed)
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

    /// Two titles are the same when they share an external id ("tmdb", "tvdb", "imdb" keys).
    /// The fallback for a server whose library uses a legacy agent: it stores the agent's own
    /// guid, which a plex:// lookup cannot match.
    static func sharesExternalID(_ a: [String: String], _ b: [String: String]) -> Bool {
        a.contains { key, value in !value.isEmpty && b[key] == value }
    }
}
