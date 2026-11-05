// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyMediaMapper+Sources.swift
//  Rivulet
//
//  Media sources, tracks and skip markers. Emby's embedded `Index` is the container stream
//  index the engine reports, so tracks keep it as is: no offset arithmetic, and attachments
//  (`EmbeddedImage`) are left out of the lists but never renumber what follows.
//

import Foundation

extension EmbyMediaMapper {

    // MARK: - Language

    /// Emby writes ISO 639-2/B ("fre", "ger", "chi"). The app, like Plex and Jellyfin, uses 639-2/T.
    /// "und" means no language.
    static func language(_ code: String?) -> String? {
        guard let code = code?.lowercased(), !code.isEmpty, code != "und" else { return nil }
        return bibliographicToTerminology[code] ?? code
    }

    private static let bibliographicToTerminology: [String: String] = [
        "alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces", "dut": "nld",
        "fre": "fra", "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl", "mac": "mkd", "mao": "mri",
        "may": "msa", "per": "fas", "rum": "ron", "slo": "slk", "tib": "bod", "wel": "cym"
    ]

    // MARK: - Video

    /// The badge range. Emby is not authoritative for Dolby Vision (a dual-layer P7 file came back as
    /// HDR10): the engine's own probe decides playback. `DoviProfile<profile><compat>` carries the
    /// profile in its tens digit (76 is 7.6, 81 is 8.1); a subtype of `None` leaves it unknown.
    static func videoTrack(_ s: EmbyMediaStream) -> VideoTrack? {
        guard s.type == "Video", let index = s.index else { return nil }
        let range: VideoTrack.VideoRange = switch s.extendedVideoType?.lowercased() {
        case "dolbyvision": .dolbyVision(profile: dolbyVisionProfile(s.extendedVideoSubType))
        case "hdr10": .hdr10
        case "hdr10plus": .hdr10Plus
        case "hyperloggamma": .hlg
        default: .sdr
        }
        return VideoTrack(
            id: "\(index)",
            codec: s.codec?.lowercased() ?? "unknown",
            profile: s.profile,
            level: s.level.flatMap { Int(exactly: $0.rounded()) },
            width: s.width,
            height: s.height,
            frameRate: s.realFrameRate ?? s.averageFrameRate,
            bitrate: s.bitRate,
            videoRange: range,
            isDefault: s.isDefault ?? false,
            scanType: s.isInterlaced.map { $0 ? "interlaced" : "progressive" },
            hasHDR10Plus: false
        )
    }

    private static func dolbyVisionProfile(_ subtype: String?) -> Int {
        guard let subtype, subtype.lowercased().hasPrefix("doviprofile"),
              let digits = Int(subtype.dropFirst("DoviProfile".count)) else { return 0 }
        return digits / 10
    }

    // MARK: - Audio

    /// Sidecar audio is dropped: it is not in the container, so the engine never sees it.
    static func audioTrack(_ s: EmbyMediaStream, defaultIndex: Int?) -> AudioTrack? {
        guard s.type == "Audio", let index = s.index, s.isExternal != true else { return nil }
        // AudioTrack.qualityLabel speaks Plex: DTS is "dca", and the object-audio word rides the profile.
        let codec = s.codec?.lowercased() == "dts" ? "dca" : (s.codec?.lowercased() ?? "unknown")
        let profile = [s.profile, spatialAudioTag(codec: codec, title: s.title)].compactMap { $0 }.joined(separator: " ")
        return AudioTrack(
            id: "\(index)",
            index: index,
            codec: codec,
            profile: profile.isEmpty ? nil : profile,
            channels: s.channels,
            channelLayout: s.channelLayout,
            language: language(s.language),
            title: s.title ?? s.displayTitle,
            extendedTitle: s.displayTitle,
            bitrate: s.bitRate,
            samplingRate: s.sampleRate,
            isDefault: s.isDefault ?? false,
            isForced: s.isForced ?? false,
            isSelected: index == defaultIndex
        )
    }

