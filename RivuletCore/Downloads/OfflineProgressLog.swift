// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Progress that could not reach the server, replayed on the next connection.
nonisolated struct OfflineProgressLog: Codable, Sendable, Equatable {
    nonisolated struct Entry: Codable, Sendable, Equatable {
        var serverID: String
        var profileID: String?
        var ratingKey: String
        var offsetMs: Int
        var durationMs: Int?
        var watched: Bool
        var at: Date
    }

    var entries: [Entry] = []

    /// One entry per server, profile and item: the latest position, watched if ever watched.
    mutating func record(_ entry: Entry) {
        guard let i = entries.firstIndex(where: {
            $0.serverID == entry.serverID && $0.profileID == entry.profileID && $0.ratingKey == entry.ratingKey
        }) else {
            entries.append(entry)
            return
        }
        let old = entries[i]
        var merged = entry.at >= old.at ? entry : old
        merged.watched = old.watched || entry.watched
        entries[i] = merged
    }

    /// False when the server saw a view at or after this entry, so a later view is never overwritten.
    static func shouldReplay(_ entry: Entry, serverLastViewedAt: Date?) -> Bool {
        guard let serverLastViewedAt else { return true }
        return serverLastViewedAt < entry.at
    }

    /// Where a downloaded item resumes: the server's offset, unless an unsent entry is newer than its last view.
    static func resumeOffsetMs(serverOffsetMs: Int?, serverLastViewedAt: Date?, pending: Entry?) -> Int? {
        if let pending, shouldReplay(pending, serverLastViewedAt: serverLastViewedAt) { return pending.offsetMs }
        return serverOffsetMs
    }

    /// Sends `entries` in order and returns whether any was sent. A transport error stops the run
    /// and keeps the rest, a 5xx keeps that entry, and any other failure drops it.
    static func replay(
        _ entries: [Entry],
        isolation: isolated (any Actor)? = #isolation,
        serverLastViewedAt: (Entry) async throws -> Date?,
        send: (Entry) async throws -> Void,
        remove: (Entry) -> Void
    ) async -> Bool {
        var sent = false
        for entry in entries {
            do {
                if shouldReplay(entry, serverLastViewedAt: try await serverLastViewedAt(entry)) {
                    try await send(entry)
                    sent = true
                }
            } catch let error where isTransport(error) {
                return sent
            } catch PlexAPIError.httpError(let status, _) where status >= 500 {
                continue
            } catch {}
            remove(entry)
        }
        return sent
    }

    private static func isTransport(_ error: Error) -> Bool {
        if case PlexAPIError.networkError = error { return true }
        return error is URLError || error is CancellationError
    }

    static func load(from url: URL) -> OfflineProgressLog {
        DownloadsJSONFile.load(OfflineProgressLog.self, from: url) ?? OfflineProgressLog()
    }

    func save(to url: URL) throws {
        try DownloadsJSONFile.save(self, to: url)
    }
}
