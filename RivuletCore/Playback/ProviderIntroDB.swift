// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// IntroDB for a Jellyfin or Emby episode, as `PlexPlaybackMarkers.markers` does for Plex:
/// intro, recap and credits from introdb.app for the kinds the server left out, keyed on the
/// series' IMDb id (IntroDB rejects episode ids). Opt-in ("useIntroDB"): it sends the id,
/// season and episode to a third party.
nonisolated enum ProviderIntroDB {
    struct EpisodeKey: Sendable, Equatable {
        let seriesIMDbID: String
        let season: Int
        let episode: Int
    }

    private static let backfilled: Set<PlaybackMarker.Kind> = [.intro, .recap, .credits]

    /// `markers` plus IntroDB's for the missing kinds. `episode` is asked only when the user
    /// opted in and a kind is missing, so a server that already has every marker costs nothing.
    static func filling(
        _ markers: [PlaybackMarker],
        enabled: Bool = UserDefaults.standard.bool(forKey: "useIntroDB"),
        episode: () async -> EpisodeKey?,
        lookup: @Sendable (String, Int, Int) async -> [PlexMarker] = {
            await IntroDBClient().markers(imdbID: $0, season: $1, episode: $2)
        }
    ) async -> [PlaybackMarker] {
        let present = Set(markers.map(\.kind))
        guard enabled, !backfilled.isSubset(of: present), let key = await episode() else { return markers }
        let found = PlexPlaybackMarkers.playbackMarkers(await lookup(key.seriesIMDbID, key.season, key.episode))
        return markers + found.filter { backfilled.contains($0.kind) && !present.contains($0.kind) }
    }

    /// The IMDb id in a Jellyfin or Emby `ProviderIds`, whose key case differs between servers.
    static func imdbID(in providerIds: [String: String]?) -> String? {
        guard let value = providerIds?.first(where: { $0.key.caseInsensitiveCompare("Imdb") == .orderedSame })?.value,
              !value.isEmpty else { return nil }
        return value
    }
}
