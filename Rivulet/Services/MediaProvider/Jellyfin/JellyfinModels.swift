// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinModels.swift
//  Rivulet
//
//  The subset of Jellyfin's DTOs Rivulet reads, field names from the 12.1
//  OpenAPI spec (Swift-cased by JellyfinJSON). Enum-typed fields decode as
//  String so a value a newer server adds can't fail the whole response.
//  Nothing above JellyfinProvider sees these types.
//

import Foundation

nonisolated struct JFPublicSystemInfo: Decodable, Sendable {
    let id: String?
    let serverName: String?
    let version: String?
    let productName: String?
}

nonisolated struct JFAuthenticationResult: Decodable, Sendable {
    let accessToken: String?
    let serverId: String?
    let user: JFUser?
}

nonisolated struct JFUser: Decodable, Sendable {
    let id: String?
    let name: String?
}

/// `/MediaSegments/{id}`: `type` is Intro, Outro, Recap, Commercial, Preview or Unknown.
nonisolated struct JFMediaSegment: Decodable, Sendable {
    let type: String?
    let startTicks: Int64?
    let endTicks: Int64?
}

nonisolated struct JFMediaSegments: Decodable, Sendable {
    let items: [JFMediaSegment]?
}

nonisolated struct JFQueryResult: Decodable, Sendable {
    let items: [JFItem]?
    let totalRecordCount: Int?
}

nonisolated struct JFItem: Decodable, Sendable {
    let id: String?
    let name: String?
    let sortName: String?
    let type: String?               // BaseItemKind: Movie, Series, Season, Episode, ...
    let collectionType: String?     // on library views: movies, tvshows, music, ...
    let overview: String?
    let productionYear: Int?
    let premiereDate: String?
    let officialRating: String?
    let communityRating: Double?
    let runTimeTicks: Int64?
    let dateCreated: String?
    let dateLastContentAdded: String?   // series/seasons: when the newest episode arrived

    let seriesId: String?
    let seriesName: String?
    let seasonId: String?
    let parentId: String?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let recursiveItemCount: Int?

    let userData: JFUserData?

    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let parentBackdropItemId: String?
    let parentBackdropImageTags: [String]?
    let parentLogoItemId: String?
    let parentLogoImageTag: String?
    let parentPrimaryImageItemId: String?
    let parentPrimaryImageTag: String?
    let seriesPrimaryImageTag: String?

    // Detail-only (GET /Items/{id} returns every field)
    let taglines: [String]?
    let genres: [String]?
    let studios: [JFNameId]?
    let people: [JFPerson]?
    let chapters: [JFChapter]?
    let productionLocations: [String]?
    let providerIds: [String: String]?
    let mediaSources: [JFMediaSource]?
}

nonisolated struct JFUserData: Decodable, Sendable {
    let playbackPositionTicks: Int64?
    let played: Bool?
    let isFavorite: Bool?
    let lastPlayedDate: String?
    let unplayedItemCount: Int?
}

nonisolated struct JFNameId: Decodable, Sendable {
    let name: String?
    let id: String?
}

nonisolated struct JFPerson: Decodable, Sendable {
    let id: String?
    let name: String?
    let role: String?
    let type: String?               // PersonKind: Actor, Director, Writer, GuestStar, ...
    let primaryImageTag: String?
}

nonisolated struct JFChapter: Decodable, Sendable {
    let startPositionTicks: Int64?
    let name: String?
    let imageTag: String?
}

nonisolated struct JFPlaybackInfoResponse: Decodable, Sendable {
    let mediaSources: [JFMediaSource]?
    let playSessionId: String?
    let errorCode: String?
}

nonisolated struct JFMediaSource: Decodable, Sendable {
    let id: String?
    let name: String?
    let container: String?
    let size: Int64?
    let bitrate: Int?
    let runTimeTicks: Int64?
    let supportsDirectPlay: Bool?
    /// Relative path (carries ApiKey and PlaySessionId) of the server's HLS
    /// transcode, present when the server can transcode this source.
    let transcodingUrl: String?
    let mediaStreams: [JFMediaStream]?
    let defaultAudioStreamIndex: Int?
    let defaultSubtitleStreamIndex: Int?
}

nonisolated struct JFMediaStream: Decodable, Sendable {
    let index: Int?
    let type: String?               // Video, Audio, Subtitle, EmbeddedImage, ...
    let codec: String?
    let profile: String?
    let level: Double?
    let language: String?
    let title: String?
    let displayTitle: String?
    let isDefault: Bool?
    let isForced: Bool?
    let isHearingImpaired: Bool?
    let isExternal: Bool?
    let isTextSubtitleStream: Bool?
    let isInterlaced: Bool?
    let width: Int?
    let height: Int?
    let bitRate: Int?
    let channels: Int?
    let channelLayout: String?
    let sampleRate: Int?
    let realFrameRate: Double?
    let averageFrameRate: Double?
    let videoRangeType: String?     // SDR, HDR10, HLG, HDR10Plus, DOVI, DOVIWithHDR10, ...
    let colorTransfer: String?      // smpte2084 (PQ), arib-std-b67 (HLG), bt709, ...
    let dvProfile: Int?
    let audioSpatialFormat: String? // None, DolbyAtmos, DTSX
}

