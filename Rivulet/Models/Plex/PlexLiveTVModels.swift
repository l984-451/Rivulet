//
//  PlexLiveTVModels.swift
//  Rivulet
//
//  Plex Live TV API response models
//

import Foundation
import Sentry

// MARK: - Live TV Capabilities

nonisolated struct PlexLiveTVCapabilities: Codable, Sendable {
    let allowTuners: Bool
    let liveTVEnabled: Bool
    let hasDVR: Bool

    init(allowTuners: Bool = false, liveTVEnabled: Bool = false, hasDVR: Bool = false) {
        self.allowTuners = allowTuners
        self.liveTVEnabled = liveTVEnabled
        self.hasDVR = hasDVR
    }
}

// MARK: - Live TV Session/Provider

nonisolated struct PlexLiveTVSessionContainer: Codable, Sendable {
    let MediaContainer: PlexLiveTVSessionMediaContainer
}

nonisolated struct PlexLiveTVSessionMediaContainer: Codable, Sendable {
    let size: Int?
    let MediaSubscription: [PlexMediaSubscription]?
}

nonisolated struct PlexMediaSubscription: Codable, Sendable {
    let id: Int?
    let type: String?
    let flavor: String?
    let status: String?
    let mediaGrabOperationId: Int?
}

// MARK: - Live TV Channels

nonisolated struct PlexLiveTVChannelContainer: Codable, Sendable {
    let MediaContainer: PlexLiveTVChannelMediaContainer
}

nonisolated struct PlexLiveTVChannelMediaContainer: Codable, Sendable {
    let size: Int?
    let Metadata: [PlexLiveTVChannel]?
}

nonisolated struct PlexLiveTVChannel: Codable, Identifiable, Sendable {
    let ratingKey: String
    let key: String
    let guid: String?
    let type: String?
    let title: String
    let summary: String?
    let thumb: String?
    let art: String?
    let year: Int?
    let channelCallSign: String?
    let channelIdentifier: String?
    let channelShortTitle: String?
    let channelThumb: String?
    let channelTitle: String?
    let channelNumber: String?
    let streamURL: String?  // HDHomeRun stream URL

    var id: String { ratingKey }

    /// Parse channel number as Int
    var parsedChannelNumber: Int? {
        guard let numStr = channelNumber else { return nil }
        // Handle formats like "5.1" or "5-1"
        let cleaned = numStr.components(separatedBy: CharacterSet(charactersIn: ".-")).first ?? numStr
        return Int(cleaned)
    }

    /// Whether this appears to be an HD channel
    var isHD: Bool {
        let title = (channelTitle ?? title).lowercased()
        return title.contains(" hd") || title.hasSuffix("hd") ||
               title.contains("1080") || title.contains("720")
    }
}

// MARK: - Live TV Guide (EPG)

nonisolated struct PlexLiveTVGuideContainer: Codable, Sendable {
    let MediaContainer: PlexLiveTVGuideMediaContainer
}

nonisolated struct PlexLiveTVGuideMediaContainer: Codable, Sendable {
    let size: Int?
    let Metadata: [PlexLiveTVGuideChannel]?
}

nonisolated struct PlexLiveTVGuideChannel: Codable, Sendable {
    let ratingKey: String?
    let key: String?
    let guid: String?
    let channelIdentifier: String?
    let channelTitle: String?
    let channelNumber: String?
    let channelThumb: String?
    let Metadata: [PlexLiveTVProgram]?
}

nonisolated struct PlexLiveTVProgram: Codable, Identifiable, Sendable {
    let ratingKey: String?
    let key: String?
    let guid: String?
    let type: String?
    let title: String
    let grandparentTitle: String?
    let parentTitle: String?
    let summary: String?
    let thumb: String?
    let art: String?
    let grandparentThumb: String?
    let grandparentArt: String?
    let year: Int?
    let originallyAvailableAt: String?
    let beginsAt: Int?           // Unix timestamp
    let endsAt: Int?             // Unix timestamp
    let onAir: Bool?
    let live: Bool?
    let premiere: Bool?
    let Genre: [PlexGenreTag]?
    let Media: [PlexMedia]?

    var id: String { ratingKey ?? "\(beginsAt ?? 0):\(title)" }

    /// Convert beginsAt to Date
    var startDate: Date? {
        guard let timestamp = beginsAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    /// Convert endsAt to Date
    var endDate: Date? {
        guard let timestamp = endsAt else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(timestamp))
    }

    /// Combined episode info
    var episodeInfo: String? {
        if let show = grandparentTitle {
            if let season = parentTitle {
                return "\(show) - \(season) - \(title)"
            }
            return "\(show) - \(title)"
        }
        return nil
    }

    /// Category from first genre
    var category: String? {
        Genre?.first?.tag
    }
}

