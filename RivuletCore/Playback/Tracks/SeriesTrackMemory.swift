// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  Audio and subtitle picks per series, per Plex Home profile. A pick in an
//  episode is where the show's next episodes start, ahead of Plex's per-item
//  selection and the global intent. Episodes only: a movie has no next.
//
//  Why a store and not a narrower Plex tier: Plex's auto-select from the
//  account's languages marks a `selected` stream on every episode, and that
//  reads exactly like a pick made on the episode (Plex Web, mobile). The app
//  can't tell the two apart, so a pick made here has to outrank both.
//
//  A subtitle pick is remembered as the intent the global setting takes from
//  it (`SubtitleIntent.afterPick`): under Foreign Audio a fitting pick keeps the
//  mode and Off covers the current title only (#432), so the series follows the
//  audio of each episode as the setting does. Generated subtitles forget the
//  series' subtitle pick, so they carry on to the next episode.
//

import Foundation

enum SeriesTrackMemory {
    struct Entry: Codable, Equatable {
        var audio: AudioIntent?
        var subtitle: SubtitleIntent?
        var updated: Date
    }

    /// Series kept per profile; the least recently picked go first.
    static let limit = 100

    // Defaults injectable for tests.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    private static let baseKey = "seriesTrackMemory"

    // MARK: Keys

    /// The series an episode belongs to: Plex's show guid, the same on every server, else the
    /// show's own id on its server.
    static func key(showGUID: String?, showID: String?, server: String) -> String? {
        if let showGUID, !showGUID.isEmpty { return showGUID }
        guard let showID, !showID.isEmpty else { return nil }
        return server + "/" + showID
    }

    /// The series of a Jellyfin or Emby episode.
    static func key(providerItem item: MediaItem) -> String? {
        guard item.kind == .episode else { return nil }
        return item.grandparentRef.map { $0.providerID + "/" + $0.itemID }
    }

    /// The series of what a request plays; nil for anything but an episode.
    static func key(for request: PlexPlaybackRequest) -> String? {
        if let playback = request.providerPlayback { return key(providerItem: playback.item) }
        guard request.item.type == "episode" else { return nil }
        return key(showGUID: request.item.grandparentGuid, showID: request.item.grandparentRatingKey,
                   server: request.downloadProviderID ?? request.serverURL)
    }

    // MARK: Reading

    static func entry(for series: String) -> Entry? {
        load()[series]
    }

    /// The series' audio on this episode's tracks; nil when it has no pick or the episode
    /// has no track in its language (the usual order decides those).
    static func audio(for series: String?, in tracks: [MediaTrack]) -> MediaTrack? {
        guard let series, let intent = entry(for: series)?.audio else { return nil }
        return audio(intent, in: tracks)
    }

    /// The series' subtitles on this episode's tracks, judged against the audio it plays.
    /// nil when it has no pick or nothing matches (the usual order decides those).
    static func subtitle(for series: String?, in tracks: [MediaTrack], audioLanguage: String?) -> SubtitlePick? {
        guard let series, let intent = entry(for: series)?.subtitle else { return nil }
        return subtitle(intent, in: tracks, audioLanguage: audioLanguage)
    }

    /// The tracks an episode starts on. `fallbackAudio` is the track the episode plays when the
    /// series has no audio pick, which the subtitles are judged against.
    static func startingPicks(_ entry: Entry, audio: [MediaTrack], subtitles: [MediaTrack],
                              fallbackAudio: MediaTrack? = nil) -> TrackPicks {
        let audioTrack = entry.audio.flatMap { Self.audio($0, in: audio) }
        let playing = audioTrack ?? fallbackAudio
        let subtitle = entry.subtitle.flatMap {
            Self.subtitle($0, in: subtitles, audioLanguage: playing?.languageCode ?? playing?.language)
        }
        return TrackPicks(audio: audioTrack?.id, subtitle: subtitle)
    }

    /// `resolveAudio` never misses (English, then the default), so a track in another
    /// language means the episode doesn't have the series' language.
    private static func audio(_ intent: AudioIntent, in tracks: [MediaTrack]) -> MediaTrack? {
        guard TrackLanguage.isKnown(intent.language),
              let track = TrackIntentResolver.resolveAudio(intent: intent, in: tracks),
              TrackLanguage.matches(track.languageCode ?? track.language, intent.language) else { return nil }
        return track
    }

    private static func subtitle(_ intent: SubtitleIntent, in tracks: [MediaTrack], audioLanguage: String?) -> SubtitlePick? {
        if case .off = intent { return .off }
        return TrackIntentResolver.resolveSubtitle(intent: intent, in: tracks, audioLanguage: audioLanguage)
            .map { .track($0.id) }
    }

    // MARK: Writing

    static func remember(audio: AudioIntent, for series: String, now: Date = Date()) {
        update(series, now: now) { $0.audio = audio }
    }

    /// The intent the pick left behind (`SubtitleIntent.afterPick`), so `.off` here is an Off
    /// outside Foreign Audio, which the global setting keeps too.
    static func remember(subtitle: SubtitleIntent, for series: String, now: Date = Date()) {
        update(series, now: now) { $0.subtitle = subtitle }
    }

    /// Generated subtitles: the series' subtitle pick no longer holds.
    static func forgetSubtitle(for series: String) {
        var entries = load()
        guard var entry = entries[series], entry.subtitle != nil else { return }
        entry.subtitle = nil
        entries[series] = entry.audio == nil ? nil : entry
        save(entries)
    }

    /// Test seam.
    static func resetAll() {
        defaults.removeObject(forKey: profileKey)
    }

    // MARK: Storage

    /// Keyed off `selectedPlexUserId`, as `TrackIntentStore` is. Not synced through iCloud: the
    /// whole list is one value, so two devices watching different shows would overwrite each other.
    private static var profileKey: String {
        guard let userId = defaults.object(forKey: PlexProfileSession.savedUserIDKey) as? Int else { return baseKey }
        return "\(baseKey)_user_\(userId)"
    }

    private static func load() -> [String: Entry] {
        guard let data = defaults.data(forKey: profileKey) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }

    private static func save(_ entries: [String: Entry]) {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: profileKey) }
    }

    private static func update(_ series: String, now: Date, _ change: (inout Entry) -> Void) {
        var entries = load()
        var entry = entries[series] ?? Entry(updated: now)
        change(&entry)
        entry.updated = now
        entries[series] = entry
        if entries.count > limit {
            let oldest = entries.sorted { $0.value.updated < $1.value.updated }.prefix(entries.count - limit)
            oldest.forEach { entries.removeValue(forKey: $0.key) }
        }
        save(entries)
    }
}
