// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyModels.swift
//  Rivulet
//
//  The subset of Emby's DTOs Rivulet reads, shapes taken from captured 4.8.11,
//  4.9.5 and 4.10.2 responses. Nearly every field is optional and unknown keys
//  are ignored, so a version that adds or drops one cannot fail a response.
//  Nothing above EmbyProvider sees these types.
//

import Foundation

/// An id Emby writes as a JSON string (item ids, user ids) or as an integer
/// (`Studios`, `GenreItems`, `TagItems`, `Collections`). Stored as a String.
nonisolated struct EmbyID: Decodable, Sendable, Hashable, CustomStringConvertible {
    let value: String
    var description: String { value }

    init(_ value: String) { self.value = value }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let string = try? container.decode(String.self) {
            value = string
        } else if let integer = try? container.decode(Int64.self) {
            value = String(integer)
        } else {
            throw DecodingError.typeMismatch(
                String.self, .init(codingPath: decoder.codingPath, debugDescription: "id is neither string nor integer")
            )
        }
    }
}

/// `NameLongIdPair` and the string-id entities: `{Name, Id}` with either id type.
nonisolated struct EmbyNameID: Decodable, Sendable {
    let name: String?
    let id: EmbyID?
}

nonisolated struct EmbyPublicSystemInfo: Decodable, Sendable {
    let id: String?
    let serverName: String?
    let version: String?
    let productName: String?
}

nonisolated struct EmbyAuthenticationResult: Decodable, Sendable {
    let accessToken: String?
    let serverId: String?
    let user: EmbyUser?
}

nonisolated struct EmbyUser: Decodable, Sendable {
    let id: EmbyID?
    let name: String?
    let policy: Policy?

    nonisolated struct Policy: Decodable, Sendable {
        let isAdministrator: Bool?
        let enableContentDeletion: Bool?
        let enableContentDeletionFromFolders: [EmbyID]?
        let enableContentDownloading: Bool?
        let enableLiveTvAccess: Bool?
        let enableSubtitleDownloading: Bool?
    }
}

/// `Libraries/AvailableOptions`: the subtitle providers (Open Subtitles) the server has.
nonisolated struct EmbyLibraryAvailableOptions: Decodable, Sendable {
    let subtitleFetchers: [Fetcher]?
    nonisolated struct Fetcher: Decodable, Sendable { let name: String? }
}

/// `Items/{id}/RemoteSearch/Subtitles/{language}`.
nonisolated struct EmbyRemoteSubtitle: Decodable, Sendable {
    let id: String?
    let name: String?
    let providerName: String?
    let format: String?
    let threeLetterISOLanguageName: String?
    let isForced: Bool?
    let isHearingImpaired: Bool?
}

// MARK: - Items

nonisolated struct EmbyQueryResult: Decodable, Sendable {
    let items: [EmbyItem]?
    let totalRecordCount: Int?
}

/// `Genres` and `Years` rows: a genre has an `Id`; a year is `{"Name":"1991"}` alone.
nonisolated struct EmbyNamedResult: Decodable, Sendable {
    struct Row: Decodable, Sendable {
        let id: EmbyID?
        let name: String?
    }
    let items: [Row]?
}

/// `Items/Prefixes` rows: `{"Name":"#"}` with no counts.
nonisolated struct EmbyPrefix: Decodable, Sendable {
    let name: String?
}

