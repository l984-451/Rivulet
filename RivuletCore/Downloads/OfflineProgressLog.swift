// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Progress that could not reach the server, replayed on the next connection.
nonisolated struct OfflineProgressLog: Codable, Sendable, Equatable {
    nonisolated struct Key: Hashable, Sendable {
        let providerID: String
        let profileID: String?
        let accountID: String?
        let itemID: String

        func entry(offsetMs: Int, durationMs: Int?, watched: Bool, at: Date) -> Entry {
            Entry(providerID: providerID, profileID: profileID, accountID: accountID, itemID: itemID,
                  offsetMs: offsetMs, durationMs: durationMs, watched: watched, at: at)
        }
    }

    nonisolated struct Entry: Codable, Sendable, Hashable {
        var key: Key { Key(providerID: providerID, profileID: profileID, accountID: accountID, itemID: itemID) }

        /// The server, as `DownloadRecord.providerID` names it.
        var providerID: String
        var profileID: String?
        var accountID: String? = nil
        var itemID: String
        var sourceID: String? = nil
        var offsetMs: Int
        var durationMs: Int?
        var watched: Bool
        var at: Date

        init(providerID: String, profileID: String?, accountID: String? = nil, itemID: String, sourceID: String? = nil,
             offsetMs: Int, durationMs: Int?, watched: Bool, at: Date) {
            self.providerID = providerID
            self.profileID = profileID
            self.accountID = accountID
            self.itemID = itemID
            self.sourceID = sourceID
            self.offsetMs = offsetMs
            self.durationMs = durationMs
            self.watched = watched
            self.at = at
        }

        private enum CodingKeys: String, CodingKey {
            case providerID, profileID, accountID, itemID, sourceID, offsetMs, durationMs, watched, at
            // The Plex-only build's names, read but never written.
            case serverID, ratingKey
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            if let id = try c.decodeIfPresent(String.self, forKey: .providerID) {
                providerID = id
            } else {
                let machineID = try c.decode(String.self, forKey: .serverID)
                providerID = DownloadIdentity.plexProviderID(machineID: machineID.isEmpty ? nil : machineID)
            }
            itemID = try c.decodeIfPresent(String.self, forKey: .itemID) ?? c.decode(String.self, forKey: .ratingKey)
            profileID = try c.decodeIfPresent(String.self, forKey: .profileID)
            accountID = try c.decodeIfPresent(String.self, forKey: .accountID)
            sourceID = try c.decodeIfPresent(String.self, forKey: .sourceID)
            offsetMs = try c.decode(Int.self, forKey: .offsetMs)
            durationMs = try c.decodeIfPresent(Int.self, forKey: .durationMs)
            watched = try c.decode(Bool.self, forKey: .watched)
            at = try c.decode(Date.self, forKey: .at)
        }

        static func previousBuildServerID(_ providerID: String) -> String {
            providerID.hasPrefix("plex:") ? DownloadIdentity.plexMachineID(of: providerID) ?? "" : providerID
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            // The previous build reads this file too: it needs these two, and never matches a non-Plex server id.
            try c.encode(Self.previousBuildServerID(providerID), forKey: .serverID)
            try c.encode(itemID, forKey: .ratingKey)
            try c.encode(providerID, forKey: .providerID)
            try c.encodeIfPresent(profileID, forKey: .profileID)
            try c.encodeIfPresent(accountID, forKey: .accountID)
            try c.encode(itemID, forKey: .itemID)
            try c.encodeIfPresent(sourceID, forKey: .sourceID)
            try c.encode(offsetMs, forKey: .offsetMs)
            try c.encodeIfPresent(durationMs, forKey: .durationMs)
            try c.encode(watched, forKey: .watched)
            try c.encode(at, forKey: .at)
        }
    }

    var entries: [Entry] = []

    // Only in-flight callbacks can arrive behind an acknowledgment. This state ends with the process.
    private var lastReached: [Key: Date] = [:]
    private enum CodingKeys: String, CodingKey { case entries }

    /// One entry per server, profile, account and item: the latest position, watched if ever watched.
    @discardableResult
    mutating func record(_ entry: Entry) -> Bool {
        if let reached = lastReached[entry.key], reached >= entry.at { return false }
        guard let i = entries.firstIndex(where: { $0.key == entry.key }) else {
            entries.append(entry)
            return true
        }
        let old = entries[i]
        var merged = entry.at >= old.at ? entry : old
        merged.watched = old.watched || entry.watched
        guard merged != old else { return false }
        entries[i] = merged
        return true
    }

    /// A report for this owner landed. Late failures for it can no longer add an older position.
    mutating func reached(_ key: Key, at: Date) -> Bool {
        lastReached[key] = max(at, lastReached[key] ?? at)
        let before = entries.count
        entries.removeAll { $0.key == key && $0.at <= at }
        return entries.count != before
    }

    /// Match the complete replayed snapshot so a position coalesced during the send survives.
    mutating func remove(replayed: [Entry]) -> Bool {
        let completed = Set(replayed)
        let before = entries.count
        entries.removeAll { completed.contains($0) }
        return entries.count != before
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

    /// What to do with an entry whose send failed.
    enum Verdict: Equatable {
        /// Give up on the entry.
        case drop
        /// Keep the entry for the next run and go on with the rest.
        case keep
        /// The server is out of reach or refused us: keep everything and end the run.
        case stop
    }

    static func verdict(for error: Error) -> Verdict {
        if error is URLError || error is CancellationError { return .stop }
        if let plex = error as? PlexAPIError {
            switch plex {
            case .networkError, .authenticationFailed: return .stop
            case .httpError(let status, _):
                switch status {
                case 401, 408, 421, 425, 429: return .stop
                case 500...599: return .keep
                default: return .drop
                }
            case .invalidResponse, .parsingError: return .keep
            default: return .drop
            }
        }
        switch error as? MediaProviderError {
        case .unreachable?, .unauthorized?: return .stop
        case .backendSpecific?: return .keep
        default: return .drop
        }
    }

    /// Checkpoint completed entries together. A crash can repeat the last partial batch.
    static let checkpointSize = 16

    /// Sends entries in order and checkpoints completed work even when a later send stops the run.
    static func replay(
        _ entries: [Entry],
        isolation: isolated (any Actor)? = #isolation,
        serverLastViewedAt: (Entry) async throws -> Date?,
        send: (Entry) async throws -> Void,
        remove: ([Entry]) -> Void
    ) async -> Bool {
        var sent = false
        var completed: [Entry] = []
        defer { if !completed.isEmpty { remove(completed) } }
        for entry in entries {
            do {
                try Task.checkCancellation()
                if shouldReplay(entry, serverLastViewedAt: try await serverLastViewedAt(entry)) {
                    try await send(entry)
                    sent = true
                }
            } catch {
                switch verdict(for: error) {
                case .stop: return sent
                case .keep: continue
                case .drop: break
                }
            }
            completed.append(entry)
            if completed.count == checkpointSize {
                remove(completed)
                completed.removeAll(keepingCapacity: true)
            }
        }
        return sent
    }

    static func load(from url: URL) -> OfflineProgressLog {
        DownloadsJSONFile.load(OfflineProgressLog.self, from: url) ?? OfflineProgressLog()
    }

    func save(to url: URL) throws {
        try DownloadsJSONFile.save(self, to: url)
    }
}

/// Replaying a Jellyfin or Emby account's entries through the provider.
nonisolated enum ProviderProgressReplay {
    /// The entries that belong to this server, account and profile.
    static func due(_ entries: [OfflineProgressLog.Entry], providerID: String, accountID: String?,
                    profileID: String?) -> [OfflineProgressLog.Entry] {
        entries.filter { $0.providerID == providerID && $0.accountID == accountID && $0.profileID == profileID }
    }

    /// Sends each entry's position, then marks it played when it was watched, unless the server saw a
    /// later view. Returns whether anything was sent.
    static func replay(
        _ entries: [OfflineProgressLog.Entry],
        isolation: isolated (any Actor)? = #isolation,
        provider: any MediaProvider,
        remove: ([OfflineProgressLog.Entry]) -> Void
    ) async -> Bool {
        func ref(_ entry: OfflineProgressLog.Entry) -> MediaItemRef {
            MediaItemRef(providerID: provider.id, itemID: entry.itemID)
        }
        return await OfflineProgressLog.replay(
            entries,
            serverLastViewedAt: { try await provider.fullDetail(for: ref($0)).item.userState.lastViewedAt },
            send: { entry in
                try await provider.updateProgress(ref(entry), position: TimeInterval(entry.offsetMs) / 1000)
                if entry.watched { try await provider.markPlayed(ref(entry)) }
            },
            remove: remove)
    }
}