nonisolated struct PlexGenreTag: Codable, Sendable {
    let tag: String
}

// MARK: - DVR Info

nonisolated struct PlexDVRContainer: Codable, Sendable {
    let MediaContainer: PlexDVRMediaContainer
}

nonisolated struct PlexDVRMediaContainer: Codable, Sendable {
    let size: Int?
    let Dvr: [PlexDVR]?
}

nonisolated struct PlexDVR: Codable, Sendable {
    let key: String?
    let uuid: String?
    let friendlyName: String?
    let device: String?
    let model: String?
    let make: String?
    let status: String?
    let lineup: String?
    let epgIdentifier: String?
    let Device: [PlexDVRDevice]?
}

struct PlexDVRDevice: Sendable {
    let key: String?
    let uuid: String?
    let uri: String?
    let parentID: String?  // Can be Int or String from Plex API
}

extension PlexDVRDevice: Decodable {
    private enum CodingKeys: String, CodingKey {
        case key, uuid, uri, parentID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        key = try container.decodeIfPresent(String.self, forKey: .key)
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        uri = try container.decodeIfPresent(String.self, forKey: .uri)

        // parentID can be Int or String from Plex API
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: .parentID) {
            parentID = String(intValue)
        } else {
            parentID = try container.decodeIfPresent(String.self, forKey: .parentID)
        }
    }
}

extension PlexDVRDevice: Encodable {}

// MARK: - Converters

extension PlexLiveTVChannel {
    /// Build a Plex HLS transcode URL for Live TV channels without an HDHomeRun stream URL.
    /// This is how official Plex clients stream from DVB tuners (e.g. TBS cards) — through
    /// the Plex server's universal transcode endpoint.
    ///
    /// The URL includes comprehensive client profile information that Plex requires to
    /// properly start a transcode session. Without these parameters, DVB tuners will fail
    /// to start playback (Fixes GitHub #64, RIVULET-15).
    private func buildPlexLiveTVStreamURL(serverURL: String, authToken: String) -> URL? {
        // Generate a unique session ID for this transcode session
        let sessionId = UUID().uuidString.uppercased()

        // Log transcode URL building start (GitHub #64 - DVB diagnostics)
        let startBreadcrumb = Breadcrumb(level: .info, category: "plex_livetv")
        startBreadcrumb.message = "Building Plex transcode URL for DVB channel"
        startBreadcrumb.data = [
            "channel_name": title,
            "channel_number": channelNumber ?? "unknown",
            "channel_key": key,
            "session_id": String(sessionId.prefix(8)),
            "server_host": URL(string: serverURL)?.host ?? "unknown"
        ]
        SentryBridge.addBreadcrumb(startBreadcrumb)

        var components = URLComponents(string: "\(serverURL)/video/:/transcode/universal/start.m3u8")

        // Build the client profile extras - these define codec support and limitations
        // This matches what official Plex clients send for Apple TV
        let profileExtras = buildClientProfileExtras()

        components?.queryItems = [
            // Core transcode parameters
            URLQueryItem(name: "X-Plex-Client-Profile-Name", value: "Generic"),
            URLQueryItem(name: "path", value: key),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "offset", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),

            // Container format
            URLQueryItem(name: "container", value: "mpegts"),
            URLQueryItem(name: "segmentFormat", value: "mpegts"),
            URLQueryItem(name: "segmentContainer", value: "mpegts"),

            // Playback mode - DIRECT STREAM: the server remuxes the tuner feed
            // (no re-encode; the codec lists below declare the raw broadcast
            // codecs as acceptable) and AetherEngine demuxes it client-side.
            // directPlay stays off — the universal endpoint refuses to build a
            // session when it decides direct play.
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "directStreamAudio", value: "1"),

            // Video settings - include mpeg2video so DVB broadcasts direct-play
            // instead of forcing a video transcode (Aether software-decodes it)
            URLQueryItem(name: "videoCodec", value: "h264,hevc,mpeg2video"),
            URLQueryItem(name: "videoResolution", value: "1920x1080"),
            URLQueryItem(name: "maxVideoBitrate", value: "20000"),
            URLQueryItem(name: "videoQuality", value: "100"),

            // HLS segment settings
            URLQueryItem(name: "segmentDuration", value: "6"),

