// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Catalog cards, details, season/episode lists and watch detail share these
/// field names. Endpoint-specific units stay explicit on SiloVersion below.
nonisolated struct SiloItem: Decodable, Sendable {
    let contentId: String
    var type: String?
    let title: String
    let sortTitle: String?
    let overview: String?
    let pendingTranslationLanguage: String?
    let machineTranslatedFields: [String]?
    let year: Int?
    let runtime: Int?
    let durationSeconds: Double?
    let releaseDate: String?
    let airDate: String?
    let firstAirDate: String?
    let contentRating: String?
    let genres: [String]?
    let studios: [String]?
    let countries: [String]?
    let tagline: String?
    var seriesId: String?
    var seriesTitle: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let episodeCount: Int?
    let seasonCount: Int?
    let playContentId: String?
    let playSeasonNumber: Int?
    let posterUrl: String?
    let backdropUrl: String?
    let logoUrl: String?
    let thumbUrl: String?
    let stillUrl: String?
    let positionSeconds: Double?
    let progressUpdatedAt: String?
    let addedAt: String?
    let userData: SiloWatchState?
    let userState: SiloItemUserState?
    var versions: [SiloVersion]?
    let cast: [SiloCredit]?
    let crew: [SiloCredit]?
    let ratings: [SiloRating]?
    let ratingRtCritic: Int?
    let ratingRtAudience: Int?
    let imdbId: String?
    let tmdbId: String?
    let tvdbId: String?
    let videos: [SiloItemVideo]?
    let extras: [SiloExtra]?
    let intro: SiloMarker?
    let credits: SiloMarker?
    let recap: SiloMarker?
    let preview: SiloMarker?
    let effectiveSubtitleMode: String?
    let effectiveSubtitleLanguage: String?
    let effectiveShowForcedSubtitles: Bool?
    let effectiveSubtitleTrackSignature: SiloSubtitleSignature?

    /// Silo caps formatted title ratings at three, but exposes both RT columns.
    /// Their presence alone is not permission to show a curator's hidden scores.
    var hasSupplementalRTRatings: Bool {
        (ratingRtCritic != nil && !(ratings ?? []).contains { $0.source == "rt_critic" })
            || (ratingRtAudience != nil && !(ratings ?? []).contains { $0.source == "rt_audience" })
    }
}

nonisolated struct SiloWatchState: Decodable, Sendable {
    let played: Bool?
    let watchedCount: Int?
    let unplayedCount: Int?
    let positionSeconds: Double?
    let durationSeconds: Double?
    let lastFileId: String?
}

nonisolated struct SiloItemUserState: Decodable, Sendable {
    let played: Bool
    let isFavorite: Bool
    let inWatchlist: Bool
}

nonisolated struct SiloVersion: Decodable, Sendable {
    let fileId: String
    let resolution: String
    let codecVideo: String
    let codecAudio: String
    let hdr: Bool
    let container: String
    let fileSize: Int64
    /// Both native catalog and watch serializers return catalog bitrate in
    /// kbps. The pinned WatchFileVersion schema incorrectly labels it bps.
    let bitrate: Int
    let duration: Double?
    let durationSeconds: Double?
    let fileName: String?
    let filePath: String?
    let editionKey: String?
    let editionRaw: String?
    let presentationPartIndex: Int?
    let presentationPartTotal: Int?
    let effectiveAudioTrackIndex: Int?
    let audioTracks: [SiloAudioTrack]?
    let videoTracks: [SiloVideoTrack]?
    let subtitleTracks: [SiloSubtitleTrack]?
    let chapters: [SiloChapter]?
    let intro: SiloMarker?
    let credits: SiloMarker?
    let recap: SiloMarker?
    let preview: SiloMarker?
    let markerSegments: [SiloMarkerOccurrence]?

    var seconds: Double { durationSeconds ?? duration ?? 0 }
    var bitsPerSecond: Int? {
        guard bitrate >= 0 else { return nil }
        let value = bitrate.multipliedReportingOverflow(by: 1000)
        return value.overflow ? nil : value.partialValue
    }
}