/// BaseItemDto. Only `Id`, `Name` and `Type` are always present; everything else is
/// absent (never null) when the server has nothing, or when a list call did not ask
/// for it (`Fields`). Ids decode from string or integer.
nonisolated struct EmbyItem: Decodable, Sendable {
    let id: EmbyID
    let name: String
    let type: String
    let sortName: String?
    let collectionType: String?
    let mediaType: String?
    let isFolder: Bool?
    let locationType: String?
    let canDelete: Bool?
    let overview: String?
    let taglines: [String]?
    let productionYear: Int?
    let premiereDate: String?
    let dateCreated: String?
    let officialRating: String?
    let communityRating: Double?
    let criticRating: Double?
    let runTimeTicks: Int64?
    let genres: [String]?
    let studios: [EmbyNameID]?
    let people: [EmbyPerson]?
    let chapters: [EmbyChapter]?
    let productionLocations: [String]?
    let providerIds: [String: String]?
    let collections: [EmbyNameID]?
    let extraType: String?
    let container: String?
    let localTrailerCount: Int?
    let specialFeatureCount: Int?
    /// Internet trailers (YouTube links from TMDB), asked for by `detailFields`.
    let remoteTrailers: [EmbyRemoteTrailer]?

    let seriesId: EmbyID?
    let seriesName: String?
    let seasonId: EmbyID?
    let parentId: EmbyID?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let recursiveItemCount: Int?
    let childCount: Int?

    // Music
    let album: String?
    let albumId: EmbyID?
    let albumPrimaryImageTag: String?
    let albumArtist: String?
    let albumArtists: [EmbyNameID]?
    let artistItems: [EmbyNameID]?

    let userData: EmbyUserData?
    let playlistItemId: EmbyID?

    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let parentBackdropItemId: EmbyID?
    let parentBackdropImageTags: [String]?
    let parentLogoItemId: EmbyID?
    let parentLogoImageTag: String?
    let seriesPrimaryImageTag: String?
    /// Albums and photo albums have no image of their own: these point at a child's.
    let primaryImageItemId: EmbyID?
    let primaryImageTag: String?

    let mediaSources: [EmbyMediaSource]?

    /// Photos: only when asked for in `Fields`.
    let width: Int?
    let height: Int?
    let path: String?

    /// Provider ids come with mixed key case on one server (`Imdb` on a movie, `IMDB` on a series).
    func providerID(_ name: String) -> String? {
        providerIds?.first { $0.key.caseInsensitiveCompare(name) == .orderedSame && !$0.value.isEmpty }?.value
    }
}

nonisolated struct EmbyUserData: Decodable, Sendable {
    let playbackPositionTicks: Int64?
    let played: Bool?
    let isFavorite: Bool?
    let playCount: Int?
    let lastPlayedDate: String?
    let playedPercentage: Double?
    let unplayedItemCount: Int?
}

nonisolated struct EmbyPerson: Decodable, Sendable {
    let id: EmbyID?
    let name: String?
    let role: String?
    let type: String?
    let primaryImageTag: String?
}

/// `MarkerType` is on every chapter; a missing one reads as a plain chapter.
nonisolated struct EmbyChapter: Decodable, Sendable {
    let startPositionTicks: Int64?
    let name: String?
    let markerType: String
    let chapterIndex: Int?
    let imageTag: String?

    init(from decoder: any Decoder) throws {
        enum Key: String, CodingKey { case startPositionTicks, name, markerType, chapterIndex, imageTag }
        let c = try decoder.container(keyedBy: Key.self)
        startPositionTicks = try c.decodeIfPresent(Int64.self, forKey: .startPositionTicks)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        markerType = try c.decodeIfPresent(String.self, forKey: .markerType) ?? "Chapter"
        chapterIndex = try c.decodeIfPresent(Int.self, forKey: .chapterIndex)
        imageTag = try c.decodeIfPresent(String.self, forKey: .imageTag)
    }
}

// MARK: - Playback

nonisolated struct EmbyPlaybackInfoResponse: Decodable, Sendable {
    let mediaSources: [EmbyMediaSource]?
    let playSessionId: String?
    let errorCode: String?
}

