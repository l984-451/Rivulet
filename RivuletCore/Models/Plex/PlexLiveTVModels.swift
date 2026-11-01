// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

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

    /// Name of the lineup whose DVR carried this channel, used to group the
    /// guide the way an M3U's `group-title` does. Assigned by the fetch, which
    /// is the only place that knows which DVR it just queried — and left nil
    /// when there is only one, since a lone tab would duplicate All Channels.
    var tunerName: String?

    var id: String { ratingKey }

    var parsedChannelNumber: ChannelNumber? { channelNumber.flatMap(ChannelNumber.init) }

    /// Channel name without the number PMS prepends to `channelTitle`
    /// ("666 HALLHDP"); the number is shown separately everywhere (#336).
    var displayName: String {
        let full = channelTitle ?? title
        guard let number = channelNumber, full.hasPrefix(number + " ") else { return full }
        let rest = full.dropFirst(number.count + 1).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? full : rest
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
    let parentThumb: String?
    let parentArt: String?
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
    /// Episode and season numbers, for the "S2 E5" line in programme info.
    let index: Int?
    let parentIndex: Int?
    let contentRating: String?

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

    /// Every genre tag, comma-joined like XMLTV's categories, less the bare
    /// provider codes some guides carry ("178"). The first tag alone was
    /// often only the code, which hid the real label behind it.
    var category: String? {
        let tags = (Genre ?? []).map(\.tag).filter { $0.contains(where: \.isLetter) }
        return tags.isEmpty ? nil : tags.joined(separator: ", ")
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

    /// Name for this tuner's guide group, from the lineup URL's fragment
    /// (`lineup://…#Freeview - Perth (58 channels)`), minus the stale channel count.
    /// `key` is left out: "161" is a worse heading than none.
    var guideGroupName: String? {
        func cleaned(_ value: String?) -> String? {
            guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return nil }
            return trimmed
        }

        let makeModel = [cleaned(make), cleaned(model)]
            .compactMap { $0 }
            .joined(separator: " ")

        // Annotated: a bare literal mixing String? with the non-optional
        // `makeModel` infers [Any] and the whole expression stops compiling.
        let candidates: [String?] = [Self.lineupName(from: lineup), friendlyName, device, makeModel]
        return candidates.lazy.compactMap(cleaned).first
    }

    /// Human-readable half of a lineup string, or nil if it carries none.
    static func lineupName(from lineup: String?) -> String? {
        guard let lineup, let hash = lineup.firstIndex(of: "#") else { return nil }
        let raw = String(lineup[lineup.index(after: hash)...])
        // The value arrives percent-encoded when it has been through a query.
        let decoded = raw.removingPercentEncoding ?? raw
        let trimmed = decoded.replacingOccurrences(
            of: #"\s*\(\d+\s+channels?\)\s*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        let name = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }
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
    /// Plex HLS transcode URL for Live TV channels with no HDHomeRun stream URL
    /// (DVB tuners). PMS needs the full client profile or playback fails (#64).
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

        // Untuned base: `path` points at the EPG channel metadata. Cloud-EPG /
        // DVB servers reject this (the tuned session path from resolveStreamURL
        // replaces it); some HDHomeRun setups accept it, so it stays the
        // last-resort fallback when the tune step fails.
        components?.queryItems = Self.universalLiveQueryItems(
            sessionPath: key,
            sessionIdentifier: UUID().uuidString,
            transcodeSessionId: sessionId,
            directPlay: false,
            authToken: authToken
        )
        // Consensus wire form: '+' profile-clause separators travel as %2B.
        let resultURL = components.flatMap { Self.finalizedLiveURL($0) }

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

    /// The universal-transcoder query set for live sessions, shared verbatim
    /// by /decision and /start.m3u8 (PMS links them by identical params).
    /// Mirrors the parameter set working third-party clients ship (Plezy /
    /// Vita_plex), verified against a live PMS. Three distinct identities:
    /// `session` (transcode session), `X-Plex-Session-Identifier` (from tune,
    /// links the transcode to the tuner grab's consumer), and the client
    /// identifier.
    static func universalLiveQueryItems(
        sessionPath: String,
        sessionIdentifier: String,
        transcodeSessionId: String,
        directPlay: Bool,
        authToken: String
    ) -> [URLQueryItem] {
        let productVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? "1.0"
        return [
            URLQueryItem(name: "hasMDE", value: "1"),
            URLQueryItem(name: "path", value: sessionPath),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "fastSeek", value: "1"),
            // directPlay=1 asks for the raw session playlist (all original
            // streams incl. DVB teletext / mp2); the decision response says
            // whether the server granted it. directStream=1 is the remux
            // fallback the server applies on its own.
            URLQueryItem(name: "directPlay", value: directPlay ? "1" : "0"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "directStreamAudio", value: "1"),
            URLQueryItem(name: "subtitleSize", value: "100"),
            URLQueryItem(name: "audioBoost", value: "100"),
            URLQueryItem(name: "location", value: "lan"),
            URLQueryItem(name: "addDebugOverlay", value: "0"),
            URLQueryItem(name: "autoAdjustQuality", value: "0"),
            URLQueryItem(name: "advancedSubtitles", value: "text"),
            URLQueryItem(name: "mediaBufferSize", value: "157286"),
            URLQueryItem(name: "session", value: transcodeSessionId),
            URLQueryItem(name: "subtitles", value: "auto"),
            URLQueryItem(name: "copyts", value: "0"),
            URLQueryItem(name: "Accept-Language", value: "en"),
            URLQueryItem(name: "X-Plex-Session-Identifier", value: sessionIdentifier),
            URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: Self.liveClientProfileExtras()),
            URLQueryItem(name: "X-Plex-Incomplete-Segments", value: "1"),
            URLQueryItem(name: "X-Plex-Product", value: PlexAPI.productName),
            URLQueryItem(name: "X-Plex-Version", value: productVersion),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
            URLQueryItem(name: "X-Plex-Platform", value: "Generic"),
            URLQueryItem(name: "X-Plex-Client-Profile-Name", value: "Generic"),
            URLQueryItem(name: "X-Plex-Token", value: authToken),
        ]
    }

    /// Finalises a live-session URL. `X-Plex-Client-Profile-Extra` joins clauses
    /// with `+`, which `URLComponents` leaves raw and PMS reads as a space, so it
    /// must travel as `%2B`. Reading `queryItems` decodes it back, so every build
    /// and rebuild goes through here. (`%2C` round-trips on its own.)
    static func finalizedLiveURL(_ components: URLComponents) -> URL? {
        var components = components
        if let escaped = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B") {
            components.percentEncodedQuery = escaped
        }
        return components.url
    }

    /// X-Plex-Client-Profile-Extra for live sessions, in the canonical
    /// header-form: clauses joined by raw '+', comma lists pre-encoded as %2C
    /// (the PMS OpenAPI spec's own example uses exactly this shape). The whole
    /// value is then percent-encoded ONCE when placed in the query string —
    /// URLComponents handles that, plus the '+'→%2B pass callers apply.
    static func liveClientProfileExtras() -> String {
        let clauses = [
            // Direct-play profiles for raw broadcast codecs (Aether demuxes MPEG-TS
            // and decodes MPEG-2 and mp2). DTS is in for cable and satellite feeds.
            // `dvb_teletext` keeps PMS from converting teletext to WebVTT, which
            // would force a conversion and lose the page the caption renderer reads.
            "add-direct-play-profile(type=videoProfile&protocol=hls&container=mpegts&videoCodec=h264%2Chevc%2Cmpeg2video&audioCodec=aac%2Cac3%2Ceac3%2Cmp2%2Cmp3%2Cdts&subtitleCodec=dvb_teletext%2Cdvb_subtitle%2Ceia_608)",
            "add-direct-play-profile(type=videoProfile&protocol=http&container=mpegts&videoCodec=h264%2Chevc%2Cmpeg2video&audioCodec=aac%2Cac3%2Ceac3%2Cmp2%2Cmp3%2Cdts&subtitleCodec=dvb_teletext%2Cdvb_subtitle%2Ceia_608)",

            // Direct-stream target: keep mp2/mp3 so a remux COPIES broadcast
            // audio instead of re-encoding it (the engine decodes mp2 fine).
            "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264%2Chevc%2Cmpeg2video&audioCodec=aac%2Cac3%2Ceac3%2Cmp2%2Cmp3%2Cdts&replace=true)",

            // Subtitle transcode target. Only reached when direct play was
            // refused for some other reason; the clause above is what keeps
            // teletext out of this path in the first place.
            "add-transcode-target(type=subtitleProfile&context=streaming&protocol=hls&container=webvtt&subtitleCodec=webvtt)",
        ]
        return clauses.joined(separator: "+")
    }

    /// Convert to UnifiedChannel
    func toUnifiedChannel(
        sourceId: String,
        serverURL: String,
        authToken: String,
        favouriteRank: Int? = nil
    ) -> UnifiedChannel {
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
            name: displayName,
            callSign: channelCallSign ?? channelShortTitle,
            logoURL: logoURL,
            streamURL: streamURLValue,
            tvgId: channelIdentifier ?? ratingKey,
            // Groups the guide by tuner, the same field an M3U fills from
            // `group-title`. nil reads as "ungrouped" rather than a new tab.
            groupTitle: tunerName,
            isHD: isHD,
            isFavourite: favouriteRank != nil,
            favouriteRank: favouriteRank
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

        // Plex episode metadata uses `thumb` for the 16:9 episode still and
        // parent/grandparent thumbs for portrait season/show posters. Movies
        // use their own thumb as the poster. Keep those roles separate so a
        // landscape episode still is never promoted into the 2:3 poster slot.
        let isEpisode = type?.lowercased() == "episode" || grandparentTitle != nil
        let posterPath = isEpisode
            ? (grandparentThumb ?? parentThumb)
            : (thumb ?? grandparentThumb ?? parentThumb)
        let backgroundPath = isEpisode
            ? (thumb ?? art ?? grandparentArt ?? parentArt)
            : (art ?? grandparentArt ?? parentArt)

        let poster = Self.plexImageURL(posterPath, serverURL: serverURL, authToken: authToken)
        let background = Self.plexImageURL(backgroundPath, serverURL: serverURL, authToken: authToken)

        var episodeLine: String?
        if isEpisode, let episode = index {
            episodeLine = parentIndex.map { "S\($0) E\(episode)" } ?? "E\(episode)"
        }

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
            episodeNumber: episodeLine,
            isNew: premiere ?? false,
            // What the DVR schedules against: the subscription template is
            // keyed by the airing's own guid (plex://episode/…, plex://movie/…).
            sourceGuid: guid,
            year: isEpisode ? nil : year,
            contentRating: contentRating,
            isMovie: type?.lowercased() == "movie",
            isLive: live ?? false
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
