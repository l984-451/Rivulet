// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// What a Jellyfin or Emby download needs to start and to play offline: the version chosen, the
/// player-shaped metadata, and the external subtitles to save beside the file.
nonisolated struct ProviderDownloadPlan: Sendable {
    nonisolated struct Sidecar: Sendable, Equatable {
        var url: URL
        var language: String?
        var title: String?
        var codec: String
        var isForced: Bool
        /// The file extension to save it under.
        var ext: String
    }

    var item: MediaItem
    var sourceID: String
    var expectedBytes: Int64?
    var metadata: PlexMetadata
    var sidecars: [Sidecar]
}

nonisolated enum ProviderDownloadPlanner {
    /// Picks the version and shapes the stored copy: the item without tokens, and the player's
    /// metadata with every sidecar's URL replaced by its slot, so no credential reaches the manifest.
    static func plan(detail: MediaItemDetail, extras: PlaybackExtras, choice: VersionChoice) throws -> ProviderDownloadPlan {
        guard let source = VersionRanking.choose(choice, from: detail.mediaSources) else { throw MediaProviderError.notPlayable }
        // The player pairs a sidecar with the external stream at the same position (a stream with a key),
        // so the keys stay as slot names instead of URLs.
        let metadata = ProviderPlaybackMetadata.make(detail: detail, source: source, extras: extras, sidecarSlots: true)
        let tracks = source.subtitleTracks.filter { !$0.isEmbedded && $0.externalURL != nil }

        let sidecars = tracks.compactMap { track -> ProviderDownloadPlan.Sidecar? in
            guard let url = track.externalURL else { return nil }
            return ProviderDownloadPlan.Sidecar(
                url: url, language: track.language, title: track.title ?? track.extendedTitle, codec: track.codec,
                isForced: track.isForced, ext: fileExtension(url: url, codec: track.codec))
        }
        return ProviderDownloadPlan(
            item: detail.item.storedForDownload(providerID: detail.item.ref.providerID), sourceID: source.id,
            expectedBytes: source.fileSize, metadata: metadata, sidecars: sidecars)
    }

    /// The URL's own extension when it has one, else the codec's.
    private static func fileExtension(url: URL, codec: String) -> String {
        let fromURL = url.pathExtension.lowercased()
        if !fromURL.isEmpty, fromURL.count <= 4 { return fromURL }
        switch codec.lowercased() {
        case "subrip", "": return "srt"
        case "webvtt": return "vtt"
        default: return codec.lowercased()
        }
    }
}
