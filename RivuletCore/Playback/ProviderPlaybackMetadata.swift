// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ProviderPlaybackMetadata.swift
//  Rivulet
//
//  The player chrome reads `PlexMetadata`. For a non-Plex item this builds
//  one from the agnostic types, carrying display data only: no Part key, no
//  artwork paths, nothing a Plex request could be built from.
//
//  Streams keep the source's track order, so external subtitles appear in
//  the same order as `source.subtitleTracks.filter { !$0.isEmbedded }`:
//  TrackMerge pairs sidecars by that order, and embedded tracks by `index`.
//

import Foundation

enum ProviderPlaybackMetadata {

    /// `sidecarSlots` names each external subtitle "sidecar:<n>" instead of by URL, for a copy that is
    /// stored: the URL carries the account's key.
    static func make(detail: MediaItemDetail, source: MediaSource, extras: PlaybackExtras,
                     sidecarSlots: Bool = false) -> PlexMetadata {
        let item = detail.item
        let durationSeconds = source.duration > 0 ? source.duration : item.runtime
        let video = source.videoTracks.first
        let audio = source.audioTracks.first
        let offset = item.userState.viewOffset

        // The external subtitle's key: its URL, or its place among the external ones.
        var next = 0
        let slots: [String?] = source.subtitleTracks.map { track in
            guard !track.isEmbedded, let url = track.externalURL else { return nil }
            defer { next += 1 }
            return sidecarSlots ? "sidecar:\(next)" : url.absoluteString
        }
        // Each stream's position in the list is its fallback id (see `stream`).
        let audioStart = source.videoTracks.count
        let subtitleStart = audioStart + source.audioTracks.count
        let streams = source.videoTracks.enumerated().map { videoStream($1, ordinal: $0) }
            + source.audioTracks.enumerated().map { audioStream($1, ordinal: audioStart + $0) }
            + source.subtitleTracks.enumerated().map { subtitleStream($1, ordinal: subtitleStart + $0, slot: slots[$0]) }
        let part = PlexPart(
            id: 0,
            key: nil,
            duration: durationSeconds.map(ms),
            file: source.fileName,
            size: source.fileSize.map { Int($0) },
            container: source.container,
            Stream: streams
        )
        let media = PlexMedia(
            id: 0,
            duration: durationSeconds.map(ms),
            bitrate: source.bitrate.map { $0 / 1000 },   // bps -> kbps
            width: video?.width,
            height: video?.height,
            aspectRatio: nil,
            audioChannels: audio?.channels,
            audioCodec: audio?.codec,
            videoCodec: video?.codec,
            videoResolution: source.videoResolution,
            container: source.container,
            videoFrameRate: nil,
            Part: [part]
        )

        let type: String? = switch item.kind {
        case .movie, .show, .season, .episode: item.kind.rawValue
        default: nil
        }

        var metadata = PlexMetadata(
            ratingKey: item.ref.itemID,
            key: nil,
            type: type,
            title: item.title,
            contentRating: detail.contentRating ?? item.contentRating,
            summary: item.overview,
            year: item.year,
            Genre: detail.genres.isEmpty ? nil : detail.genres.map { PlexTag(tag: $0) },
            duration: durationSeconds.map(ms),
            parentIndex: item.seasonNumber,
            grandparentTitle: item.seriesTitle,
            index: item.episodeNumber,
            viewOffset: offset > 0 ? ms(offset) : nil,
            Media: [media],
            Marker: extras.markers.isEmpty ? nil : markers(from: extras)
        )
        metadata.Chapter = detail.chapters.isEmpty ? nil : detail.chapters.enumerated().map { i, chapter in
            PlexChapter(
                id: nil,
                tag: chapter.title,
                index: i + 1,
                startTimeOffset: ms(chapter.start),
                endTimeOffset: chapter.end.map(ms),
                thumb: nil
            )
        }
        metadata.Guid = detail.externalIDs.isEmpty ? nil : detail.externalIDs
            .sorted { $0.key < $1.key }
            .map { PlexGuid(id: "\($0.key)://\($0.value)") }
        return metadata
    }

    /// The source with the audio and subtitle tracks marked selected, as a transcode started on
    /// them plays. Ids are the shim's stream ids.
    static func applying(_ picks: TrackPicks, to source: MediaSource) -> MediaSource {
        var source = source
        if let audio = picks.audio {
            for i in source.audioTracks.indices { source.audioTracks[i].isSelected = Int(source.audioTracks[i].id) == audio }
        }
        if let subtitle = picks.subtitle {
            for i in source.subtitleTracks.indices {
                source.subtitleTracks[i].isSelected = subtitle.trackID.map { Int(source.subtitleTracks[i].id) == $0 } ?? false
            }
        }
        return source
    }

    /// The player tracks credits, recap and commercial markers by id, so each gets a unique
    /// negative one, clear of IntroDB's -900x range.
    static func markers(from extras: PlaybackExtras) -> [PlexMarker] {
        extras.markers.enumerated().map { i, marker in
            PlexMarker(id: -(1 + i), type: marker.kind.rawValue,
                       startTimeOffset: ms(marker.start), endTimeOffset: ms(marker.end))
        }
    }

