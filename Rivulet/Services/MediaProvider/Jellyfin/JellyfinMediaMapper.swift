// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinMediaMapper.swift
//  Rivulet
//
//  Jellyfin DTOs -> agnostic Media types. The Jellyfin twin of
//  PlexMediaMapper: same field conventions, so a Jellyfin MediaItem renders
//  through the same cells, carousel and detail page with no view changes.
//

import Foundation

enum JellyfinMediaMapper {

    // MARK: - Library

    /// Library views Rivulet can render. Book, playlist, box set and trailer
    /// views have no surface, so they are dropped rather than shown empty.
    static func library(_ view: JFItem, providerID: String) -> MediaLibrary? {
        guard let id = view.id else { return nil }
        let kind: MediaLibrary.LibraryKind
        switch view.collectionType {
        case "movies": kind = .movies
        case "tvshows": kind = .shows
        case "music": kind = .music
        case "photos": kind = .photos
        case "livetv": kind = .liveTV
        case nil, "homevideos", "mixed", "folders", "unknown": kind = .mixed
        default: return nil
        }
        return MediaLibrary(id: id, providerID: providerID, title: view.name ?? "", kind: kind)
    }

    // MARK: - Kind

    static func kind(_ type: String?) -> MediaKind {
        switch type {
        case "Movie": return .movie
        case "Series": return .show
        case "Season": return .season
        case "Episode": return .episode
        case "BoxSet": return .collection
        case "Person": return .person
        default: return .unknown
        }
    }

    // MARK: - User state

    static func userState(_ dto: JFItem) -> MediaUserState {
        let data = dto.userData
        return MediaUserState(
            isPlayed: data?.played ?? false,
            viewOffset: JellyfinTicks.seconds(data?.playbackPositionTicks) ?? 0,
            isFavorite: data?.isFavorite ?? false,
            lastViewedAt: data?.lastPlayedDate.flatMap { parseDate($0) }
        )
    }