            // Audio settings - include mp2/mp3 (common on DVB) for direct play
            URLQueryItem(name: "audioCodec", value: "aac,ac3,eac3,mp2,mp3"),
            URLQueryItem(name: "audioBitrate", value: "384"),
            URLQueryItem(name: "audioChannels", value: "6"),

            // Subtitles
            URLQueryItem(name: "subtitles", value: "auto"),
            URLQueryItem(name: "subtitleSize", value: "100"),

            // Context and location
            URLQueryItem(name: "context", value: "streaming"),
            URLQueryItem(name: "location", value: "lan"),

            // Session management
            URLQueryItem(name: "session", value: sessionId),
            URLQueryItem(name: "autoAdjustQuality", value: "0"),
            URLQueryItem(name: "hasMDE", value: "1"),

            // Fast seeking support
            URLQueryItem(name: "fastSeek", value: "1"),

            // Client profile extras - critical for Plex to understand client capabilities
            URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: profileExtras),

            // Authentication
            URLQueryItem(name: "X-Plex-Token", value: authToken),
        ]

        let resultURL = components?.url

        // Log transcode URL building result (GitHub #64 - DVB diagnostics)
        if let url = resultURL {
            let successBreadcrumb = Breadcrumb(level: .info, category: "plex_livetv")
            successBreadcrumb.message = "Plex transcode URL built successfully"
            successBreadcrumb.data = [
                "channel_name": title,
                "channel_number": channelNumber ?? "unknown",
                "session_id": String(sessionId.prefix(8)),
                "url_path": url.path,
                "url_host": url.host ?? "unknown",
                "has_query_params": url.query != nil
            ]
            SentryBridge.addBreadcrumb(successBreadcrumb)
        } else {
            let failBreadcrumb = Breadcrumb(level: .error, category: "plex_livetv")
            failBreadcrumb.message = "Failed to build Plex transcode URL - URLComponents failed"
            failBreadcrumb.data = [
                "channel_name": title,
                "channel_key": key,
                "server_url": serverURL
            ]
            SentryBridge.addBreadcrumb(failBreadcrumb)
        }

        return resultURL
    }

    /// Build the X-Plex-Client-Profile-Extra parameter value.
    /// This tells Plex what codecs and formats the client supports.
    private func buildClientProfileExtras() -> String {
        // Each profile directive is separated by "+"
        // These are URL-encoded when added to the query string
        let profiles = [
            // Direct play profiles - what we can play without transcoding.
            // AetherEngine demuxes MPEG-TS and software-decodes MPEG-2, so
            // declare the raw DVB codecs too and let Plex skip the transcoder.
            "add-direct-play-profile(type=videoProfile&protocol=http&container=mpegts&videoCodec=h264,hevc,mpeg2video&audioCodec=aac,ac3,eac3,mp2,mp3)",
            "add-direct-play-profile(type=videoProfile&protocol=hls&container=mpegts&videoCodec=h264,hevc,mpeg2video&audioCodec=aac,ac3,eac3,mp2,mp3)",

            // Transcode target - how to transcode if needed
            "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264,hevc&audioCodec=aac,ac3,eac3&replace=true)",

            // Subtitle transcode target
            "add-transcode-target(type=subtitleProfile&context=streaming&protocol=hls&container=webvtt&subtitleCodec=webvtt)",

            // Limitations - match Apple TV 4K capabilities
            "add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.width&value=1920&replace=true)",
            "add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.height&value=1080&replace=true)",
            "add-limitation(scope=videoAudioCodec&scopeName=*&type=upperBound&name=audio.channels&value=6&replace=true)",
        ]

        return profiles.joined(separator: "+")
    }

    /// Convert to UnifiedChannel
    func toUnifiedChannel(sourceId: String, serverURL: String, authToken: String) -> UnifiedChannel {
        let channelId = UnifiedChannel.makeId(
            sourceType: .plex,
            sourceId: sourceId,
            channelId: ratingKey
        )

        // Use the HDHomeRun stream URL if available, otherwise fall back to
        // Plex server transcode URL (needed for DVB tuners without HDHomeRun)
        let streamURLValue: URL? = {
            if let hdhrURL = streamURL {
                // HDHomeRun direct stream URL available
                let breadcrumb = Breadcrumb(level: .info, category: "plex_livetv")
                breadcrumb.message = "Using HDHomeRun direct stream URL"
                breadcrumb.data = [
                    "channel_name": title,
                    "channel_number": channelNumber ?? "unknown",
                    "rating_key": ratingKey,
                    "channel_key": key,
                    "stream_type": "hdhr_direct",
                    "has_stream_url": true,
                    "server_host": URL(string: serverURL)?.host ?? "unknown"
                ]
                SentryBridge.addBreadcrumb(breadcrumb)
                return URL(string: hdhrURL)
            }

            // No HDHomeRun URL - build Plex transcode URL (DVB tuner path)
            let transcodeURL = buildPlexLiveTVStreamURL(serverURL: serverURL, authToken: authToken)

            // Log detailed info for DVB tuner debugging (GitHub #64)
            let breadcrumb = Breadcrumb(level: .info, category: "plex_livetv")
            breadcrumb.message = transcodeURL != nil
                ? "Built Plex transcode URL for DVB tuner"
                : "Failed to build Plex transcode URL"
            breadcrumb.data = [
                "channel_name": title,
                "channel_number": channelNumber ?? "unknown",
                "rating_key": ratingKey,
                "stream_type": "plex_transcode",
                "channel_key": key,
                "server_host": URL(string: serverURL)?.host ?? "unknown",
                "transcode_url_built": transcodeURL != nil,
                "transcode_url_host": transcodeURL?.host ?? "none"
            ]
            SentryBridge.addBreadcrumb(breadcrumb)

            // If transcode URL failed, capture as an error
            if transcodeURL == nil {
                let event = Event(level: .error)
                event.message = SentryMessage(formatted: "Failed to build Plex Live TV transcode URL")
                event.extra = [
                    "channel_name": title,
                    "channel_number": channelNumber ?? "unknown",
                    "rating_key": ratingKey,
                    "channel_key": key,
                    "server_url": serverURL
                ]
                event.tags = [
                    "component": "plex_livetv",
                    "operation": "build_transcode_url"
                ]
                event.fingerprint = ["plex_livetv", "transcode_url_build_failed"]
                SentryBridge.capture(event: event)
            }

            return transcodeURL
        }()

        // Build logo URL - handle both external URLs and Plex paths
        let logoURL: URL? = {
            guard let thumb = channelThumb ?? thumb else { return nil }
            // Check if it's already an absolute URL (external)
            if thumb.hasPrefix("http://") || thumb.hasPrefix("https://") {
                return URL(string: thumb)
            }
            // Otherwise it's a Plex server path
            return URL(string: "\(serverURL)\(thumb)?X-Plex-Token=\(authToken)")
        }()

        return UnifiedChannel(
            id: channelId,
            sourceType: .plex,
            sourceId: sourceId,
            channelNumber: parsedChannelNumber,
            name: channelTitle ?? title,
            callSign: channelCallSign ?? channelShortTitle,
            logoURL: logoURL,
            streamURL: streamURLValue,
            tvgId: channelIdentifier ?? ratingKey,
            groupTitle: nil,
            isHD: isHD
        )
    }
}

