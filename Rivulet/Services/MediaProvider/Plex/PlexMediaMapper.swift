// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexMediaMapper.swift
//  Rivulet
//
//  All `PlexMetadata` -> agnostic-type translations live here. The boundary
//  between Plex DTOs and the agnostic media layer.
//

import Foundation

enum PlexMediaMapper {

    // MARK: - Library

    static func library(_ section: PlexLibrary, providerID: String) -> MediaLibrary {
        let kind: MediaLibrary.LibraryKind
        switch section.type {
        case "movie": kind = .movies
        case "show": kind = .shows
        case "artist": kind = .music
        case "photo": kind = .photos
        default: kind = .mixed
        }
        return MediaLibrary(id: section.key, providerID: providerID, title: section.title, kind: kind)
    }

    // MARK: - Kind

    static func kind(_ type: String?) -> MediaKind {
        switch type {
        case "movie": return .movie
        case "show": return .show
        case "season": return .season
        case "episode": return .episode
        case "collection": return .collection
        default: return .unknown
        }
    }

    // MARK: - User state

    static func userState(_ meta: PlexMetadata) -> MediaUserState {
        MediaUserState(
            isPlayed: isFullyWatched(meta),
            viewOffset: TimeInterval(meta.viewOffset ?? 0) / 1000,
            isFavorite: PlexUserRating.isFavorite(meta.userRating),
            lastViewedAt: meta.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    /// `isPlayed` means FULLY watched, and Plex expresses that differently for
    /// containers than for leaves.
    ///
    /// On a show or season, `viewCount` is an aggregate over watched children,
    /// not a boolean — a season with 2 of 8 episodes watched reports
    /// `viewCount == 2`, so `viewCount > 0` marked the whole season played.
    /// Containers are only watched when every episode is
    /// (`viewedLeafCount >= leafCount`), the same rule `PlexMetadata.isWatched`
    /// uses.
    private static func isFullyWatched(_ meta: PlexMetadata) -> Bool {
        if meta.type == "show" || meta.type == "season" {
            guard let total = meta.leafCount, total > 0 else { return false }
            return (meta.viewedLeafCount ?? 0) >= total
        }
        return (meta.viewCount ?? 0) > 0
    }

    // MARK: - Artwork

    /// Helper for building Plex artwork URLs from arbitrary paths. Plex mixes
    /// absolute (CDN) and relative (server-path) thumbs in the same response, so
    /// pass absolute URLs through unchanged — concatenating serverURL onto them
    /// yields an invalid string that URL(string:) rejects.
    static func artworkURL(_ path: String?, serverURL: String, authToken: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        // A collection's composite poster carries its own query
        // (`/library/collections/{rk}/composite/{ts}?width=400&height=600`).
        // A second '?' folds the token into `height` and PMS answers 401.
        let separator = path.contains("?") ? "&" : "?"
        return URL(string: "\(serverURL)\(path)\(separator)X-Plex-Token=\(authToken)")
    }

    /// Build a tokenized URL for a PLAYABLE Plex key (a Part key, an extra key).
    ///
    /// Distinct from `artworkURL` because a playable key can carry its own query
    /// string — Plex's IVA extras arrive as
    /// `/services/iva/assets/715933/video.mp4?fmt=4&bitrate=5000`. Interpolating
    /// `"...\(key)?X-Plex-Token=..."` around that produces TWO '?', so the token
    /// is absorbed into the last parameter's value (`bitrate=5000?X-Plex-Token=…`)
    /// and never authenticates. Split the key and merge instead, matching
    /// ContentRouter.buildDirectPlayURL.
    static func playableURL(_ key: String?, serverURL: String, authToken: String) -> URL? {
        guard let key, !key.isEmpty else { return nil }
        guard var components = URLComponents(string: serverURL) else { return nil }

        let (path, inherited) = ContentRouter.splitPartKey(key)
        components.path = path
        components.queryItems = inherited + [URLQueryItem(name: "X-Plex-Token", value: authToken)]
        return components.url
    }

    /// Map a Plex Common Sense Media object → the agnostic `ContentAdvisory`.
    /// Works for both the LOCAL partial (age + oneLiner) and the full Discover
    /// object (adds parentsNeedToKnow + topics).
    static func contentAdvisory(from csm: PlexCommonSenseMedia) -> ContentAdvisory {
        let official = csm.officialAge
        let age = official?.age.map { "\(Int($0.rounded()))+" }
        let topics: [ContentAdvisory.Topic] = (csm.ParentalAdvisoryTopic ?? []).compactMap { t in
            guard let label = t.label, !label.isEmpty else { return nil }
            return ContentAdvisory.Topic(label: label, rating: t.rating.map { Int($0.rounded()) }, isPositive: t.positive ?? false)
        }
        return ContentAdvisory(
            ageRating: age,
            starRating: official?.rating,
            oneLiner: csm.oneLiner,
            parentsNeedToKnow: csm.parentsNeedToKnow,
            topics: topics
        )
    }

    static func artwork(_ meta: PlexMetadata, serverURL: String, authToken: String) -> MediaArtwork {
        MediaArtwork(
            poster: artworkURL(meta.thumb ?? meta.bestThumb, serverURL: serverURL, authToken: authToken),
            backdrop: artworkURL(meta.bestArt, serverURL: serverURL, authToken: authToken),
            thumbnail: artworkURL(meta.thumb, serverURL: serverURL, authToken: authToken),
            logo: artworkURL(meta.clearLogoPath, serverURL: serverURL, authToken: authToken)
        )
    }

    // MARK: - Tracks

    static func videoTrack(_ stream: PlexStream) -> VideoTrack? {
        guard stream.streamType == 1 else { return nil }
        let range: VideoTrack.VideoRange = {
            if stream.DOVIPresent == true {
                return .dolbyVision(profile: stream.DOVIProfile ?? 0)
            }
            if stream.colorTrc == "smpte2084" && stream.colorPrimaries == "bt2020" {
                return .hdr10
            }
            if stream.colorTrc == "arib-std-b67" {
                return .hlg
            }
            return .sdr
        }()
        return VideoTrack(
            id: "\(stream.id)",
            codec: stream.codec ?? "unknown",
            profile: stream.profile,
            level: stream.level,
            width: stream.width,
            height: stream.height,
            frameRate: stream.frameRate,
            bitrate: stream.bitrate,
            videoRange: range,
            isDefault: stream.default ?? false,
            scanType: stream.scanType
        )
    }

    static func audioTrack(_ stream: PlexStream) -> AudioTrack? {
        guard stream.streamType == 2 else { return nil }
        return AudioTrack(
            id: "\(stream.id)",
            index: stream.index ?? 0,
            codec: stream.codec ?? "unknown",
            profile: stream.profile,
            channels: stream.channels,
            channelLayout: stream.audioChannelLayout,
            language: stream.language,
            title: stream.displayTitle ?? stream.title,
            extendedTitle: stream.extendedDisplayTitle,
            bitrate: stream.bitrate,
            samplingRate: stream.samplingRate,
            isDefault: stream.default ?? false,
            isForced: stream.forced ?? false,
            isSelected: stream.selected ?? false
        )
    }

    static func subtitleTrack(_ stream: PlexStream, serverURL: String? = nil, authToken: String? = nil) -> SubtitleTrack? {
        guard stream.streamType == 3 else { return nil }
        let codec = stream.codec ?? stream.format ?? "unknown"
        let isEmbedded = stream.key == nil
        let externalURL: URL? = {
            guard !isEmbedded, let key = stream.key, let serverURL, let authToken else { return nil }
            return URL(string: "\(serverURL)\(key)?X-Plex-Token=\(authToken)")
        }()
        return SubtitleTrack(
            id: "\(stream.id)",
            index: stream.index ?? 0,
            codec: codec,
            language: stream.language,
            title: stream.title ?? stream.displayTitle,
            extendedTitle: stream.extendedDisplayTitle,
            isDefault: stream.default ?? false,
            isForced: stream.forced ?? false,
            isHearingImpaired: stream.hearingImpaired ?? false,
            isEmbedded: isEmbedded,
            externalURL: externalURL,
            isSelected: stream.selected ?? false
        )
    }

    // MARK: - Item

    static func item(
        _ meta: PlexMetadata,
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MediaItem {
        let ref = MediaItemRef(providerID: providerID, itemID: meta.ratingKey ?? "")
        let runtime: TimeInterval? = meta.duration.map { TimeInterval($0) / 1000 }
        let parentRef: MediaItemRef? = meta.parentRatingKey.map {
            MediaItemRef(providerID: providerID, itemID: $0)
        }
        let grandparentRef: MediaItemRef? = meta.grandparentRatingKey.map {
            MediaItemRef(providerID: providerID, itemID: $0)
        }
        // Hierarchy artwork — for episodes, the parent is a season and the
        // grandparent is the show; for seasons, the parent is the show.
        // Plex carries parentThumb / grandparentThumb / grandparentArt on
        // the child item directly, so no extra fetch needed.
        let parentArtwork: MediaArtwork? = {
            guard meta.parentThumb != nil else { return nil }
            return MediaArtwork(
                poster: artworkURL(meta.parentThumb, serverURL: serverURL, authToken: authToken),
                backdrop: nil,
                thumbnail: artworkURL(meta.parentThumb, serverURL: serverURL, authToken: authToken),
                logo: nil
            )
        }()

        let grandparentArtwork: MediaArtwork? = {
            guard meta.grandparentThumb != nil || meta.grandparentArt != nil else { return nil }
            return MediaArtwork(
                poster: artworkURL(meta.grandparentThumb, serverURL: serverURL, authToken: authToken),
                backdrop: artworkURL(meta.grandparentArt, serverURL: serverURL, authToken: authToken),
                thumbnail: artworkURL(meta.grandparentThumb, serverURL: serverURL, authToken: authToken),
                logo: nil
            )
        }()

        // Child progress — for shows / seasons, leafCount = total episodes,
        // viewedLeafCount = watched count.
        let childProgress: ChildProgress? = {
            if let total = meta.leafCount {
                return ChildProgress(played: meta.viewedLeafCount ?? 0, total: total)
            }
            return nil
        }()

        let mediaKind = kind(meta.type)
        let isMusic = ["artist", "album", "track"].contains(meta.type ?? "")
        // On Plex, `index` means different things per kind:
        //   - episode: index = episode number, parentIndex = season number
        //   - season:  index = season number, parentIndex = show (usually unused)
        //   - show:    neither applies
        // Mapping both fields unconditionally from (index, parentIndex) made
        // every season look like "Season 1" because `parentIndex` on a season
        // is the show's index, not the season number.
        let episodeNumber: Int? = (mediaKind == .episode) ? meta.index : nil
        let seasonNumber: Int? = {
            switch mediaKind {
            case .episode: return meta.parentIndex
            case .season: return meta.index
            default: return nil
            }
        }()

        return MediaItem(
            ref: ref,
            kind: mediaKind,
            title: meta.title ?? "",
            sortTitle: nil,
            overview: meta.summary,
            year: meta.year,
            releaseDate: meta.originallyAvailableAt,
            contentRating: meta.contentRating,
            runtime: runtime,
            isMusic: isMusic,
            parentRef: parentRef,
            grandparentRef: grandparentRef,
            seriesTitle: mediaKind == .episode ? meta.grandparentTitle
                : (mediaKind == .season ? meta.parentTitle : nil),
            episodeNumber: episodeNumber,
            seasonNumber: seasonNumber,
            childProgress: childProgress,
            userState: userState(meta),
            artwork: artwork(meta, serverURL: serverURL, authToken: authToken),
            parentArtwork: parentArtwork,
            grandparentArtwork: grandparentArtwork
        )
    }

    // MARK: - Media source

    static func mediaSource(
        _ media: PlexMedia,
        _ part: PlexPart,
        serverURL: String,
        authToken: String
    ) -> MediaSource {
        let videoTracks = (part.Stream ?? []).compactMap { videoTrack($0) }
        let audioTracks = (part.Stream ?? []).compactMap { audioTrack($0) }
        let subtitleTracks = (part.Stream ?? []).compactMap {
            subtitleTrack($0, serverURL: serverURL, authToken: authToken)
        }
        let url = playableURL(part.key, serverURL: serverURL, authToken: authToken)
        let durationMs = part.duration ?? media.duration ?? 0
        return MediaSource(
            id: "\(media.id)",
            container: part.container ?? media.container,
            duration: TimeInterval(durationMs) / 1000,
            bitrate: media.bitrate.map { $0 * 1000 },     // Plex bitrate is kbps
            fileSize: part.size.map { Int64($0) },
            fileName: part.file,
            videoResolution: media.videoResolution,
            videoTracks: videoTracks,
            audioTracks: audioTracks,
            subtitleTracks: subtitleTracks,
            streamKind: .directPlay,
            streamURL: url
        )
    }

    // MARK: - Detail

    static func detail(
        _ meta: PlexMetadata,
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MediaItemDetail {
        func personURL(_ thumb: String?) -> URL? {
            guard let thumb, !thumb.isEmpty else { return nil }
            // Plex people thumbs can be absolute (metadata CDN) or a relative
            // server path. Concatenating serverURL onto an absolute URL would
            // break it, so pass absolute ones through unchanged.
            if thumb.hasPrefix("http://") || thumb.hasPrefix("https://") {
                return URL(string: thumb)
            }
            return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
        }

        let titleTmdbId: Int? = (meta.Guid ?? []).compactMap { g -> Int? in
            guard let gid = g.id, gid.hasPrefix("tmdb://") else { return nil }
            return Int(gid.dropFirst("tmdb://".count))
        }.first
        let titleIsMovie = (meta.type == "movie")

        // Backdrop of the originating title — passed to each cast member so the
        // person detail page can render it as a blurred background. Uses the same
        // artworkURL helper as MediaArtwork.backdrop (meta.bestArt → server-relative
        // path + token, or absolute CDN URL passed through unchanged).
        let titleBackdropURL = artworkURL(meta.bestArt, serverURL: serverURL, authToken: authToken)

        let cast = (meta.Role ?? []).map { role in
            MediaPerson(
                id: role.id,
                name: role.tag ?? "",
                role: role.role,
                imageURL: personURL(role.thumb),
                tagKey: role.tagKey,
                originActorId: role.originActorId,
                originSectionKey: meta.librarySectionID.map(String.init),
                titleTmdbId: titleTmdbId,
                titleIsMovie: titleIsMovie,
                backdropURL: titleBackdropURL
            )
        }
        let directors = (meta.Director ?? []).map {
            MediaPerson(
                id: $0.id,
                name: $0.tag ?? "",
                role: nil,
                imageURL: personURL($0.thumb)
            )
        }
        let writers = (meta.Writer ?? []).map {
            MediaPerson(
                id: $0.id,
                name: $0.tag ?? "",
                role: nil,
                imageURL: personURL($0.thumb)
            )
        }
        let chapters = (meta.Chapter ?? []).map { ch in
            MediaChapter(
                id: "\(ch.id ?? 0)",
                title: ch.tag,
                start: TimeInterval(ch.startTimeOffset ?? 0) / 1000,
                end: ch.endTimeOffset.map { TimeInterval($0) / 1000 },
                thumbnailURL: personURL(ch.thumb)
            )
        }
        let mediaSources: [MediaSource] = (meta.Media ?? []).flatMap { media in
            (media.Part ?? []).map { part in
                mediaSource(media, part, serverURL: serverURL, authToken: authToken)
            }
        }
        let allExtras = meta.allExtras

        // Trailer button: first trailer. Disc rips (Kino Lorber, Criterion, etc.)
        // often bundle trailers for other films, so ideally we'd title-match, but
        // Plex doesn't include Media[].Part[] on extras in the metadata response
        // (hasLocalFile is always false), so we can't distinguish IVA streams from
        // local files at this layer. Use first trailer as-is for now.
        let trailerURL: URL? = allExtras
            .first(where: { ExtraSubtype.from(subtype: $0.subtype, extraType: $0.extraType).isTrailer })
            .flatMap { $0.key }
            .flatMap { playableURL($0, serverURL: serverURL, authToken: authToken) }

        let extras: [MediaItemDetail.Extra] = allExtras.enumerated().map { idx, ex in
            MediaItemDetail.Extra(
                id: ex.ratingKey ?? ex.key ?? "extra-\(idx)",
                title: ex.title ?? "Extra",
                thumbnailURL: artworkURL(ex.thumb, serverURL: serverURL, authToken: authToken),
                duration: ex.duration.map { TimeInterval($0) / 1000 },
                playbackKey: ex.key ?? ex.ratingKey,
                subtype: ExtraSubtype.from(subtype: ex.subtype, extraType: ex.extraType)
            )
        }
        .sorted { $0.subtype < $1.subtype }

        // Next episode for shows — Plex bakes this into `OnDeck` on the show's
        // metadata. Map the first OnDeck Metadata entry to a MediaItem.
        let nextEpisode: MediaItem? = meta.OnDeck?.Metadata?.first.map {
            item($0, providerID: providerID, serverURL: serverURL, authToken: authToken)
        }
        let collections = (meta.Collection ?? []).compactMap(\.tag)

        return MediaItemDetail(
            item: item(meta, providerID: providerID, serverURL: serverURL, authToken: authToken),
            tagline: meta.tagline,
            genres: meta.Genre?.compactMap(\.tag) ?? [],
            studios: meta.studio.map { [$0] } ?? [],
            cast: cast,
            directors: directors,
            writers: writers,
            chapters: chapters,
            mediaSources: mediaSources,
            trailerURL: trailerURL,
            contentRating: meta.contentRating,
            regionOfOrigin: meta.Country?.first?.tag,
            rating: Self.rating(meta),
            nextEpisode: nextEpisode,
            collections: collections,
            extras: extras,
            contentAdvisory: meta.CommonSenseMedia?.first.map(Self.contentAdvisory(from:)),
            externalIDs: externalIDs(meta.Guid)
        )
    }

    /// `rating` is the critic score and `audienceRating` the audience score,
    /// each tagged by an image URI naming its source
    /// ("rottentomatoes://image.rating.ripe", "imdb://image.rating",
    /// "themoviedb://image.rating"). Legacy agents send `rating` with no image.
    static func rating(_ meta: PlexMetadata) -> MediaRating? {
        func source(_ image: String?) -> MediaRating.Source {
            switch image?.split(separator: ":").first {
            case "rottentomatoes": .rottenTomatoes
            case "imdb": .imdb
            case "themoviedb": .tmdb
            default: .unknown
            }
        }
        return MediaRating.preferred(
            critic: MediaRating(meta.rating, source: source(meta.ratingImage)),
            audience: MediaRating(meta.audienceRating, source: source(meta.audienceRatingImage))
        )
    }

    /// `Guid` ids ("tmdb://603", "imdb://tt0133093", "tvdb://169") keyed
    /// lowercase, parsed by PlexMetadata's guid helpers. First match wins.
    static func externalIDs(_ guids: [PlexGuid]?) -> [String: String] {
        var out: [String: String] = [:]
        for raw in (guids ?? []).compactMap(\.id) {
            if out["tmdb"] == nil, let id = PlexMetadata.extractTmdbId(from: raw) { out["tmdb"] = String(id) }
            if out["tvdb"] == nil, let id = PlexMetadata.extractTvdbId(from: raw) { out["tvdb"] = String(id) }
            if out["imdb"] == nil, let id = PlexMetadata.extractImdbId(from: raw) { out["imdb"] = id }
        }
        return out
    }

    // MARK: - Hub

    static func hub(
        _ hub: PlexHub,
        providerID: String,
        serverURL: String,
        authToken: String
    ) -> MediaHub {
        let style: MediaHub.HubStyle = {
            switch hub.type {
            case "hero": return .hero
            case "clip": return .clip
            default: return .shelf
            }
        }()
        let items = (hub.Metadata ?? []).map {
            item($0, providerID: providerID, serverURL: serverURL, authToken: authToken)
        }
        return MediaHub(
            id: hub.id,
            providerID: providerID,
            title: hub.title ?? "",
            style: style,
            items: items
        )
    }
}