    /// Jellyfin writes 7 fractional digits ("2024-05-11T12:34:56.1234567Z").
    static func parseDate(_ string: String) -> Date? {
        try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string)
    }

    // MARK: - Artwork

    /// Image endpoints are anonymous, so no token goes in the URL (and none
    /// ends up in the image cache's keys). `tag` makes the URL change when the
    /// image does. No size parameters: Plex artwork is served full size too.
    static func imageURL(_ baseURL: URL, itemID: String?, type: String, tag: String?) -> URL? {
        guard let itemID, let tag else { return nil }
        var components = URLComponents(
            url: baseURL.appending(path: "Items/\(itemID)/Images/\(type)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "tag", value: tag)]
        return components?.url
    }

    static func artwork(_ dto: JFItem, baseURL: URL) -> MediaArtwork {
        let primary = imageURL(baseURL, itemID: dto.id, type: "Primary", tag: dto.imageTags?["Primary"])
        let backdrop = imageURL(baseURL, itemID: dto.id, type: "Backdrop", tag: dto.backdropImageTags?.first)
            ?? imageURL(baseURL, itemID: dto.parentBackdropItemId, type: "Backdrop",
                        tag: dto.parentBackdropImageTags?.first)
        let logo = imageURL(baseURL, itemID: dto.id, type: "Logo", tag: dto.imageTags?["Logo"])
            ?? imageURL(baseURL, itemID: dto.parentLogoItemId, type: "Logo", tag: dto.parentLogoImageTag)
        return MediaArtwork(poster: primary, backdrop: backdrop, thumbnail: primary, logo: logo)
    }

    // MARK: - Item

    static func item(_ dto: JFItem, providerID: String, baseURL: URL) -> MediaItem {
        let mediaKind = kind(dto.type)
        func ref(_ id: String?) -> MediaItemRef? { id.map { MediaItemRef(providerID: providerID, itemID: $0) } }

        // Only episodes and seasons have a meaningful parent. A movie's
        // ParentId is its library folder, which must not become a parentRef.
        let parentRef: MediaItemRef? = switch mediaKind {
        case .episode: ref(dto.seasonId ?? dto.parentId)
        case .season: ref(dto.seriesId ?? dto.parentId)
        default: nil
        }
        let grandparentRef: MediaItemRef? = mediaKind == .episode ? ref(dto.seriesId) : nil

        let parentArtwork: MediaArtwork? = {
            guard mediaKind == .episode || mediaKind == .season,
                  let poster = imageURL(baseURL, itemID: dto.parentPrimaryImageItemId, type: "Primary",
                                        tag: dto.parentPrimaryImageTag)
            else { return nil }
            return MediaArtwork(poster: poster, backdrop: nil, thumbnail: poster, logo: nil)
        }()
        let grandparentArtwork: MediaArtwork? = {
            guard mediaKind == .episode else { return nil }
            let poster = imageURL(baseURL, itemID: dto.seriesId, type: "Primary", tag: dto.seriesPrimaryImageTag)
            let backdrop = imageURL(baseURL, itemID: dto.parentBackdropItemId, type: "Backdrop",
                                    tag: dto.parentBackdropImageTags?.first)
            guard poster != nil || backdrop != nil else { return nil }
            return MediaArtwork(poster: poster, backdrop: backdrop, thumbnail: poster, logo: nil)
        }()

        // Folder counts need Fields=RecursiveItemCount; UnplayedItemCount is
        // total minus played, computed per user by the server.
        let childProgress: ChildProgress? = {
            guard mediaKind == .show || mediaKind == .season, let total = dto.recursiveItemCount else { return nil }
            let unplayed = dto.userData?.unplayedItemCount ?? total
            return ChildProgress(played: max(0, total - unplayed), total: total)
        }()

        return MediaItem(
            ref: MediaItemRef(providerID: providerID, itemID: dto.id ?? ""),
            kind: mediaKind,
            title: dto.name ?? "",
            sortTitle: dto.sortName,
            overview: dto.overview,
            year: dto.productionYear,
            releaseDate: dto.premiereDate.map { String($0.prefix(10)) },
            contentRating: dto.officialRating,
            runtime: JellyfinTicks.seconds(dto.runTimeTicks),
            isMusic: ["MusicAlbum", "MusicArtist", "Audio"].contains(dto.type ?? ""),
            parentRef: parentRef,
            grandparentRef: grandparentRef,
            seriesTitle: mediaKind == .episode || mediaKind == .season ? dto.seriesName : nil,
            episodeNumber: mediaKind == .episode ? dto.indexNumber : nil,
            seasonNumber: mediaKind == .episode ? dto.parentIndexNumber
                : (mediaKind == .season ? dto.indexNumber : nil),
            childProgress: childProgress,
            userState: userState(dto),
            artwork: artwork(dto, baseURL: baseURL),
            parentArtwork: parentArtwork,
            grandparentArtwork: grandparentArtwork
        )
    }

    // MARK: - Tracks
    //
    // Jellyfin numbers a source's streams with its external files first
    // (sidecar subtitles, then sidecar audio) and the container's own streams
    // after them (FFProbeVideoInfo). The engine joins tracks to this metadata
    // on the container stream index, so an embedded track's `index` is
    // Jellyfin's Index minus the number of external streams. The track `id`
    // keeps Jellyfin's Index: playback reports and stream selection speak it.

    static func videoTrack(_ s: JFMediaStream) -> VideoTrack? {
        guard s.type == "Video", let index = s.index else { return nil }
        let range: VideoTrack.VideoRange = switch s.videoRangeType {
        case "DOVIInvalid": baseLayerRange(s.colorTransfer)
        case let t? where t.hasPrefix("DOVI"): .dolbyVision(profile: s.dvProfile ?? 0)
        case "HDR10": .hdr10
        case "HDR10Plus": .hdr10Plus
        case "HLG": .hlg
        default: .sdr
        }
        return VideoTrack(
            id: "\(index)",
            codec: s.codec ?? "unknown",
            profile: s.profile,
            level: s.level.map { Int($0) },
            width: s.width,
            height: s.height,
            frameRate: s.realFrameRate ?? s.averageFrameRate,
            bitrate: s.bitRate,
            videoRange: range,
            isDefault: s.isDefault ?? false,
            scanType: s.isInterlaced.map { $0 ? "interlaced" : "progressive" }
        )
    }

    /// Out-of-spec Dolby Vision keeps its base layer's range on the server
    /// (`MediaStream.GetVideoColorRange`), so read it off the transfer function.
    static func baseLayerRange(_ colorTransfer: String?) -> VideoTrack.VideoRange {
        switch colorTransfer {
        case "smpte2084": .hdr10
        case "arib-std-b67": .hlg
        default: .sdr
        }
    }

    /// Sidecar audio files are dropped: they are not in the container, so
    /// the engine never sees them.
    static func audioTrack(_ s: JFMediaStream, defaultIndex: Int?, externalCount: Int) -> AudioTrack? {
        guard s.type == "Audio", let index = s.index, s.isExternal != true else { return nil }
        // AudioTrack.qualityLabel speaks Plex: DTS is "dca", Atmos is a word in
        // the profile. Translate here so the badge reads the same on both.
        let codec = s.codec == "dts" ? "dca" : (s.codec ?? "unknown")
        let atmos = s.audioSpatialFormat == "DolbyAtmos" ? "Atmos" : nil
        let profile = [s.profile, atmos].compactMap { $0 }.joined(separator: " ")
        return AudioTrack(
            id: "\(index)",
            index: index - externalCount,
            codec: codec,
            profile: profile.isEmpty ? nil : profile,
            channels: s.channels,
            channelLayout: s.channelLayout,
            language: s.language,
            title: s.title ?? s.displayTitle,
            extendedTitle: s.displayTitle,
            bitrate: s.bitRate,
            samplingRate: s.sampleRate,
            isDefault: s.isDefault ?? false,
            isForced: s.isForced ?? false,
            isSelected: index == defaultIndex
        )
    }

    /// External image subtitles (sidecar .sup/.sub) are dropped: the sidecar
    /// path only carries text formats. A sidecar keeps Jellyfin's Index: it is
    /// in the stream URL, and sidecars never join on index (`MediaTrack`).
    static func subtitleTrack(
        _ s: JFMediaStream, itemID: String, sourceID: String, defaultIndex: Int?, externalCount: Int, baseURL: URL
    ) -> SubtitleTrack? {
        guard s.type == "Subtitle", let index = s.index else { return nil }
        let external = s.isExternal ?? false
        if external && s.isTextSubtitleStream != true { return nil }
        let externalURL: URL? = external
            ? baseURL.appending(path: "Videos/\(itemID)/\(sourceID)/Subtitles/\(index)/Stream.\(sidecarFormat(s.codec))")
            : nil
        return SubtitleTrack(
            id: "\(index)",
            index: external ? index : index - externalCount,
            codec: s.codec ?? "unknown",
            language: s.language,
            title: s.title ?? s.displayTitle,
            extendedTitle: s.displayTitle,
            isDefault: s.isDefault ?? false,
            isForced: s.isForced ?? false,
            isHearingImpaired: s.isHearingImpaired ?? false,
            isEmbedded: !external,
            externalURL: externalURL,
            isSelected: index == defaultIndex
        )
    }

    /// The Stream.{format} endpoint converts on the fly. ASS keeps its styling
    /// for libass; everything else comes down as SRT.
    static func sidecarFormat(_ codec: String?) -> String {
        switch codec?.lowercased() {
        case "ass", "ssa": return "ass"
        case "vtt", "webvtt": return "vtt"
        default: return "srt"
        }
    }

    // MARK: - Media source

    /// `streamURL` is the static file stream: byte ranges, no server work.
    /// `ApiKey=` is not required by /Videos/{id}/stream today but is the one
    /// query-token form 12.x accepts, so the URL keeps working for players
    /// that cannot send headers (AVPlayer) if that endpoint is locked down.
    static func mediaSource(
        _ src: JFMediaSource, itemID: String, playSessionID: String?, baseURL: URL, token: String,
        transcodeURL: URL? = nil
    ) -> MediaSource {
        let sourceID = src.id ?? itemID
        let streams = src.mediaStreams ?? []
        let externalCount = streams.filter { $0.isExternal == true }.count
        var query = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: sourceID)
        ]
        if let playSessionID { query.append(URLQueryItem(name: "playSessionId", value: playSessionID)) }
        query.append(URLQueryItem(name: "ApiKey", value: token))
        var components = URLComponents(
            url: baseURL.appending(path: "Videos/\(itemID)/stream"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = query

        return MediaSource(
            id: sourceID,
            container: src.container,
            duration: JellyfinTicks.seconds(src.runTimeTicks) ?? 0,
            bitrate: src.bitrate,
            fileSize: src.size,
            fileName: src.name,
            videoResolution: nil,
            videoTracks: streams.compactMap { videoTrack($0) },
            audioTracks: streams.compactMap {
                audioTrack($0, defaultIndex: src.defaultAudioStreamIndex, externalCount: externalCount)
            },
            subtitleTracks: streams.compactMap {
                subtitleTrack($0, itemID: itemID, sourceID: sourceID, defaultIndex: src.defaultSubtitleStreamIndex,
                              externalCount: externalCount, baseURL: baseURL)
            },
            streamKind: transcodeURL == nil ? .directPlay : .hlsTranscode,
            streamURL: transcodeURL ?? components?.url
        )
    }

    // MARK: - Detail

    static func detail(
        _ dto: JFItem, nextEpisode: JFItem?, providerID: String, baseURL: URL, token: String
    ) -> MediaItemDetail {
        let item = item(dto, providerID: providerID, baseURL: baseURL)
        let itemID = dto.id ?? ""
        let tmdbID = dto.providerIds?["Tmdb"].flatMap { Int($0) }
        let backdrop = item.artwork.backdrop

        func people(_ kinds: Set<String>) -> [MediaPerson] {
            (dto.people ?? []).filter { kinds.contains($0.type ?? "") }.compactMap { p in
                guard let id = p.id else { return nil }
                return MediaPerson(
                    id: id,
                    name: p.name ?? "",
                    role: p.role,
                    imageURL: imageURL(baseURL, itemID: id, type: "Primary", tag: p.primaryImageTag),
                    titleTmdbId: tmdbID,
                    titleIsMovie: dto.type == "Movie",
                    backdropURL: backdrop
                )
            }
        }

        let rawChapters = dto.chapters ?? []
        let chapters = rawChapters.enumerated().map { i, c in
            MediaChapter(
                id: "\(i)",
                title: c.name,
                start: JellyfinTicks.seconds(c.startPositionTicks) ?? 0,
                end: i + 1 < rawChapters.count ? JellyfinTicks.seconds(rawChapters[i + 1].startPositionTicks) : nil,
                thumbnailURL: c.imageTag.flatMap {
                    imageURL(baseURL, itemID: itemID, type: "Chapter/\(i)", tag: $0)
                }
            )
        }

        return MediaItemDetail(
            item: item,
            tagline: dto.taglines?.first,
            genres: dto.genres ?? [],
            studios: (dto.studios ?? []).compactMap(\.name),
            cast: people(["Actor", "GuestStar"]),
            directors: people(["Director"]),
            writers: people(["Writer"]),
            chapters: chapters,
            mediaSources: (dto.mediaSources ?? []).map {
                mediaSource($0, itemID: itemID, playSessionID: nil, baseURL: baseURL, token: token)
            },
            trailerURL: nil,
            contentRating: dto.officialRating,
            regionOfOrigin: dto.productionLocations?.first,
            rating: dto.communityRating,
            nextEpisode: nextEpisode.map { self.item($0, providerID: providerID, baseURL: baseURL) },
            collections: [],
            externalIDs: externalIDs(dto.providerIds)
        )
    }

    /// Jellyfin's ProviderIds ("Tmdb", "Imdb", "Tvdb") keyed lowercase.
    static func externalIDs(_ ids: [String: String]?) -> [String: String] {
        var out: [String: String] = [:]
        for key in ["Tmdb", "Imdb", "Tvdb"] {
            if let value = ids?[key], !value.isEmpty { out[key.lowercased()] = value }
        }
        return out
    }
}