/// `Id` is opaque: `mediasource_<itemId>` on 4.9 and 4.10, 32 hex on 4.8. Never derive it.
nonisolated struct EmbyMediaSource: Decodable, Sendable {
    let id: String?
    /// The library item this source belongs to; `Videos/{ItemId}/...` takes it.
    let itemId: EmbyID?
    let name: String?
    let path: String?
    let container: String?
    let size: Int64?
    let bitrate: Int?
    let runTimeTicks: Int64?
    let supportsDirectPlay: Bool?
    let supportsDirectStream: Bool?
    let supportsTranscoding: Bool?
    /// Server-relative, no `/emby`, carries the live `api_key`: never log it.
    let directStreamUrl: String?
    let transcodingUrl: String?
    let transcodingSubProtocol: String?
    let transcodingContainer: String?
    let mediaStreams: [EmbyMediaStream]?
    let defaultAudioStreamIndex: Int?
    let defaultSubtitleStreamIndex: Int?
    let requiresOpening: Bool?
    let liveStreamId: String?
}

nonisolated struct EmbyMediaStream: Decodable, Sendable {
    let index: Int?
    let type: String?               // Video, Audio, Subtitle, EmbeddedImage
    let codec: String?
    let profile: String?
    let level: Double?
    let language: String?
    let title: String?
    let displayTitle: String?
    let displayLanguage: String?
    let isDefault: Bool?
    let isForced: Bool?
    let isHearingImpaired: Bool?
    let isExternal: Bool?
    let isTextSubtitleStream: Bool?
    let supportsExternalStream: Bool?
    let isInterlaced: Bool?
    let width: Int?
    let height: Int?
    let bitRate: Int?
    let bitDepth: Int?
    let channels: Int?
    let channelLayout: String?
    let sampleRate: Int?
    let realFrameRate: Double?
    let averageFrameRate: Double?
    let aspectRatio: String?
    let pixelFormat: String?
    let videoRange: String?
    let colorTransfer: String?
    let colorPrimaries: String?
    let extendedVideoType: String?
    let extendedVideoSubType: String?
    let deliveryMethod: String?
    let deliveryUrl: String?
    let path: String?
}

/// `GET Items/{id}/DeleteInfo`: what a delete removes. A movie's is its whole folder.
nonisolated struct EmbyDeleteInfo: Decodable, Sendable {
    let paths: [String]?
}

// MARK: - Request bodies

/// `POST Users/{id}/Items/{id}/UserData`. Emby writes both fields on every POST and treats an
/// omitted one as false or 0, so a position-only body would wipe `Played`.
nonisolated struct EmbyUserDataUpdate: Encodable, Sendable {
    let playbackPositionTicks: Int64
    let played: Bool
}

