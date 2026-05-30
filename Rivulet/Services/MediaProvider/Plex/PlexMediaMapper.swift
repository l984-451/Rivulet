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

    /// Loose title-match used by the header Trailer button to gate on
    /// "is this trailer actually for the feature?": normalizes case,
    /// strips leading articles + non-alphanumerics, and checks substring
    /// either direction so "7 Faces of Dr. Lao (1964) - Theatrical Trailer"
    /// matches feature "7 Faces of Dr. Lao". Returns false on either-nil.
    static func titlesMatch(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        let na = normalizedTitle(a)
        let nb = normalizedTitle(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        return na.contains(nb) || nb.contains(na)
    }

    static func normalizedTitle(_ s: String) -> String {
        var t = s.lowercased()
        for prefix in ["the ", "a ", "an "] where t.hasPrefix(prefix) {
            t.removeFirst(prefix.count)
        }
        let scalars = t.unicodeScalars.map { sc -> Character in
            if CharacterSet.alphanumerics.contains(sc) { return Character(sc) }
            return " "
        }
        let compact = String(scalars).split(separator: " ").joined(separator: " ")
        return compact
    }

    static func kind(_ type: String?) -> MediaKind {
        switch type {
        case "movie": return .movie
        case "show": return .show
        case "season": return .season
        case "episode": return .episode
        case "collection": return .collection
        // Extras come back as type=="clip"; they're single-video items with
        // their own Media block, indistinguishable from movies for routing /
        // playback / detail-page rendering. Classifying as .movie lets them
        // re-use the movie code path everywhere (detail view, action row,
        // audio/subtitle pickers, WT, etc.) without a new case.
        case "clip": return .movie
        default: return .unknown
        }
    }

    // MARK: - User state

    static func userState(_ meta: PlexMetadata) -> MediaUserState {
        MediaUserState(
            isPlayed: (meta.viewCount ?? 0) > 0,
            viewOffset: TimeInterval(meta.viewOffset ?? 0) / 1000,
            isFavorite: (meta.userRating ?? 0) > 0,
            lastViewedAt: meta.lastViewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    // MARK: - Artwork

    /// Helper for building Plex artwork URLs from arbitrary paths.
    static func artworkURL(_ path: String?, serverURL: String, authToken: String) -> URL? {
        guard let path else { return nil }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(authToken)")
    }

    static func artwork(_ meta: PlexMetadata, serverURL: String, authToken: String) -> MediaArtwork {
        // For clip-type items (Plex extras: trailers, featurettes, behind-the-
        // scenes, etc.) Plex has no per-clip `art` field, so `bestArt` falls
        // back to grandparentArt (the parent movie's backdrop). Source the
        // extra's backdrop from its own thumb (a frame of the extra video)
        // so the pushed detail page represents the extra itself.
        let backdropSource: String? = (meta.type == "clip") ? meta.thumb : meta.bestArt
        return MediaArtwork(
            poster: artworkURL(meta.thumb ?? meta.bestThumb, serverURL: serverURL, authToken: authToken),
            backdrop: artworkURL(backdropSource, serverURL: serverURL, authToken: authToken),
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
            isDefault: stream.default ?? false
        )
    }

    static func audioTrack(_ stream: PlexStream) -> AudioTrack? {
        guard stream.streamType == 2 else { return nil }
        return AudioTrack(
            id: "\(stream.id)",
            index: stream.index ?? 0,
            codec: stream.codec ?? "unknown",
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
            runtime: runtime,
            parentRef: parentRef,
            grandparentRef: grandparentRef,
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
        let url = URL(string: "\(serverURL)\(part.key)?X-Plex-Token=\(authToken)")
        let durationMs = part.duration ?? media.duration ?? 0
        return MediaSource(
            id: "\(media.id)",
            container: part.container ?? media.container,
            duration: TimeInterval(durationMs) / 1000,
            bitrate: media.bitrate.map { $0 * 1000 },     // Plex bitrate is kbps
            fileSize: part.size.map { Int64($0) },
            fileName: part.file,
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
            guard let thumb else { return nil }
            return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
        }

        let cast = (meta.Role ?? []).map { role in
            MediaPerson(
                id: role.id,
                name: role.tag ?? "",
                role: role.role,
                imageURL: personURL(role.thumb)
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
        // Plex inlines `Media[].Part[]` on each Extras entry. User-added extras
        // (files under /Volumes/...) carry a Part.file path; Plex's IVA-supplied
        // extras stream from /services/iva/assets/... and have no file. We only
        // surface user-added extras; IVA streams are low quality and not what
        // we want in the carousel.
        let localExtras = (meta.Extras?.Metadata ?? []).filter(\.hasLocalFile)
        let extras: [MediaExtra] = localExtras.compactMap { ex in
            guard let rk = ex.ratingKey else { return nil }
            return MediaExtra(
                id: rk,
                title: ex.title ?? "",
                subtype: ExtraSubtype.fromPlex(subtype: ex.subtype, extraType: ex.extraType),
                durationSec: ex.duration.map { $0 / 1000 },
                thumbURL: personURL(ex.thumb)
            )
        }
        .sorted { $0.subtype < $1.subtype }
        // type=="clip" matches every extra (trailers, featurettes, BTS all share
        // type=clip), so OR-ing it in caused the Trailer button to fall through
        // to the first non-trailer extra when no trailer was present. Restrict
        // to the subtype check so the button either points at a real trailer or
        // doesn't render.
        //
        // Disc-rip extras directories often contain trailers for OTHER films
        // alongside the feature (Kino Lorber, Criterion, etc.), so require the
        // trailer's title to match the feature item's title before using it for
        // the header Trailer button. The trailers still appear in the Extras
        // row regardless; this gate is only for the dedicated action button so
        // it doesn't promise a feature trailer it can't deliver.
        let trailerURL: URL? = localExtras
            .first(where: { $0.subtype == "trailer" && titlesMatch($0.title, meta.title) })
            .flatMap { $0.key }
            .flatMap { URL(string: "\(serverURL)\($0)?X-Plex-Token=\(authToken)") }

        // Next episode for shows — Plex bakes this into `OnDeck` on the show's
        // metadata. Map the first OnDeck Metadata entry to a MediaItem.
        let nextEpisode: MediaItem? = meta.OnDeck?.Metadata?.first.map {
            item($0, providerID: providerID, serverURL: serverURL, authToken: authToken)
        }
        let collections = (meta.Collection ?? []).compactMap(\.tag)

        let extraSubtype: ExtraSubtype? = (meta.type == "clip")
            ? ExtraSubtype.fromPlex(subtype: meta.subtype, extraType: meta.extraType)
            : nil

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
            extras: extras,
            contentRating: meta.contentRating,
            rating: meta.rating,
            nextEpisode: nextEpisode,
            collections: collections,
            extraSubtype: extraSubtype
        )
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