    /// Atmos and DTS:X have no field on Emby; the release's own `Title` is the only place that says so.
    /// A release title is copied onto every track of the file (the AC3 core of a TrueHD Atmos remux
    /// carries "Atmos" too), so each word counts only on the codecs that can carry it.
    static func spatialAudioTag(codec: String, title: String?) -> String? {
        guard let title = title?.lowercased() else { return nil }
        if ["eac3", "truehd"].contains(codec), title.contains("atmos") { return "Atmos" }
        if codec == "dca", title.range(of: #"\bdts[:\-. ]?x\b"#, options: .regularExpression) != nil { return "DTS:X" }
        return nil
    }

    // MARK: - Subtitles

    /// A sidecar text file becomes an external track; its image formats are never offered (the
    /// conversion answers an empty 200). With no token the track has no URL: a detail page only
    /// lists, and the URL carries the live token.
    static func subtitleTrack(
        _ s: EmbyMediaStream, itemID: String, sourceID: String, defaultIndex: Int?, baseURL: URL, token: String?
    ) -> SubtitleTrack? {
        guard s.type == "Subtitle", let index = s.index else { return nil }
        let external = s.isExternal ?? false
        if external && s.isTextSubtitleStream != true { return nil }
        let format = sidecarFormat(s.codec)
        // Sidecar routes are anonymous, so a token-less detail source still carries the URL.
        let url: URL? = external ? EmbyClient.makeURL(
            base: baseURL, "Videos/\(itemID)/\(sourceID)/Subtitles/\(index)/0/Stream.\(format)",
            token.map { [URLQueryItem(name: "api_key", value: $0)] } ?? []
        ) : nil
        return SubtitleTrack(
            id: "\(index)",
            index: index,
            codec: external ? format : (s.codec?.lowercased() ?? "unknown"),
            language: language(s.language),
            title: s.title ?? s.displayTitle,
            extendedTitle: s.displayTitle,
            isDefault: s.isDefault ?? false,
            isForced: s.isForced ?? false,
            isHearingImpaired: s.isHearingImpaired ?? false,
            isEmbedded: !external,
            externalURL: url,
            isSelected: index == defaultIndex
        )
    }

    /// The `Stream.{format}` route converts on the fly. ASS keeps its styling for libass.
    static func sidecarFormat(_ codec: String?) -> String {
        switch codec?.lowercased() {
        case "ass", "ssa": "ass"
        case "vtt", "webvtt": "vtt"
        default: "srt"
        }
    }

    // MARK: - Media source

    /// The source id is opaque (`mediasource_<itemId>` on 4.9 and later, 32 hex on 4.8): a source
    /// without one is dropped, never given the item's id. With a token the source carries its direct
    /// URL, `Videos/{ItemId}/stream?static=true` with `api_key` (`ApiKey` is a 401 on Emby, and the
    /// player sends no headers); a transcode URL replaces it.
    static func mediaSource(
        _ src: EmbyMediaSource, itemID: String, playSessionID: String?, baseURL: URL, token: String?,
        transcodeURL: URL? = nil
    ) -> MediaSource? {
        guard let sourceID = src.id, !sourceID.isEmpty else { return nil }
        let streams = src.mediaStreams ?? []
        let owner = src.itemId?.value ?? itemID
        let direct: URL? = token.map {
            var query = [URLQueryItem(name: "static", value: "true"), URLQueryItem(name: "MediaSourceId", value: sourceID)]
            if let playSessionID { query.append(URLQueryItem(name: "PlaySessionId", value: playSessionID)) }
            query.append(URLQueryItem(name: "api_key", value: $0))
            return EmbyClient.makeURL(base: baseURL, "Videos/\(owner)/stream", query)
        }
        return MediaSource(
            id: sourceID,
            container: src.container,
            duration: EmbyTicks.seconds(src.runTimeTicks) ?? 0,
            bitrate: src.bitrate,
            fileSize: src.size,
            fileName: src.path.flatMap { $0.split(whereSeparator: { "/\\".contains($0) }).last.map(String.init) } ?? src.name,
            versionName: src.name,
            videoResolution: nil,
            videoTracks: streams.compactMap(videoTrack),
            audioTracks: streams.compactMap { audioTrack($0, defaultIndex: src.defaultAudioStreamIndex) },
            subtitleTracks: streams.compactMap {
                subtitleTrack($0, itemID: owner, sourceID: sourceID, defaultIndex: src.defaultSubtitleStreamIndex,
                              baseURL: baseURL, token: token)
            },
            streamKind: transcodeURL == nil ? .directPlay : .hlsTranscode,
            streamURL: transcodeURL ?? direct
        )
    }

    // MARK: - Markers

    /// Skip ranges from the item's own `Chapters`. Only `MarkerType` counts: names are never read
    /// ("Intro" with a plain `Chapter` type is a chapter), and a free server has none, so empty is
    /// the usual answer. An intro runs from `IntroStart` to the next `IntroEnd`; credits run to the end.
    static func markers(_ chapters: [EmbyChapter], runtime: TimeInterval?) -> [PlaybackMarker] {
        let marks = chapters.compactMap { chapter in
            EmbyTicks.seconds(chapter.startPositionTicks).map { (type: chapter.markerType, time: $0) }
        }.sorted { $0.time < $1.time }
        return marks.compactMap { mark -> PlaybackMarker? in
            switch mark.type {
            case "IntroStart":
                marks.first { $0.type == "IntroEnd" && $0.time > mark.time }
                    .map { PlaybackMarker(kind: .intro, start: mark.time, end: $0.time) }
            case "CreditsStart":
                runtime.flatMap { $0 > mark.time ? PlaybackMarker(kind: .credits, start: mark.time, end: $0) : nil }
            default:
                nil
            }
        }
    }
}