/// `POST Items/{id}/PlaybackInfo`. The profile accepts every container and codec for direct
/// play (a missing `Container` is a wildcard on Emby, and explicit lists are honored literally,
/// so a list would send a TrueHD remux to a transcode); `MaxStreamingBitrate` must ride in the
/// body or the server declares a 57 Mbps remux over the limit.
nonisolated struct EmbyPlaybackInfoRequest: Encodable, Sendable {
    let userId: String
    let mediaSourceId: String?
    let maxStreamingBitrate: Int
    let startTimeTicks: Int64?
    let audioStreamIndex: Int?
    let subtitleStreamIndex: Int?
    let enableDirectPlay: Bool
    let enableDirectStream: Bool
    let enableTranscoding: Bool
    /// False forces a re-encode instead of copying the source video into the TS segments.
    let allowVideoStreamCopy: Bool?
    let deviceProfile: Profile

    nonisolated struct Profile: Encodable, Sendable {
        let maxStreamingBitrate: Int
        let directPlayProfiles: [DirectPlay]
        let transcodingProfiles: [Transcoding]
        let subtitleProfiles: [Subtitle]
    }
    nonisolated struct DirectPlay: Encodable, Sendable {
        let type: String
        var container: String?
        var videoCodec: String?
        var audioCodec: String?
    }
    nonisolated struct Transcoding: Encodable, Sendable {
        let container: String
        let type: String
        var videoCodec: String?
        let audioCodec: String
        let `protocol`: String
        let context: String
        let maxAudioChannels: String
        let breakOnNonKeyFrames: Bool
    }
    nonisolated struct Subtitle: Encodable, Sendable {
        let format: String
        let method: String
    }

    /// Without these a selected subtitle forces a transcode with burn-in (`SubtitleCodecNotSupported`).
    /// Embed covers streams inside the container, External the sidecars; names match case-insensitively.
    /// A format Rivulet cannot draw is still declared: a subtitle that does not render beats a title
    /// that does not play.
    static let subtitleProfiles: [Subtitle] =
        ["subrip", "ass", "ssa", "webvtt", "mov_text", "pgssub", "dvdsub", "dvbsub"]
            .map { Subtitle(format: $0, method: "Embed") }
        + ["srt", "ass", "vtt", "pgssub", "dvdsub"]
            .map { Subtitle(format: $0, method: "External") }

    /// The one transcode Rivulet asks for: H.264 in TS over HLS. fMP4 re-encodes restart their
    /// timestamps at 0 on every fragment, and HEVC in TS was never seen on AVPlayer.
    static let transcodingProfile = Transcoding(
        container: "ts", type: "Video", videoCodec: "h264", audioCodec: "aac,ac3,eac3",
        protocol: "hls", context: "Streaming", maxAudioChannels: "6", breakOnNonKeyFrames: true
    )

    /// Uncapped is 400 Mbps, above any UHD remux. A forced transcode declares no subtitle profiles,
    /// so the server burns the chosen subtitle in: the hls route draws no captions of its own.
    static func playback(
        userId: String, mediaSourceId: String?, allowDirectPlay: Bool, startTimeTicks: Int64? = nil,
        maxStreamingBitrate: Int? = nil, audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil,
        allowVideoStreamCopy: Bool? = nil
    ) -> Self {
        let bitrate = maxStreamingBitrate ?? 400_000_000
        return Self(
            userId: userId, mediaSourceId: mediaSourceId, maxStreamingBitrate: bitrate,
            startTimeTicks: startTimeTicks, audioStreamIndex: audioStreamIndex,
            subtitleStreamIndex: subtitleStreamIndex,
            enableDirectPlay: allowDirectPlay, enableDirectStream: allowDirectPlay, enableTranscoding: true,
            allowVideoStreamCopy: allowVideoStreamCopy,
            deviceProfile: Profile(
                maxStreamingBitrate: bitrate,
                directPlayProfiles: [DirectPlay(type: "Video"), DirectPlay(type: "Audio")],
                transcodingProfiles: [transcodingProfile],
                subtitleProfiles: allowDirectPlay ? subtitleProfiles : []
            )
        )
    }
}

extension EmbyPlaybackInfoRequest {
    /// A backdrop clip: direct play on AVPlayer or nothing. No transcode, subtitles or resume.
    static func themeVideo(userId: String) -> Self {
        let bitrate = 20_000_000
        return Self(
            userId: userId, mediaSourceId: nil, maxStreamingBitrate: bitrate, startTimeTicks: 0,
            audioStreamIndex: nil, subtitleStreamIndex: -1,
            enableDirectPlay: true, enableDirectStream: true, enableTranscoding: false, allowVideoStreamCopy: nil,
            deviceProfile: Profile(
                maxStreamingBitrate: bitrate,
                directPlayProfiles: [DirectPlay(type: "Video", container: "mp4,m4v,mov",
                                               videoCodec: "h264,hevc", audioCodec: "aac,ac3,eac3,alac,mp3")],
                transcodingProfiles: [],
                subtitleProfiles: []
            )
        )
    }