// MARK: - Request bodies

nonisolated struct JFAuthenticateByName: Encodable, Sendable {
    let username: String
    let pw: String
}

/// POST /Items/{id}/PlaybackInfo. Rivulet direct-plays everything through
/// AetherEngine, so the profile accepts every container and codec: an empty
/// Container/VideoCodec/AudioCodec matches all (ContainerHelper.ContainsContainer).
nonisolated struct JFPlaybackInfoRequest: Encodable, Sendable {
    let userId: String
    let mediaSourceId: String?
    let maxStreamingBitrate: Int
    let startTimeTicks: Int64?
    let enableDirectPlay: Bool
    let enableDirectStream: Bool
    let enableTranscoding: Bool
    let deviceProfile: Profile

    nonisolated struct Profile: Encodable, Sendable {
        let maxStreamingBitrate: Int
        let directPlayProfiles: [DirectPlay]
        let transcodingProfiles: [Transcoding]
        let subtitleProfiles: [Subtitle]
    }
    nonisolated struct Transcoding: Encodable, Sendable {
        let container: String
        let type: String
        let videoCodec: String
        let audioCodec: String
        let `protocol`: String
        let context: String
        let maxAudioChannels: String
        let breakOnNonKeyFrames: Bool
    }
    nonisolated struct DirectPlay: Encodable, Sendable {
        let type: String
    }
    nonisolated struct Subtitle: Encodable, Sendable {
        let format: String
        let method: String
    }

    /// Without these, a selected subtitle (the server picks a default from the
    /// user's language settings) resolves to burn-in, which rules out direct
    /// play (StreamBuilder.GetSubtitleProfile). On a 12.1 server that blocked
    /// 3 of 9 movies. Embed covers subtitles inside the container, External the
    /// sidecar files, matched on Jellyfin's codec names (PGSSUB, DVDSUB, ...).
    /// A format Rivulet cannot draw is still declared: a subtitle that does not
    /// render beats a title that does not play.
    static let subtitleProfiles: [Subtitle] =
        ["subrip", "ass", "ssa", "webvtt", "mov_text", "pgssub", "dvdsub", "dvbsub"]
            .map { Subtitle(format: $0, method: "Embed") }
        + ["srt", "ass", "vtt", "pgssub", "dvdsub"]
            .map { Subtitle(format: $0, method: "External") }

    /// Direct play first; the server falls back to an HLS transcode (h264/hevc
    /// in ts with aac/ac3/eac3) when it cannot. `allowDirectPlay: false` forces
    /// the transcode, and `startTimeTicks` starts it at that offset.
    static func playback(
        userId: String, mediaSourceId: String?, allowDirectPlay: Bool = true, startTimeTicks: Int64? = nil
    ) -> Self {
        // 400 Mbps: above any UHD remux, so the server never declines direct
        // play on bitrate alone.
        let bitrate = 400_000_000
        return Self(
            userId: userId,
            mediaSourceId: mediaSourceId,
            maxStreamingBitrate: bitrate,
            startTimeTicks: startTimeTicks,
            enableDirectPlay: allowDirectPlay,
            enableDirectStream: allowDirectPlay,
            enableTranscoding: true,
            deviceProfile: Profile(
                maxStreamingBitrate: bitrate,
                directPlayProfiles: [DirectPlay(type: "Video"), DirectPlay(type: "Audio")],
                transcodingProfiles: [Transcoding(
                    container: "ts", type: "Video", videoCodec: "h264,hevc", audioCodec: "aac,ac3,eac3",
                    protocol: "hls", context: "Streaming", maxAudioChannels: "6", breakOnNonKeyFrames: true
                )],
                subtitleProfiles: subtitleProfiles
            )
        )
    }
}

/// Body for /Sessions/Playing, /Sessions/Playing/Progress and /Sessions/Playing/Stopped.
/// The server ignores fields a given endpoint doesn't define.
nonisolated struct JFPlaybackReport: Encodable, Sendable {
    let itemId: String
    let mediaSourceId: String?
    let playSessionId: String?
    let positionTicks: Int64
    let isPaused: Bool
    let canSeek: Bool
    let playMethod: String
}

nonisolated struct JFUserDataUpdate: Encodable, Sendable {
    let playbackPositionTicks: Int64
}