extension PlexLiveTVProgram {
    /// Convert to UnifiedProgram. Plex EPG supplies two images we map to the
    /// guide's artwork slots: `thumb` (2:3 poster) and `art` (16:9 background).
    /// Both are resolved to full URLs (absolute passthrough, or Plex server path
    /// + token) so they work the same as the XMLTV `posterURL` / `landscapeURL`.
    func toUnifiedProgram(unifiedChannelId: String, serverURL: String, authToken: String) -> UnifiedProgram? {
        guard let start = startDate, let end = endDate else {
            return nil
        }

        let programId = "\(unifiedChannelId):\(beginsAt ?? 0)"

        // Prefer the programme's own artwork, falling back to the show's
        // (grandparent) poster/art, which Plex often populates when the
        // per-episode image is missing.
        let poster = Self.plexImageURL(thumb ?? grandparentThumb, serverURL: serverURL, authToken: authToken)
        let background = Self.plexImageURL(art ?? grandparentArt, serverURL: serverURL, authToken: authToken)

        return UnifiedProgram(
            id: programId,
            channelId: unifiedChannelId,
            title: grandparentTitle ?? title,
            subtitle: grandparentTitle != nil ? title : parentTitle,
            description: summary,
            startTime: start,
            endTime: end,
            category: category,
            iconURL: poster,          // keep icon = poster for existing callers
            posterURL: poster,        // 2:3 poster (Plex `thumb`)
            landscapeURL: background, // 16:9 background (Plex `art`)
            episodeNumber: nil,
            isNew: premiere ?? false
        )
    }

    /// Resolve a Plex image path to a full URL: external http(s) URLs pass
    /// through; Plex server paths get the server prefix + auth token.
    private static func plexImageURL(_ path: String?, serverURL: String, authToken: String) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(authToken)")
    }
}