    /// An Up Next row or the next-episode card: what a listing shows, no media.
    static func listing(item: MediaItem) -> PlexMetadata {
        PlexMetadata(
            ratingKey: item.ref.itemID,
            type: item.kind == .episode ? "episode" : nil,
            title: item.title,
            summary: item.overview,
            year: item.year,
            duration: item.runtime.map { ms($0) },
            parentIndex: item.seasonNumber,
            grandparentTitle: item.seriesTitle,
            index: item.episodeNumber,
            viewCount: item.userState.isPlayed ? 1 : nil
        )
    }

    private static func ms(_ seconds: TimeInterval) -> Int {
        Int((seconds * 1000).rounded())
    }

    // MARK: - Streams

    /// VideoTrack carries no container index, so the video stream has none.
    /// Nothing joins on a video stream's index.
    private static func videoStream(_ t: VideoTrack, ordinal: Int) -> PlexStream {
        var primaries: String?
        var transfer: String?
        var doviProfile: Int?
        switch t.videoRange {
        case .sdr: break
        case .hdr10, .hdr10Plus: (primaries, transfer) = ("bt2020", "smpte2084")
        case .hlg: (primaries, transfer) = ("bt2020", "arib-std-b67")
        case .dolbyVision(let profile): doviProfile = profile
        }
        return stream(
            id: t.id, ordinal: ordinal, type: 1, index: nil, codec: t.codec, isDefault: t.isDefault,
            colorPrimaries: primaries, colorTrc: transfer, doviProfile: doviProfile,
            frameRate: t.frameRate, height: t.height, width: t.width, level: t.level,
            profile: t.profile, scanType: t.scanType
        )
    }

    private static func audioStream(_ t: AudioTrack, ordinal: Int) -> PlexStream {
        stream(
            id: t.id, ordinal: ordinal, type: 2, index: t.index, codec: t.codec, language: t.language,
            title: t.title, extendedTitle: t.extendedTitle, isDefault: t.isDefault,
            isForced: t.isForced, isSelected: t.isSelected, profile: t.profile,
            channelLayout: t.channelLayout, channels: t.channels, samplingRate: t.samplingRate
        )
    }

    /// Embedded tracks join the engine on `index`; sidecars have no index and
    /// carry their URL as `key`.
    private static func subtitleStream(_ t: SubtitleTrack, ordinal: Int, slot: String?) -> PlexStream {
        stream(
            id: t.id, ordinal: ordinal, type: 3, index: t.isEmbedded ? t.index : nil, codec: t.codec,
            language: t.language, title: t.title, extendedTitle: t.extendedTitle,
            isDefault: t.isDefault, isForced: t.isForced, isSelected: t.isSelected,
            hearingImpaired: t.isHearingImpaired,
            key: slot
        )
    }

    /// A numeric track id is used as is. Any other id falls back to the
    /// stream's ordinal, below -10_000_000: real ids are never negative and
    /// `PlexStream`'s own synthesized ids stay above -4_000_000, so no two
    /// streams share an id even when none has an index.
    private static func stream(
        id: String, ordinal: Int, type: Int, index: Int?, codec: String, language: String? = nil,
        title: String? = nil, extendedTitle: String? = nil, isDefault: Bool,
        isForced: Bool = false, isSelected: Bool = false, hearingImpaired: Bool? = nil,
        colorPrimaries: String? = nil, colorTrc: String? = nil, doviProfile: Int? = nil,
        frameRate: Double? = nil, height: Int? = nil, width: Int? = nil, level: Int? = nil,
        profile: String? = nil, scanType: String? = nil, channelLayout: String? = nil,
        channels: Int? = nil, samplingRate: Int? = nil, key: String? = nil
    ) -> PlexStream {
        PlexStream(
            _id: Int(id) ?? -(10_000_000 + ordinal),
            streamType: type,
            index: index,
            codec: codec,
            codecID: nil,
            // Plex's `language` is the display name ("English"); the provider's
            // track carries only the code ("eng"), as Plex's `languageCode` does.
            language: language.map { Locale.current.localizedString(forLanguageCode: $0)?.capitalized ?? $0 },
            languageCode: language,
            languageTag: nil,
            displayTitle: title,
            title: title,
            default: isDefault,
            forced: isForced,
            selected: isSelected,
            bitDepth: nil,
            chromaLocation: nil,
            chromaSubsampling: nil,
            colorPrimaries: colorPrimaries,
            colorRange: nil,
            colorSpace: nil,
            colorTrc: colorTrc,
            DOVIBLCompatID: nil,
            DOVIBLPresent: nil,
            DOVIELPresent: nil,
            DOVILevel: nil,
            DOVIPresent: doviProfile.map { _ in true },
            DOVIProfile: doviProfile,
            DOVIRPUPresent: nil,
            DOVIVersion: nil,
            HDR10PlusPresent: nil,
            frameRate: frameRate,
            height: height,
            width: width,
            level: level,
            profile: profile,
            refFrames: nil,
            scanType: scanType,
            audioChannelLayout: channelLayout,
            channels: channels,
            bitrate: nil,
            samplingRate: samplingRate,
            format: nil,
            key: key,
            extendedDisplayTitle: extendedTitle,
            hearingImpaired: hearingImpaired
        )
    }
}
