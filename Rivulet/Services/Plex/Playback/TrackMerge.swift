// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  Merges the engine's tracks (selectable stream ids) with Plex's streams (labels) at load,
//  so there is one id space (#201). The join key is the container stream index: the engine's
//  `TrackInfo.id` is the FFmpeg stream index, and Plex reports it as `PlexStream.index`.
//  Ordinals would shift, because Plex lists EIA-608/708 captions (`embeddedInVideo`) that
//  FFmpeg never exposes as streams. External sidecars pair by registration order.

import Foundation

enum TrackMerge {

    /// Merge the engine's audio tracks with Plex's audio streams.
    static func mergeAudio(engine: [MediaTrack], plex: [MediaTrack]) -> [MediaTrack] {
        let byIndex = indexPlexStreams(plex)
        return engine.map { track in
            enrich(track, with: track.streamIndex.flatMap { byIndex[$0] })
        }
    }

    /// Merge the engine's subtitle tracks with Plex's subtitle streams.
    ///
    /// External sidecars have no stream index, so they pair with Plex's sidecars in
    /// the order `aetherExternalSubtitles()` registered them.
    static func mergeSubtitles(engine: [MediaTrack], plex: [MediaTrack]) -> [MediaTrack] {
        let byIndex = indexPlexStreams(plex.filter { $0.subtitleKey == nil })
        let externalPlex = plex.filter { $0.subtitleKey != nil }
        var externalOrdinal = 0

        return engine.map { track in
            if track.isExternal {
                let counterpart = externalOrdinal < externalPlex.count ? externalPlex[externalOrdinal] : nil
                externalOrdinal += 1
                return enrich(track, with: counterpart)
            }
            return enrich(track, with: track.streamIndex.flatMap { byIndex[$0] })
        }
    }

    /// Plex streams keyed by container stream index. Streams with no index are
    /// dropped; duplicate indices keep the first.
    private static func indexPlexStreams(_ plex: [MediaTrack]) -> [Int: MediaTrack] {
        var map: [Int: MediaTrack] = [:]
        for track in plex {
            guard let index = track.streamIndex else { continue }
            if map[index] == nil { map[index] = track }
        }
        return map
    }

    // MARK: - Enrichment

    /// Folds Plex's labels onto an engine track, keeping the engine's `id` (the selection key).
    /// Name prefers Plex; forced/SDH/default flags are OR'd; codec and channels prefer the
    /// engine, since Plex's scan goes stale when a file is replaced in place.
    private static func enrich(_ engineTrack: MediaTrack, with plexTrack: MediaTrack?) -> MediaTrack {
        guard let plexTrack else { return engineTrack }

        return MediaTrack(
            id: engineTrack.id,                       // engine index — the selection key
            name: preferredName(engine: engineTrack, plex: plexTrack),
            language: plexTrack.language ?? engineTrack.language,
            languageCode: plexTrack.languageCode ?? engineTrack.languageCode,
            codec: engineTrack.codec ?? plexTrack.codec,
            isDefault: engineTrack.isDefault || plexTrack.isDefault,
            isForced: engineTrack.isForced || plexTrack.isForced,
            isHearingImpaired: engineTrack.isHearingImpaired || plexTrack.isHearingImpaired,
            isCommentary: engineTrack.isCommentary,   // engine-only flag
            extendedDisplayTitle: plexTrack.extendedDisplayTitle,
            channels: engineTrack.channels ?? plexTrack.channels,
            profile: plexTrack.profile,
            hasAtmos: engineTrack.hasAtmos || plexTrack.hasAtmos,
            subtitleKey: plexTrack.subtitleKey,
            streamIndex: engineTrack.streamIndex,
            isExternal: engineTrack.isExternal
        )
    }

    /// Plex's display title, unless it has nothing usable, in which case keep
    /// whatever the engine synthesized (localized language name, or codec).
    private static func preferredName(engine: MediaTrack, plex: MediaTrack) -> String {
        let plexName = plex.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return plexName.isEmpty ? engine.name : plexName
    }
}

/// Silo's audio identity is an ordinal within the original file's audio tracks,
/// not an FFmpeg stream index. Probe publications during load are not a settled
/// selection: the engine still has to choose its initial track and start it.
struct NativeAudioSelection {
    private var applied = false

    mutating func resolve(ordinal: Int?, engine: [MediaTrack], loadReturned: Bool) -> Int? {
        guard !applied, loadReturned, let ordinal, engine.indices.contains(ordinal) else { return nil }
        applied = true
        return engine[ordinal].id
    }
}

/// Provider request indices and native container indices are distinct identities.
enum NativeSubtitleSelection {
    static func engineID(ordinal: Int, tracks: [SubtitleTrack], engine: [MediaTrack]) -> Int? {
        guard tracks.indices.contains(ordinal) else { return nil }
        let selected = tracks[ordinal]
        if selected.isEmbedded {
            guard let index = selected.nativeStreamIndex else { return nil }
            return engine.first { !$0.isExternal && $0.id == index }?.id
        }
        guard selected.externalURL != nil else { return nil }
        var remaining = tracks[..<ordinal].reduce(0) {
            $0 + (!$1.isEmbedded && $1.externalURL != nil ? 1 : 0)
        }
        for track in engine where track.isExternal {
            if remaining == 0 { return track.id }
            remaining -= 1
        }
        return nil
    }
}
