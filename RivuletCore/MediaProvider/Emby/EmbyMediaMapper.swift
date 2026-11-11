// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyMediaMapper.swift
//  Rivulet
//
//  Emby DTOs -> agnostic Media types. The Emby twin of JellyfinMediaMapper: same
//  field conventions, so an Emby MediaItem renders through the same cells and detail
//  page. Media sources, tracks and markers are in EmbyMediaMapper+Sources.swift.
//

import Foundation

enum EmbyMediaMapper {

    // MARK: - Library

    /// Library views Rivulet can render. Box set and playlist views are dropped: collections
    /// and playlists have their own surfaces. A view with no `CollectionType` is mixed.
    /// Types never seen on a real server (books, games, live TV, channels) are skipped.
    static func library(_ view: EmbyItem, providerID: String, homeVideos: HomeVideosContent = .videos) -> MediaLibrary? {
        let kind: MediaLibrary.LibraryKind
        switch view.collectionType {
        case "movies": kind = .movies
        case "tvshows": kind = .shows
        case "music": kind = .music
        // The photo browser's only when the view holds photos, so a video-only one keeps the video page.
        case "homevideos": kind = homeVideos == .photosOnly ? .photos : .mixed
        case nil, "musicvideos": kind = .mixed
        default: return nil
        }
        var library = MediaLibrary(id: view.id.value, providerID: providerID, title: view.name, kind: kind)
        library.browsesByFolder = kind == .mixed
        return library
    }

    // MARK: - Kind

    static func kind(_ type: String?) -> MediaKind {
        switch type {
        case "Movie", "Video", "MusicVideo": return .movie
        case "Series": return .show
        case "Season": return .season
        case "Episode": return .episode
        case "BoxSet": return .collection
        case "Playlist": return .playlist
        case "Person": return .person
        default: return .unknown
        }
    }

    // MARK: - User state

    static func userState(_ dto: EmbyItem) -> MediaUserState {
        let data = dto.userData
        return MediaUserState(
            isPlayed: data?.played ?? false,
            viewOffset: EmbyTicks.seconds(data?.playbackPositionTicks) ?? 0,
            isFavorite: data?.isFavorite ?? false,
            lastViewedAt: EmbyJSON.date(data?.lastPlayedDate)
        )
    }

    // MARK: - Artwork

    /// Image routes are anonymous: no token goes in the URL (a stale `api_key` turns the
    /// image's 200 into a 401, and the token would land in the image cache's keys). `Tag`
    /// only sets cache headers. No size parameters, as for Plex artwork.
    static func imageURL(_ baseURL: URL, itemID: EmbyID?, type: String, tag: String?) -> URL? {
        guard let itemID, let tag else { return nil }
        return EmbyClient.makeURL(base: baseURL, "Items/\(itemID.value)/Images/\(type)", [URLQueryItem(name: "Tag", value: tag)])
    }

    static func artwork(_ dto: EmbyItem, baseURL: URL) -> MediaArtwork {
        // An album or photo album has no image of its own; it names a child's.
        let primary = imageURL(baseURL, itemID: dto.id, type: "Primary", tag: dto.imageTags?["Primary"])
            ?? imageURL(baseURL, itemID: dto.primaryImageItemId, type: "Primary", tag: dto.primaryImageTag)
            ?? (dto.type == "Season"
                ? imageURL(baseURL, itemID: dto.seriesId, type: "Primary", tag: dto.seriesPrimaryImageTag) : nil)
        let backdrop = dto.type == "Playlist"
            ? primary
            : imageURL(baseURL, itemID: dto.id, type: "Backdrop", tag: dto.backdropImageTags?.first)
                ?? imageURL(baseURL, itemID: dto.parentBackdropItemId, type: "Backdrop",
                            tag: dto.parentBackdropImageTags?.first)
        let logo = imageURL(baseURL, itemID: dto.id, type: "Logo", tag: dto.imageTags?["Logo"])
            ?? imageURL(baseURL, itemID: dto.parentLogoItemId, type: "Logo", tag: dto.parentLogoImageTag)
        return MediaArtwork(poster: primary, backdrop: backdrop, thumbnail: primary, logo: logo)
    }

    // MARK: - Item

