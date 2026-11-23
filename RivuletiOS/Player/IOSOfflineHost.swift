// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation

/// Progress that failed to reach a server, kept next to the downloads manifest.
@MainActor
enum IOSOfflineProgress {
    private static let url = IOSDownloadTransfer.directory.appending(path: "offline-progress.json")
    private(set) static var log = OfflineProgressLog.load(from: url)
    static var isFlushing = false
    private static var isFlushingProviders = false

    static func record(_ entry: OfflineProgressLog.Entry) {
        if log.record(entry) { try? log.save(to: url) }
    }

    static func reached(_ key: OfflineProgressLog.Key, at: Date) {
        if log.reached(key, at: at) { try? log.save(to: url) }
    }

    static func remove(_ entries: [OfflineProgressLog.Entry]) {
        var checkpoint = log
        guard checkpoint.remove(replayed: entries) else { return }
        // Keep these entries available for retry if the atomic write fails.
        guard (try? checkpoint.save(to: url)) != nil else { return }
        log = checkpoint
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
    func recordProgress(_ entry: OfflineProgressLog.Entry) { IOSOfflineProgress.record(entry) }
    func progressReached(_ key: OfflineProgressLog.Key, at: Date) { IOSOfflineProgress.reached(key, at: at) }
    func removeProgress(_ entries: [OfflineProgressLog.Entry]) { IOSOfflineProgress.remove(entries) }
    func flushProviders() async -> Bool { await IOSOfflineProgress.flushProviders() }
}