    /// Music through AVPlayer. Without a profile the reply has no URL at all. These containers play
    /// direct; anything else (ogg, opus, wma) comes back as an AAC HLS transcode, the only transcode
    /// form that seeks (the HTTP one is a raw ADTS stream).
    static func audio(userId: String) -> Self {
        let bitrate = 400_000_000
        return Self(
            userId: userId, mediaSourceId: nil, maxStreamingBitrate: bitrate, startTimeTicks: nil,
            audioStreamIndex: nil, subtitleStreamIndex: nil,
            enableDirectPlay: true, enableDirectStream: true, enableTranscoding: true, allowVideoStreamCopy: nil,
            deviceProfile: Profile(
                maxStreamingBitrate: bitrate,
                directPlayProfiles: [DirectPlay(type: "Audio", container: "mp3,aac,m4a,flac,wav,alac")],
                transcodingProfiles: [Transcoding(
                    container: "aac", type: "Audio", videoCodec: nil, audioCodec: "aac", protocol: "hls",
                    context: "Streaming", maxAudioChannels: "2", breakOnNonKeyFrames: false
                )],
                subtitleProfiles: []
            )
        )
    }
}

/// Body for `Sessions/Playing`, `/Progress` and `/Stopped`. `PlaySessionId` is required on the
/// first (400 without), and `Stopped` must carry the position: a body without one marks the
/// item played.
nonisolated struct EmbyPlaybackReport: Encodable, Sendable {
    let itemId: String
    let mediaSourceId: String?
    let playSessionId: String
    let positionTicks: Int64
    let isPaused: Bool
    let canSeek: Bool
    let playMethod: String
}

/// `POST Items/{id}` rename. `ProviderIds` must be present, even empty.
nonisolated struct EmbyRenameItem: Encodable, Sendable {
    let name: String
    var providerIds: [String: String] = [:]
}

/// `POST Playlists` reply: the new playlist's id (and `ItemAddedCount`, unread).
nonisolated struct EmbyCreatedPlaylist: Decodable, Sendable {
    let id: EmbyID
}

/// Sign-in body. `Pw` is always sent, empty for a passwordless user; `Password` never is.
nonisolated struct EmbyAuthenticateByName: Encodable, Sendable {
    let username: String
    let pw: String
}

/// Emby's JSON is PascalCase. Map it to Swift casing at the edge so the DTOs
/// read like the rest of the codebase. Dictionary keys (ImageTags,
/// ProviderIds) are left untouched by a custom key strategy.
nonisolated enum EmbyJSON {
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .custom { path in
            let key = path.last!.stringValue
            return Key(stringValue: key.prefix(1).lowercased() + key.dropFirst())
        }
        return decoder
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .custom { path in
            let key = path.last!.stringValue
            return Key(stringValue: key.prefix(1).uppercased() + key.dropFirst())
        }
        return encoder
    }

    /// Emby writes `2026-11-04T14:03:49.1537435Z`: always Z, seven fraction digits.
    /// Year 1 (`0001-01-01...`, the "unset" date on some views) is nil.
    static func date(_ string: String?) -> Date? {
        guard let string, !string.hasPrefix("0001-") else { return nil }
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) { return date }
        return try? Date.ISO8601FormatStyle().parse(string)
    }
}

/// Emby times are 100ns ticks (RunTimeTicks, PositionTicks, chapter starts).
nonisolated enum EmbyTicks {
    static let perSecond: Double = 10_000_000
    static func seconds(_ ticks: Int64?) -> TimeInterval? { ticks.map { Double($0) / perSecond } }

    /// 0 for a non-finite or out-of-range value, which `Int64(_:)` would trap on.
    static func ticks(_ seconds: TimeInterval) -> Int64 {
        let value = (seconds * perSecond).rounded()
        return value.isFinite && abs(value) < Double(Int64.max) ? Int64(value) : 0
    }
}

/// One entry of `RemoteTrailers`: a link, usually YouTube, and its name.
nonisolated struct EmbyRemoteTrailer: Decodable, Sendable {
    let url: String?
    let name: String?
}