    /// `childProgress` replaces the list-level progress; the detail page passes the exact one.
    static func item(
        _ dto: EmbyItem, providerID: String, baseURL: URL, childProgress override: ChildProgress? = nil
    ) -> MediaItem {
        let mediaKind = kind(dto.type)
        func ref(_ id: EmbyID?) -> MediaItemRef? { id.map { MediaItemRef(providerID: providerID, itemID: $0.value) } }

        // Only episodes and seasons have a meaningful parent. A movie's ParentId is its folder.
        let parentRef: MediaItemRef? = switch mediaKind {
        case .episode: ref(dto.seasonId ?? dto.parentId)
        case .season: ref(dto.seriesId ?? dto.parentId)
        default: nil
        }
        let grandparentRef: MediaItemRef? = mediaKind == .episode ? ref(dto.seriesId) : nil

        // A season's parent art is its show's poster. An episode's season art is not on the item.
        let seriesPoster = imageURL(baseURL, itemID: dto.seriesId, type: "Primary", tag: dto.seriesPrimaryImageTag)
        let showLogo = imageURL(baseURL, itemID: dto.parentLogoItemId, type: "Logo", tag: dto.parentLogoImageTag)
        let parentArtwork: MediaArtwork? = mediaKind == .season ? seriesPoster.map {
            MediaArtwork(poster: $0, backdrop: nil, thumbnail: $0, logo: showLogo)
        } : nil
        let grandparentArtwork: MediaArtwork? = {
            guard mediaKind == .episode else { return nil }
            let backdrop = imageURL(baseURL, itemID: dto.parentBackdropItemId, type: "Backdrop",
                                    tag: dto.parentBackdropImageTags?.first)
            guard seriesPoster != nil || backdrop != nil || showLogo != nil else { return nil }
            return MediaArtwork(poster: seriesPoster, backdrop: backdrop, thumbnail: seriesPoster, logo: showLogo)
        }()

        return MediaItem(
            ref: MediaItemRef(providerID: providerID, itemID: dto.id.value),
            kind: mediaKind,
            title: dto.name,
            sortTitle: dto.sortName,
            overview: dto.overview,
            year: dto.productionYear,
            releaseDate: dto.premiereDate.flatMap { $0.hasPrefix("0001-") ? nil : String($0.prefix(10)) },
            contentRating: dto.officialRating,
            runtime: EmbyTicks.seconds(dto.runTimeTicks),
            isMusic: ["MusicAlbum", "MusicArtist", "Audio"].contains(dto.type),
            parentRef: parentRef,
            grandparentRef: grandparentRef,
            seriesTitle: mediaKind == .episode || mediaKind == .season ? dto.seriesName : nil,
            episodeNumber: mediaKind == .episode ? dto.indexNumber : nil,
            seasonNumber: mediaKind == .episode ? dto.parentIndexNumber
                : (mediaKind == .season ? dto.indexNumber : nil),
            childProgress: override ?? childProgress(dto, kind: mediaKind),
            userState: userState(dto),
            artwork: artwork(dto, baseURL: baseURL),
            parentArtwork: parentArtwork,
            grandparentArtwork: grandparentArtwork,
            versionCount: dto.mediaSources.flatMap { $0.count > 1 ? $0.count : nil },
            genres: (dto.genres ?? []).isEmpty ? nil : dto.genres,
            externalIDs: externalIDs(dto).nilIfEmpty
        )
    }

    /// A season's `RecursiveItemCount` is its episodes, so total minus unplayed is exact.
    /// A show's is not: `UnplayedItemCount` leaves out Season 0 but `RecursiveItemCount` counts it,
    /// so the subtraction reports one watched on an untouched show with a special. Lists carry
    /// the unplayed count alone (all the poster pill reads); `showProgress` sums the seasons for the detail page.
    static func childProgress(_ dto: EmbyItem, kind: MediaKind) -> ChildProgress? {
        switch kind {
        case .season:
            guard let total = dto.recursiveItemCount else { return nil }
            let unplayed = dto.userData?.unplayedItemCount ?? total
            return ChildProgress(played: max(0, total - unplayed), total: total)
        case .show:
            guard let unplayed = dto.userData?.unplayedItemCount else { return nil }
            if unplayed > 0 { return ChildProgress(played: 0, total: unplayed, unplayedOnly: true) }
            return dto.recursiveItemCount.flatMap { $0 > 0 ? ChildProgress(played: $0, total: $0) : nil }
        default:
            return nil
        }
    }