nonisolated struct SiloAudioTrack: Codable, Sendable {
    let codec: String?
    let profile: String?
    let channels: Int?
    let layout: String?
    let language: String?
    let title: String?
    let embeddedTitle: String?
    let bitrate: Int?
    let sampleRate: Int?
    let bitDepth: Int?
    let `default`: Bool
}

nonisolated struct SiloVideoTrack: Decodable, Sendable {
    let codec: String?
    let profile: String?
    let level: Int?
    let width: Int?
    let height: Int?
    let frameRate: String?
    let bitrate: Int?
    let videoRange: String?
    let videoRangeType: String?
    let colorTransfer: String?
    let dvProfile: Int?
    let dvLevel: Int?
    let dvBlCompatId: Int?
    let dvBlCompatIdPresent: Bool?
    let dvConfigPresent: Bool?
    let dvEnhancementLayer: String?
    let dolbyVision: String?
    let hdr10Plus: Bool?
    let interlaced: Bool
    let bitDepth: Int?
    let pixelFormat: String?
    let aspectRatio: String?
    let colorPrimaries: String?
    let colorSpace: String?
    let colorRange: String?
}

nonisolated struct SiloSubtitleTrack: Decodable, Sendable {
    let index: Int?
    let codec: String?
    let language: String?
    let title: String?
    let embeddedTitle: String?
    let external: Bool
    let fileName: String?
    let forced: Bool
    let `default`: Bool
    let hearingImpaired: Bool
}

nonisolated struct SiloChapter: Decodable, Sendable {
    let index: Int
    let title: String
    let startSeconds: Double
    let endSeconds: Double
    let thumbnailUrl: String?
}

nonisolated struct SiloCredit: Decodable, Sendable {
    let personId: String?
    let tmdbId: String?
    let imdbId: String?
    let name: String
    let character: String?
    let job: String?
    let order: Int?
    let photoUrl: String?
}

nonisolated struct SiloRating: Decodable, Sendable {
    let source: String
    let name: String
    let score: Double
    let display: String
}

nonisolated struct SiloRatingsCapability: Decodable, Sendable {
    struct Source: Decodable, Sendable {
        let source: String
        let name: String
    }
    let sources: [Source]
}

nonisolated struct SiloItemVideo: Decodable, Sendable {
    let kind: String
    let site: String
    let siteKey: String
    let name: String?

    /// Silo supplies site references, not playable URLs. These are app handoffs.
    var watchURL: URL? {
        let key = siteKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        switch site.lowercased() {
        case "youtube":
            var components = URLComponents(string: "https://www.youtube.com/watch")
            components?.queryItems = [URLQueryItem(name: "v", value: key)]
            return components?.url
        case "vimeo":
            guard key.allSatisfy(\.isNumber) else { return nil }
            return URL(string: "https://vimeo.com/\(key)")
        default:
            return nil
        }
    }

    var thumbnailURL: URL? {
        guard site.lowercased() == "youtube", watchURL != nil else { return nil }
        let key = SiloClient.pathComponent(siteKey.trimmingCharacters(in: .whitespacesAndNewlines))
        return URL(string: "https://i.ytimg.com/vi/\(key)/hqdefault.jpg")
    }
}

nonisolated struct SiloExtra: Decodable, Sendable {
    let contentId: String
    let kind: String
    let title: String?
    let durationSeconds: Double?
    let stillUrl: String?
}

nonisolated struct SiloMarker: Decodable, Sendable {
    let start: Double
    let end: Double

    private enum CodingKeys: String, CodingKey { case start, end, startSeconds, endSeconds }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        start = try values.decodeIfPresent(Double.self, forKey: .start) ?? values.decode(Double.self, forKey: .startSeconds)
        end = try values.decodeIfPresent(Double.self, forKey: .end) ?? values.decode(Double.self, forKey: .endSeconds)
    }
}

nonisolated struct SiloMarkerOccurrence: Decodable, Sendable {
    let kind: String
    let startSeconds: Double
    let endSeconds: Double
}

nonisolated struct SiloSubtitleSignature: Codable, Sendable {
    let language: String?
    let codec: String?
    let forced: Bool?
    let hearingImpaired: Bool?
    let source: String?
    let label: String?
}
