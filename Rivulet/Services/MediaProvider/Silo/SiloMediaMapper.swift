// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated enum SiloMediaMapper {
    static func url(_ value: String?, baseURL: URL) -> URL? {
        guard let value else { return nil }
        return SiloClient.mediaURL(value, relativeTo: baseURL)
    }

    static func kind(_ dto: SiloItem) -> MediaKind {
        switch dto.type {
        case "movie": .movie
        case "series": .show
        case "season": .season
        case "episode": .episode
        default: dto.episodeNumber != nil ? .episode : dto.seasonNumber != nil ? .season : .unknown
        }
    }

    static func item(_ dto: SiloItem, providerID: String, baseURL: URL, libraryID: String? = nil, parentID: String? = nil) -> MediaItem {
        let kind = kind(dto)
        let show = dto.seriesId.map { MediaItemRef(providerID: providerID, itemID: $0) }
        // The server's content identity is opaque: never manufacture a season
        // content_id from the series and its numeric season number.
        let progress: ChildProgress? = {
            guard kind == .show || kind == .season, let state = dto.userData,
                  let watched = state.watchedCount, let unplayed = state.unplayedCount else { return nil }
            return ChildProgress(played: watched, total: watched + unplayed)
        }()
        let artwork = MediaArtwork(poster: url(dto.posterUrl ?? (kind == .episode ? dto.stillUrl : nil), baseURL: baseURL),
                                   backdrop: url(dto.backdropUrl, baseURL: baseURL),
                                   thumbnail: url(dto.stillUrl ?? dto.thumbUrl ?? dto.posterUrl, baseURL: baseURL),
                                   logo: url(dto.logoUrl, baseURL: baseURL))
        // Episode/season ids identify those catalog entries, never a movie or
        // their owning series. Continue Watching resolves that series separately.
        let scope: String? = kind == .movie ? "m" : kind == .show ? "s" : nil
        let identities = scope.map { scope in
            [("tmdb", dto.tmdbId), ("imdb", dto.imdbId), ("tvdb", dto.tvdbId)]
                .compactMap { key, value in value.map { "\(scope):\(key):\($0)" } }
        } ?? []
        return MediaItem(
            ref: MediaItemRef(providerID: providerID, itemID: dto.contentId), kind: kind,
            title: dto.title, sortTitle: dto.sortTitle, overview: dto.overview,
            overviewIsMachineTranslated: dto.machineTranslatedFields?.contains("overview") == true, year: dto.year,
            releaseDate: dto.releaseDate ?? dto.airDate ?? dto.firstAirDate, contentRating: dto.contentRating,
            runtime: dto.durationSeconds ?? dto.runtime.map { Double($0) * 60 },
            parentRef: kind == .season ? show : parentID.map { MediaItemRef(providerID: providerID, itemID: $0) },
            grandparentRef: kind == .episode ? show : nil,
            seriesTitle: dto.seriesTitle, episodeNumber: dto.episodeNumber, seasonNumber: dto.seasonNumber,
            childProgress: progress,
            userState: MediaUserState(isPlayed: dto.userState?.played ?? dto.userData?.played ?? false,
                                      viewOffset: dto.positionSeconds ?? dto.userData?.positionSeconds ?? 0,
                                      isFavorite: dto.userState?.isFavorite ?? false,
                                      lastViewedAt: date(dto.progressUpdatedAt)),
            artwork: artwork, parentArtwork: nil, grandparentArtwork: nil,
            versionCount: dto.versions?.count, identity: identities.isEmpty ? nil : identities,
            libraryID: libraryID
        )
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        return (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
    }

    static func frameRate(_ value: String?) -> Double? {
        guard let value else { return nil }
        let parts = value.split(separator: "/")
        if parts.count == 2, let numerator = Double(parts[0]), let denominator = Double(parts[1]), denominator != 0 {
            return numerator / denominator
        }
        return Double(value)
    }

    static func video(_ track: SiloVideoTrack, index: Int, sourceID: String, fallbackCodec: String? = nil,
                      fallbackHDR: Bool = false) -> VideoTrack {
        let rangeType = track.videoRangeType?.lowercased() ?? ""
        let hdr10Plus = track.hdr10Plus == true || rangeType.contains("hdr10plus")
            || rangeType.contains("hdr10+") || rangeType == "hdr10_plus"
        let range: VideoTrack.VideoRange
        if let profile = track.dvProfile, profile > 0 { range = .dolbyVision(profile: profile) }
        else if nonempty(track.dolbyVision) != nil || rangeType.hasPrefix("dovi")
                    || ["dolbyvision", "dolby_vision"].contains(rangeType)
                    || track.videoRange?.lowercased() == "dolbyvision" {
            range = .dolbyVision(profile: 0)
        } else if hdr10Plus { range = .hdr10Plus }
        else if track.colorTransfer == "arib-std-b67" || rangeType == "hlg" { range = .hlg }
        else if track.colorTransfer == "smpte2084" || rangeType == "hdr10" { range = .hdr10 }
        else if track.videoRange?.lowercased() == "sdr" || rangeType == "sdr" { range = .sdr }
        else if track.videoRange?.lowercased() == "hdr" || fallbackHDR { range = .hdr }
        else { range = .unknown }
        return VideoTrack(id: "file:\(sourceID):video:\(index)", codec: nonempty(track.codec) ?? nonempty(fallbackCodec) ?? "unknown",
                          profile: nonempty(track.profile), level: track.level, width: track.width, height: track.height,
                          frameRate: frameRate(track.frameRate), bitrate: bitsPerSecond(track.bitrate),
                          videoRange: range, isDefault: index == 0,
                          scanType: track.interlaced ? "interlaced" : "progressive", hasHDR10Plus: hdr10Plus,
                          bitDepth: track.bitDepth, pixelFormat: nonempty(track.pixelFormat), aspectRatio: nonempty(track.aspectRatio),
                          colorPrimaries: nonempty(track.colorPrimaries), colorTransfer: nonempty(track.colorTransfer),
                          colorSpace: nonempty(track.colorSpace), colorRange: nonempty(track.colorRange),
                          dolbyVisionLevel: track.dvLevel,
                          dolbyVisionCompatibilityID: track.dvBlCompatIdPresent == true ? track.dvBlCompatId : nil,
                          dolbyVisionEnhancementLayer: nonempty(track.dvEnhancementLayer),
                          compatibleRangeLabel: compatibleRange(track))
    }

    static func compatibleRange(_ track: SiloVideoTrack) -> String? {
        let type = track.videoRangeType?.lowercased() ?? ""
        if type.hasPrefix("doviwithhdr10") { return "HDR10" }
        if type == "doviwithhlg" { return "HLG" }
        if type == "doviwithsdr" { return "SDR" }
        guard track.dvConfigPresent == true, track.dvBlCompatIdPresent == true else { return nil }
        switch track.dvBlCompatId {
        case 1: return "HDR10"
        case 2: return "SDR"
        case 4: return "HLG"
        default: return nil
        }
    }

    static func nonempty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    /// Native scanner stores both file and track bitrates in kbps.
    static func bitsPerSecond(_ kbps: Int?) -> Int? {
        guard let kbps, kbps > 0 else { return nil }
        let result = kbps.multipliedReportingOverflow(by: 1000)
        return result.overflow ? nil : result.partialValue
    }

    static func source(_ dto: SiloVersion, baseURL: URL, streamURL: URL? = nil,
                       streamKind: MediaSource.StreamKind = .directPlay,
                       selectedAudio: Int? = nil) -> MediaSource {
        var audio = (dto.audioTracks ?? []).enumerated().map { index, track in
            let codec = nonempty(track.codec) ?? (index == 0 ? nonempty(dto.codecAudio) : nil) ?? "unknown"
            let atmos = [track.profile, track.title, track.embeddedTitle, track.layout].contains {
                $0?.localizedCaseInsensitiveContains("atmos") == true
            } || (codec.lowercased() == "eac3" && (track.profile ?? "").lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains("joc"))
            return AudioTrack(id: "file:\(dto.fileId):audio:\(index)", index: index,
                       codec: codec == "dts" ? "dca" : codec, profile: nonempty(track.profile),
                       channels: track.channels, channelLayout: nonempty(track.layout), language: track.language,
                       title: track.title ?? track.embeddedTitle, extendedTitle: track.title,
                       bitrate: bitsPerSecond(track.bitrate), samplingRate: track.sampleRate,
                       isDefault: track.default, isForced: false,
                       isSelected: index == (selectedAudio ?? dto.effectiveAudioTrackIndex),
                       bitDepth: track.bitDepth, hasAtmos: atmos)
        }
        if audio.isEmpty, let codec = nonempty(dto.codecAudio) {
            audio = [AudioTrack(id: "file:\(dto.fileId):audio:0", index: 0,
                                codec: codec == "dts" ? "dca" : codec, profile: nil,
                                channels: nil, channelLayout: nil, language: nil, title: nil, extendedTitle: nil,
                                bitrate: nil, samplingRate: nil, isDefault: true, isForced: false, isSelected: true)]
        }
        var videos = (dto.videoTracks ?? []).enumerated().map {
            video($0.element, index: $0.offset, sourceID: dto.fileId,
                  fallbackCodec: $0.offset == 0 ? dto.codecVideo : nil, fallbackHDR: $0.offset == 0 && dto.hdr)
        }
        if videos.isEmpty, nonempty(dto.codecVideo) != nil || nonempty(dto.resolution) != nil || dto.hdr {
            videos = [VideoTrack(id: "file:\(dto.fileId):video:0", codec: nonempty(dto.codecVideo) ?? "unknown",
                                 profile: nil, level: nil, width: nil, height: nil, frameRate: nil, bitrate: nil,
                                 videoRange: dto.hdr ? .hdr : .unknown, isDefault: true, scanType: nil)]
        }
        let subtitles = (dto.subtitleTracks ?? []).enumerated().map { offset, track in
            // Version metadata is not the plan's dense combined ordinal space.
            // These IDs are display-only until resolveStream replaces the list
            // with the server's authoritative subtitle inventory.
            return SubtitleTrack(id: "metadata:\(dto.fileId):subtitle:\(offset)", index: track.index ?? offset,
                                 codec: track.codec ?? "unknown", language: track.language,
                                 title: track.title ?? track.embeddedTitle, extendedTitle: track.title,
                                 isDefault: track.default, isForced: track.forced, isHearingImpaired: track.hearingImpaired,
                                 isEmbedded: !track.external, externalURL: nil, isSelected: false)
        }
        return MediaSource(id: dto.fileId, container: dto.container, duration: dto.seconds,
                           bitrate: dto.bitsPerSecond, fileSize: dto.fileSize, fileName: dto.filePath ?? dto.fileName,
                           versionName: dto.editionRaw, videoResolution: dto.resolution,
                           videoTracks: videos,
                           audioTracks: audio, subtitleTracks: subtitles, streamKind: streamKind, streamURL: streamURL,
                           chapters: chapters(dto, baseURL: baseURL))
    }

    static func chapters(_ version: SiloVersion, baseURL: URL) -> [MediaChapter] {
        (version.chapters ?? []).map {
            MediaChapter(id: "\($0.index)", title: $0.title, start: $0.startSeconds, end: $0.endSeconds,
                         thumbnailURL: url($0.thumbnailUrl, baseURL: baseURL))
        }
    }

    static func unavailableDetail(_ item: MediaItem) -> MediaItemDetail {
        MediaItemDetail(item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
                        chapters: [], mediaSources: [], trailerURL: nil, contentRating: item.contentRating,
                        nextEpisode: nil, collections: [])
    }

    /// Silo uses snake_case and includes teasers/clips, unlike Plex's vocabulary.
    static func extraSubtype(_ kind: String) -> ExtraSubtype {
        switch kind {
        case "trailer", "teaser": .trailer
        case "featurette": .featurette
        case "behind_the_scenes": .behindTheScenes
        case "deleted_scene": .deletedScene
        case "clip": .scene
        default: .unknown
        }
    }

    static func extras(_ dto: SiloItem, providerID: String, baseURL: URL) -> [MediaItemDetail.Extra] {
        let local = (dto.extras ?? []).map { extra in
            let subtype = extraSubtype(extra.kind)
            return MediaItemDetail.Extra(
                id: extra.contentId, title: extra.title.flatMap { $0.isEmpty ? nil : $0 } ?? subtype.displayName,
                thumbnailURL: url(extra.stillUrl, baseURL: baseURL), duration: extra.durationSeconds,
                playbackKey: extra.contentId, providerID: providerID, subtype: subtype)
        }
        // Preserve the server's video order and keep remote IDs distinct from local content IDs.
        // Unknown hosting sites are not media streams and have no supported Apple TV handoff.
        var seen = Set<String>()
        let remote = (dto.videos ?? []).compactMap { video -> MediaItemDetail.Extra? in
            guard let watchURL = video.watchURL else { return nil }
            let id = "siloVideo:\(video.site.lowercased()):\(video.siteKey)"
            guard seen.insert(id).inserted else { return nil }
            let subtype = extraSubtype(video.kind)
            return MediaItemDetail.Extra(
                id: id, title: video.name.flatMap { $0.isEmpty ? nil : $0 } ?? subtype.displayName,
                thumbnailURL: video.thumbnailURL, duration: nil, playbackKey: nil, providerID: providerID,
                subtype: subtype, externalURL: watchURL)
        }
        return local + remote
    }

    static func detail(_ dto: SiloItem, providerID: String, baseURL: URL, authorityRevision: UInt64 = 0, parentID: String? = nil,
                       nextEpisode: SiloItem? = nil, ratingSources: [SiloRatingsCapability.Source] = []) -> MediaItemDetail {
        let item = item(dto, providerID: providerID, baseURL: baseURL, parentID: parentID)
        func person(_ credit: SiloCredit) -> MediaPerson {
            MediaPerson(id: credit.personId.map { SiloPersonContext.identity($0, providerID: providerID, authorityRevision: authorityRevision) } ?? "",
                        name: credit.name, role: credit.character ?? credit.job,
                        imageURL: url(credit.photoUrl, baseURL: baseURL),
                        backdropURL: item.artwork.backdrop)
        }
        let versions = dto.versions ?? []
        let chapters = versions.first.map { self.chapters($0, baseURL: baseURL) } ?? []
        var providedRatings = dto.ratings ?? []
        for definition in ratingSources where !providedRatings.contains(where: { $0.source == definition.source }) {
            let score: Int?
            switch definition.source {
            case "rt_critic": score = dto.ratingRtCritic
            case "rt_audience": score = dto.ratingRtAudience
            default: continue
            }
            guard let score, (0...100).contains(score) else { continue }
            providedRatings.append(SiloRating(source: definition.source, name: definition.name,
                                             score: Double(score), display: "\(score)%"))
        }
        let ratings: [MediaRating] = providedRatings.compactMap { rating in
            let source: MediaRating.Source
            switch rating.source {
            case "imdb": source = .imdb
            case "tmdb": source = .tmdb
            case "rt_critic": source = .rottenTomatoes
            case "rt_audience": source = .rottenTomatoesAudience
            case "metacritic": source = .metacritic
            case "letterboxd": source = .letterboxd
            default: source = .unknown
            }
            return MediaRating(scoreOutOf100: rating.score, source: source, sourceID: rating.source,
                               name: rating.name, display: rating.display)
        }
        var external: [String: String] = [:]
        if let value = dto.tmdbId { external["tmdb"] = value }
        if let value = dto.imdbId { external["imdb"] = value }
        if let value = dto.tvdbId { external["tvdb"] = value }
        return MediaItemDetail(item: item, tagline: dto.tagline, genres: dto.genres ?? [], studios: dto.studios ?? [],
                               cast: (dto.cast ?? []).sorted { ($0.order ?? 0) < ($1.order ?? 0) }.map(person),
                               directors: (dto.crew ?? []).filter { $0.job?.lowercased() == "director" }.map(person),
                               writers: (dto.crew ?? []).filter { ["writer", "screenplay", "story", "creator"].contains($0.job?.lowercased() ?? "") }.map(person),
                               chapters: chapters, mediaSources: versions.map { source($0, baseURL: baseURL) },
                               trailerURL: nil,
                               contentRating: dto.contentRating, regionOfOrigin: dto.countries?.first, ratings: ratings,
                               ratingPresentation: .allAvailable, showsTechnicalMetadata: true,
                               pendingDescriptionTranslationLanguage: dto.pendingTranslationLanguage,
                               nextEpisode: nextEpisode.map { self.item($0, providerID: providerID, baseURL: baseURL) }, collections: [],
                               extras: extras(dto, providerID: providerID, baseURL: baseURL), externalIDs: external)
    }
}