    /// Exact watched count for a show from its seasons, Season 0 (specials) left out as the server leaves it out.
    static func showProgress(seasons: [EmbyItem]) -> ChildProgress? {
        var total = 0
        var unplayed = 0
        for season in seasons where season.indexNumber != 0 {
            let count = season.recursiveItemCount ?? 0
            total += count
            unplayed += min(count, season.userData?.unplayedItemCount ?? count)
        }
        return total > 0 ? ChildProgress(played: total - unplayed, total: total) : nil
    }

    // MARK: - Detail

    static func detail(
        _ dto: EmbyItem, nextEpisode: EmbyItem?, trailers: [EmbyItem] = [], specialFeatures: [EmbyItem] = [],
        showProgress: ChildProgress? = nil, providerID: String, baseURL: URL
    ) -> MediaItemDetail {
        let item = item(dto, providerID: providerID, baseURL: baseURL, childProgress: showProgress)
        let tmdbID = dto.providerID("Tmdb").flatMap { Int($0) }
        let backdrop = item.artwork.backdrop

        func people(_ kinds: Set<String>) -> [MediaPerson] {
            (dto.people ?? []).filter { kinds.contains($0.type ?? "") }.compactMap { p in
                guard let id = p.id else { return nil }
                return MediaPerson(
                    id: id.value,
                    name: p.name ?? "",
                    role: p.role,
                    imageURL: imageURL(baseURL, itemID: id, type: "Primary", tag: p.primaryImageTag),
                    titleTmdbId: tmdbID,
                    titleIsMovie: dto.type == "Movie",
                    backdropURL: backdrop,
                    providerID: providerID
                )
            }
        }

        // Intro and credits markers share this array; only real chapters are chapters.
        let rawChapters = (dto.chapters ?? []).filter { $0.markerType == "Chapter" }
        let chapters = rawChapters.enumerated().map { i, c in
            MediaChapter(
                id: "\(i)",
                title: c.name,
                start: EmbyTicks.seconds(c.startPositionTicks) ?? 0,
                end: i + 1 < rawChapters.count ? EmbyTicks.seconds(rawChapters[i + 1].startPositionTicks) : nil,
                thumbnailURL: c.imageTag.flatMap {
                    imageURL(baseURL, itemID: dto.id, type: "Chapter/\(c.chapterIndex ?? i)", tag: $0)
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
            mediaSources: (dto.mediaSources ?? []).compactMap {
                mediaSource($0, itemID: dto.id.value, playSessionID: nil, baseURL: baseURL, token: nil)
            },
            // The first internet trailer on YouTube; local trailer files ride `extras`.
            trailerURL: YouTubeTrailer.firstLink((dto.remoteTrailers ?? []).map(\.url)),
            contentRating: dto.officialRating,
            regionOfOrigin: dto.productionLocations?.first,
            ratings: MediaRating.ordered([
                MediaRating(dto.criticRating.map { $0 / 10 }, source: .rottenTomatoes),
                MediaRating(dto.communityRating, source: .unknown),
            ]),
            nextEpisode: nextEpisode.map { self.item($0, providerID: providerID, baseURL: baseURL) },
            collections: (dto.collections ?? []).compactMap(\.name),
            extras: trailers.map { extra($0, providerID: providerID, baseURL: baseURL, isTrailer: true) }
                + specialFeatures.map { extra($0, providerID: providerID, baseURL: baseURL, isTrailer: false) },
            externalIDs: externalIDs(dto)
        )
    }

    /// A local trailer or special feature. It is a library item, so its id plays it.
    static func extra(_ dto: EmbyItem, providerID: String, baseURL: URL, isTrailer: Bool) -> MediaItemDetail.Extra {
        let type = dto.extraType.map { $0.prefix(1).lowercased() + $0.dropFirst() }
        return MediaItemDetail.Extra(
            id: dto.id.value,
            title: dto.name,
            thumbnailURL: imageURL(baseURL, itemID: dto.id, type: "Primary", tag: dto.imageTags?["Primary"]),
            duration: EmbyTicks.seconds(dto.runTimeTicks),
            playbackKey: dto.id.value,
            providerID: providerID,
            subtype: isTrailer ? .trailer : ExtraSubtype.from(subtype: type, extraType: nil)
        )
    }

    /// ProviderIds keyed lowercase, whatever case the server wrote.
    static func externalIDs(_ dto: EmbyItem) -> [String: String] {
        var out: [String: String] = [:]
        for key in ["tmdb", "imdb", "tvdb"] {
            if let value = dto.providerID(key) { out[key] = value }
        }
        return out
    }
}
