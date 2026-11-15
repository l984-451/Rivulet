// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation

/// Progress that failed to reach a server, kept next to the downloads manifest.
@MainActor
enum IOSOfflineProgress {
    private static let url = IOSDownloadTransfer.directory.appending(path: "offline-progress.json")
    private(set) static var log = OfflineProgressLog.load(from: url)
    private static var lastReached: [String: Date] = [:]
    static var isFlushing = false
    private static var isFlushingProviders = false

    /// Queues a position for `providerID` (a download key), for the current profile and, on Jellyfin and
    /// Emby, the signed-in account.
    static func record(providerID: String, itemID: String, offsetMs: Int, durationMs: Int?, watched: Bool, at: Date) {
        let center = ClientHost.offline
        // A bare Plex key (server not known) would replay to whichever server is current, and never clear.
        guard providerID != "plex:" else { return }
        // A report that failed after a newer one landed adds nothing.
        guard lastReached["\(providerID)|\(itemID)"].map({ $0 < at }) ?? true else { return }
        let account = account(of: providerID)
        log.record(.init(providerID: providerID, profileID: center.currentProfileID, accountID: account, itemID: itemID,
                         offsetMs: offsetMs, durationMs: durationMs, watched: watched, at: at))
        try? log.save(to: url)
    }

    /// A report landed, so older offline entries for the item are stale.
    static func reached(_ providerID: String, itemID: String, at: Date) {
        let key = "\(providerID)|\(itemID)"
        lastReached[key] = max(at, lastReached[key] ?? at)
        let before = log.entries.count
        log.entries.removeAll { $0.providerID == providerID && $0.itemID == itemID && $0.at <= at }
        if log.entries.count != before { try? log.save(to: url) }
    }

    /// Drops a replayed entry; a newer one coalesced in meanwhile stays.
    static func remove(_ entry: OfflineProgressLog.Entry) {
        log.entries.removeAll { $0 == entry }
        try? log.save(to: url)
    }

    /// The signed-in account of a Jellyfin or Emby download key; Plex entries have none.
    private static func account(of providerID: String) -> String? {
        guard !providerID.hasPrefix("plex:") else { return nil }
        return MediaProviderRegistry.shared.provider(for: providerID)?.accountID
    }

    /// Sends what is queued for the signed-in Jellyfin and Emby servers. True when anything was sent.
    static func flushProviders() async -> Bool {
        guard !isFlushingProviders else { return false }
        isFlushingProviders = true
        defer { isFlushingProviders = false }
        var sent = false
        for provider in MediaProviderRegistry.shared.secondaryProviders where provider.kind != .plex {
            let due = ProviderProgressReplay.due(log.entries, providerID: provider.id, accountID: provider.accountID,
                                                 profileID: ClientHost.offline.currentProfileID)
            guard !due.isEmpty else { continue }
            if await ProviderProgressReplay.replay(due, provider: provider, remove: { remove($0) }) { sent = true }
        }
        return sent
    }
}

/// The iOS answers for the shared stores' `OfflineHost`: the download center and the offline queue.
@MainActor
final class IOSOfflineHost: OfflineHost {
    private var center: IOSDownloadCenter { .shared }
    var currentProfileID: String? { center.currentProfileID }
    var currentServerID: String? { center.currentServerID }
    var visibleRecords: [DownloadRecord] { center.visibleRecords }
    func localPlayback(for item: PlexMetadata, serverID: String?) -> PlexPlaybackRequest? {
        center.localPlayback(for: item, serverID: serverID)
    }
    func localPlayback(for item: MediaItem) -> PlexPlaybackRequest? { center.localPlayback(for: item) }
    func noteProgress(for request: PlexPlaybackRequest, offsetMs: Int, watched: Bool, persist: Bool) {
        center.noteProgress(for: request, offsetMs: offsetMs, watched: watched, persist: persist)
    }

    var progressEntries: [OfflineProgressLog.Entry] { IOSOfflineProgress.log.entries }
    var isFlushing: Bool {
        get { IOSOfflineProgress.isFlushing }
        set { IOSOfflineProgress.isFlushing = newValue }
    }
    func recordProgress(providerID: String, itemID: String, offsetMs: Int, durationMs: Int?, watched: Bool, at: Date) {
        IOSOfflineProgress.record(providerID: providerID, itemID: itemID, offsetMs: offsetMs,
                                  durationMs: durationMs, watched: watched, at: at)
    }
    func progressReached(_ providerID: String, itemID: String, at: Date) {
        IOSOfflineProgress.reached(providerID, itemID: itemID, at: at)
    }
    func removeProgress(_ entry: OfflineProgressLog.Entry) { IOSOfflineProgress.remove(entry) }
    func flushProviders() async -> Bool { await IOSOfflineProgress.flushProviders() }
}
