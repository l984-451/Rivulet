// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation

/// What the shared client stores ask of an app that keeps downloads and an offline progress queue.
/// Only iOS has either; the defaults here (`NoOfflineHost`) mean "nothing downloaded, nothing queued".
@MainActor
protocol OfflineHost: AnyObject {
    var currentProfileID: String? { get }
    /// The selected Plex server's machine id, as downloads key it.
    var currentServerID: String? { get }
    var visibleRecords: [DownloadRecord] { get }
    func localPlayback(for item: PlexMetadata, serverID: String?) -> PlexPlaybackRequest?
    func localPlayback(for item: MediaItem) -> PlexPlaybackRequest?
    func noteProgress(for request: PlexPlaybackRequest, offsetMs: Int, watched: Bool, persist: Bool)

    var progressEntries: [OfflineProgressLog.Entry] { get }
    var isFlushing: Bool { get set }
    func recordProgress(providerID: String, itemID: String, offsetMs: Int, durationMs: Int?, watched: Bool, at: Date)
    func progressReached(_ providerID: String, itemID: String, at: Date)
    func removeProgress(_ entry: OfflineProgressLog.Entry)
    /// Sends what is queued for signed-in Jellyfin and Emby servers. True when anything was sent.
    func flushProviders() async -> Bool
}

@MainActor
final class NoOfflineHost: OfflineHost {
    var currentProfileID: String? { nil }
    var currentServerID: String? { nil }
    var visibleRecords: [DownloadRecord] { [] }
    func localPlayback(for item: PlexMetadata, serverID: String?) -> PlexPlaybackRequest? { nil }
    func localPlayback(for item: MediaItem) -> PlexPlaybackRequest? { nil }
    func noteProgress(for request: PlexPlaybackRequest, offsetMs: Int, watched: Bool, persist: Bool) {}
    var progressEntries: [OfflineProgressLog.Entry] { [] }
    var isFlushing = false
    func recordProgress(providerID: String, itemID: String, offsetMs: Int, durationMs: Int?, watched: Bool, at: Date) {}
    func progressReached(_ providerID: String, itemID: String, at: Date) {}
    func removeProgress(_ entry: OfflineProgressLog.Entry) {}
    func flushProviders() async -> Bool { false }
}

/// Seams the host fills at launch, before the first `PlexSession` or `BrowseStore` is made.
@MainActor
enum ClientHost {
    static var offline: any OfflineHost = NoOfflineHost()
    /// Warms the host's image cache for a URL; the default does nothing.
    static var prefetchImage: @Sendable (URL) async -> Void = { _ in }
    /// Rewrites the assembled Home before it is shown (iOS screenshot mode).
    static var transformHome: (HomeFeed.Assembled) -> HomeFeed.Assembled = { $0 }
}

/// A sidecar subtitle file registered with the player at load.
struct SubtitleSidecar {
    let url: URL
    let name: String?
    let language: String?
    let isForced: Bool
    let isHearingImpaired: Bool
    let isDefault: Bool
    /// "srt", "ass", "vtt": Plex stream keys carry no extension.
    let formatHint: String?
}
