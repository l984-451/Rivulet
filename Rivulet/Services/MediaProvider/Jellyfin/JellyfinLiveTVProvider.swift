// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  JellyfinLiveTVProvider.swift
//  Rivulet
//
//  The signed-in Jellyfin server's Live TV as a Live TV source. It comes and
//  goes with the sign-in (`sync`), never through an add-source step, and is
//  never saved. Measured on 12.1 with an M3U tuner and XMLTV guide. Records
//  through timers and series timers when the user may manage Live TV.
//

import Foundation

actor JellyfinLiveTVProvider: LiveTVProvider {
    let sourceType: LiveTVSourceType = .jellyfin
    let sourceId: String
    let displayName: String
    nonisolated let supportsRecording: Bool

    private let client: JellyfinClient
    private let userID: String
    private var cachedChannels: [UnifiedChannel] = []

    init(provider: JellyfinProvider, canRecord: Bool) {
        sourceId = provider.id
        displayName = "\(provider.displayName) Live TV"
        supportsRecording = canRecord
        client = provider.client
        userID = provider.userID
    }

    var isConnected: Bool { true }

    // MARK: - Automatic source

    /// Set when the user hid the server's Live TV (#406).
    static let hiddenKey = "liveTVHideJellyfin"
    /// The server's Live TV while hidden, so Settings can list it as Off.
    @MainActor static var hiddenSource: LiveTVDataStore.LiveTVSourceInfo?

    /// Shows or hides the signed-in server's Live TV; the task ends once the source is found again.
    @MainActor
    static func setHidden(_ hide: Bool) -> Task<Void, Never>? {
        UserDefaults.standard.set(hide, forKey: hiddenKey)
        let id = JellyfinSession.account?.providerID
        return sync(MediaProviderRegistry.shared.secondaryProviders.first { $0.id == id } as? JellyfinProvider)
    }

    /// Adds the server's Live TV when it has channels for this user, removes
    /// it when signed out or when it has none. A failed check changes nothing.
    @MainActor @discardableResult
    static func sync(_ provider: JellyfinProvider?) -> Task<Void, Never>? {
        let store = LiveTVDataStore.shared
        guard let provider else {
            hiddenSource = nil
            store.setServerSource(nil, of: .jellyfin)
            return nil
        }
        return Task { @MainActor in
            let probe: JFLiveQuery<JFLiveChannel>
            do {
                probe = try await provider.client.get("LiveTv/Channels", [URLQueryItem(name: "limit", value: "0")])
            } catch {
                return
            }
            guard (probe.totalRecordCount ?? 0) > 0 else {
                hiddenSource = nil
                store.setServerSource(nil, of: .jellyfin)
                return
            }
            guard !UserDefaults.standard.bool(forKey: hiddenKey) else {
                hiddenSource = LiveTVDataStore.LiveTVSourceInfo(
                    id: provider.id, sourceType: .jellyfin, displayName: "\(provider.displayName) Live TV",
                    channelCount: 0, isConnected: false, lastSync: nil)
                store.setServerSource(nil, of: .jellyfin)
                return
            }
            hiddenSource = nil
            if !store.hasSource(id: provider.id) {
                // Admins pass without the Live TV management right; the server
                // answers 403 to timer requests from anyone else.
                let me: JFUserWithPolicy? = try? await provider.client.get("Users/Me")
                let canRecord = me?.policy?.isAdministrator == true || me?.policy?.enableLiveTvManagement == true
                store.setServerSource(JellyfinLiveTVProvider(provider: provider, canRecord: canRecord), of: .jellyfin)
            }
        }
    }

    // MARK: - Channels

    // ponytail: the lineup is cached for the provider's life (a sign-in);
    // Refresh Channels or a relaunch picks up server changes. Add a TTL like Plex's if needed.
    func fetchChannels() async throws -> [UnifiedChannel] {
        cachedChannels.isEmpty ? try await refreshChannels() : cachedChannels
    }

    func refreshChannels() async throws -> [UnifiedChannel] {
        let result: JFLiveQuery<JFLiveChannel> = try await client.get("LiveTv/Channels", [
            URLQueryItem(name: "addCurrentProgram", value: "false"),
            URLQueryItem(name: "enableImageTypes", value: "Primary"),
            URLQueryItem(name: "enableUserData", value: "true")
        ])
        let channels = (result.items ?? []).compactMap {
            $0.unifiedChannel(sourceId: sourceId, baseURL: client.baseURL)
        }
        cachedChannels = channels
        return channels
    }

    // MARK: - Guide

    /// One request for the whole window. Unpaged: 24 hours of 107 channels
    /// measured 2.4 MB in 1.2 s.
    func fetchEPG(for channels: [UnifiedChannel], startDate: Date,
                  endDate: Date) async throws -> [String: [UnifiedProgram]] {
        let iso = Date.ISO8601FormatStyle()
        let result: JFLiveQuery<JFLiveProgram> = try await client.get("LiveTv/Programs", [
            URLQueryItem(name: "minEndDate", value: iso.format(startDate)),
            URLQueryItem(name: "maxStartDate", value: iso.format(endDate)),
            URLQueryItem(name: "fields", value: "Overview,Genres"),
            URLQueryItem(name: "enableImageTypes", value: "Primary,Thumb,Backdrop"),
            URLQueryItem(name: "enableUserData", value: "false"),
            URLQueryItem(name: "enableTotalRecordCount", value: "false"),
            URLQueryItem(name: "sortBy", value: "StartDate")
        ])
        return JFLiveProgram.guide(result.items ?? [], channels: channels, baseURL: client.baseURL)
    }

    func getCurrentProgram(for channel: UnifiedChannel) async -> UnifiedProgram? { nil }

    // MARK: - Playback

    nonisolated func buildStreamURL(for channel: UnifiedChannel) -> URL? { nil }

    /// Opens the live stream (one tuner consumer) and plays it through
    /// Jellyfin as one continuous MPEG-TS. Every open needs exactly one close,
    /// which `closeLiveStream` sends from the keepalive's stop.
    func resolveStreamURL(for channel: UnifiedChannel) async throws -> URL? {
        let channelItemID = String(channel.id.dropFirst("\(sourceType.rawValue):\(sourceId):".count))
        let info: JFLivePlaybackInfo = try await client.post(
            "Items/\(channelItemID)/PlaybackInfo", body: JFLivePlaybackRequest(userId: userID))
        guard let url = info.streamURL(channelItemID: channelItemID, baseURL: client.baseURL,
                                       token: client.token ?? "") else {
            throw LiveTVProviderError.channelNotFound(channel.name)
        }
        // A remote HLS source plays straight from its origin, so the stream
        // Jellyfin opened has no consumer: close it now.
        if Self.closeRequest(for: url) == nil, let liveStreamId = info.mediaSources?.first?.liveStreamId {
            try? await client.post("LiveStreams/Close", query: [URLQueryItem(name: "liveStreamId", value: liveStreamId)])
        }
        if Task.isCancelled {
            await PlexLiveTimelineKeepalive.release(url)
            return nil
        }
        return url
    }

    /// Keepalive hook (tvOS): closes the Jellyfin live stream `url` plays, and
    /// stops its transcode if it is one. No-op for any other URL.
    @MainActor
    static func closeLiveStream(_ url: URL) {
        guard let request = closeRequest(for: url) else { return }
        let client = JellyfinClient(baseURL: request.base, token: request.token)
        Task {
            try? await client.post("LiveStreams/Close",
                                   query: [URLQueryItem(name: "liveStreamId", value: request.liveStreamId)])
            if let session = request.transcodeSession {
                try? await client.delete("Videos/ActiveEncodings", query: [
                    URLQueryItem(name: "deviceId", value: client.deviceID),
                    URLQueryItem(name: "playSessionId", value: session)
                ])
            }
        }
    }

    nonisolated static func closeRequest(for url: URL)
        -> (base: URL, token: String, liveStreamId: String, transcodeSession: String?)? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let videos = components.path.range(of: "/videos/", options: .caseInsensitive) else { return nil }
        let items = components.queryItems ?? []
        let value = { (name: String) in items.first { $0.name.lowercased() == name.lowercased() }?.value }
        guard let liveStreamId = value("liveStreamId"), let token = value("ApiKey") else { return nil }
        let isTranscode = components.path.lowercased().hasSuffix(".m3u8")
        components.path = String(components.path[..<videos.lowerBound])
        components.query = nil
        guard let base = components.url else { return nil }
        return (base, token, liveStreamId, isTranscode ? value("playSessionId") : nil)
    }
}

// MARK: - DVR

extension JellyfinLiveTVProvider: LiveTVRecordingProvider {

    /// Jellyfin marks every programme recordable; a series timer matches on
    /// the programme's name, so films are offered one airing only.
    func recordOptions(for program: UnifiedProgram, on channel: UnifiedChannel) async throws -> [LiveTVRecordOption] {
        guard supportsRecording else { throw LiveTVRecordingError.notSupported }
        guard program.endTime > Date() else { throw LiveTVRecordingError.programEnded }
        var options = [LiveTVRecordOption(id: "\(program.id)#once", title: "Record", scope: .single, payload: "once")]
        if !program.isMovie {
            options.append(LiveTVRecordOption(id: "\(program.id)#all", title: "Record Series",
                                              scope: .series, payload: "all"))
            options.append(LiveTVRecordOption(id: "\(program.id)#new", title: "Record New Episodes",
                                              scope: .series, payload: "new"))
        }
        return options
    }

    /// The server's defaults for the programme (padding, keep rules), posted
    /// back as a timer or a series timer.
    func record(_ option: LiveTVRecordOption, program: UnifiedProgram, on channel: UnifiedChannel) async throws {
        var timer: JFTimerDefaults = try await client.get("LiveTv/Timers/Defaults",
                                                          [URLQueryItem(name: "programId", value: program.id)])
        switch option.payload {
        case "all", "new":
            timer.recordNewOnly = option.payload == "new"
            try await client.post("LiveTv/SeriesTimers", query: [], body: timer)
        default:
            try await client.post("LiveTv/Timers", query: [], body: timer)
        }
    }

    func scheduledRecordings() async throws -> [LiveTVScheduledRecording] {
        let result: JFLiveQuery<JFTimer> = try await client.get("LiveTv/Timers")
        let prefix = "\(sourceType.rawValue):\(sourceId):"
        return (result.items ?? []).compactMap { timer -> LiveTVScheduledRecording? in
            guard let id = timer.id, let start = jellyfinDate(timer.startDate),
                  let end = jellyfinDate(timer.endDate) else { return nil }
            var recording = LiveTVScheduledRecording(
                id: id,
                sourceId: sourceId,
                title: timer.name ?? "Recording",
                subtitle: timer.programInfo?.episodeTitle,
                startTime: start,
                endTime: end,
                status: Self.status(timer.status),
                channelName: timer.channelName,
                channelId: timer.channelId.map { prefix + $0 },
                programGuid: nil,
                ruleId: timer.seriesTimerId,
                posterURL: timer.programId.flatMap {
                    jellyfinImageURL(client.baseURL, itemID: $0, type: "Primary",
                                     tag: timer.programInfo?.imageTags?["Primary"])
                }
            )
            recording.ruleIsSeries = timer.seriesTimerId != nil
            return recording
        }
        .sorted { $0.startTime < $1.startTime }
    }

    /// Deleting an in-progress timer stops it and keeps what was recorded; a
    /// series timer's airing is marked cancelled and the rule stays.
    func cancel(_ recording: LiveTVScheduledRecording) async throws {
        try await client.delete("LiveTv/Timers/\(recording.id)")
    }

    func recordingRules() async throws -> [LiveTVRecordingRule] {
        let result: JFLiveQuery<JFSeriesTimer> = try await client.get("LiveTv/SeriesTimers")
        return (result.items ?? []).compactMap { rule in
            guard let id = rule.id else { return nil }
            let mode = rule.recordNewOnly == true ? "New episodes" : "All episodes"
            let channel = rule.recordAnyChannel == true ? nil : rule.channelName
            return LiveTVRecordingRule(id: id, sourceId: sourceId, title: rule.name ?? "Series",
                                       detail: [mode, channel].compactMap { $0 }.joined(separator: " · "))
        }
    }

    /// Removes the series timer and the airings it scheduled.
    func delete(_ rule: LiveTVRecordingRule) async throws {
        try await client.delete("LiveTv/SeriesTimers/\(rule.id)")
    }

    /// `RecordingStatus`. Cancelled also marks a series airing the server
    /// skipped as a repeat.
    private static func status(_ status: String?) -> LiveTVScheduledRecording.Status {
        switch status {
        case "InProgress": return .recording
        case "Completed": return .completed
        case "Cancelled": return .cancelled
        case "Error", "ConflictedNotOk": return .failed
        default: return .scheduled
        }
    }
}

// MARK: - Mapping

/// No-token image URL with the tag that changes when the image does
/// (`JellyfinMediaMapper.imageURL`, callable off the main actor).
private nonisolated func jellyfinImageURL(_ baseURL: URL, itemID: String, type: String, tag: String?) -> URL? {
    guard let tag else { return nil }
    var components = URLComponents(url: baseURL.appending(path: "Items/\(itemID)/Images/\(type)"),
                                   resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "tag", value: tag)]
    return components?.url
}

/// "2026-10-21T13:00:00.0000000Z": seven fractional digits, always UTC.
private nonisolated func jellyfinDate(_ string: String?) -> Date? {
    string.flatMap { try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse($0) }
}

nonisolated extension JFLiveChannel {
    func unifiedChannel(sourceId: String, baseURL: URL) -> UnifiedChannel? {
        guard let id, let name else { return nil }
        let number = (channelNumber ?? self.number).flatMap(ChannelNumber.init)
        return UnifiedChannel(
            id: UnifiedChannel.makeId(sourceType: .jellyfin, sourceId: sourceId, channelId: id),
            sourceType: .jellyfin,
            sourceId: sourceId,
            channelNumber: number,
            name: name,
            logoURL: jellyfinImageURL(baseURL, itemID: id, type: "Primary", tag: imageTags?["Primary"]),
            isFavourite: userData?.isFavorite ?? false
        )
    }
}

nonisolated extension JFLiveProgram {
    static func guide(_ programs: [JFLiveProgram], channels: [UnifiedChannel],
                      baseURL: URL) -> [String: [UnifiedProgram]] {
        let prefix = channels.first.map { "\($0.sourceType.rawValue):\($0.sourceId):" } ?? ""
        let known = Set(channels.map(\.id))
        var guide: [String: [UnifiedProgram]] = [:]
        for dto in programs {
            guard let channelItemID = dto.channelId else { continue }
            let channelId = prefix + channelItemID
            guard known.contains(channelId),
                  let program = dto.unifiedProgram(channelId: channelId, baseURL: baseURL) else { continue }
            guide[channelId, default: []].append(program)
        }
        return guide.mapValues { $0.sorted { $0.startTime < $1.startTime } }
    }

    func unifiedProgram(channelId: String, baseURL: URL) -> UnifiedProgram? {
        guard let id, let name, let start = jellyfinDate(startDate), let end = jellyfinDate(endDate),
              end > start else { return nil }
        var episode: String?
        if isSeries == true, let indexNumber {
            episode = parentIndexNumber.map { "S\($0) E\(indexNumber)" } ?? "E\(indexNumber)"
        }
        let genreList = (genres ?? []).joined(separator: ", ")
        let flagged = isSports == true ? "Sports" : isNews == true ? "News"
            : isKids == true ? "Kids" : isMovie == true ? "Movie" : nil
        return UnifiedProgram(
            id: id,
            channelId: channelId,
            title: name,
            subtitle: episodeTitle,
            description: overview,
            startTime: start,
            endTime: end,
            category: genreList.isEmpty ? flagged : genreList,
            iconURL: jellyfinImageURL(baseURL, itemID: id, type: "Primary", tag: imageTags?["Primary"]),
            landscapeURL: jellyfinImageURL(baseURL, itemID: id, type: "Thumb", tag: imageTags?["Thumb"])
                ?? jellyfinImageURL(baseURL, itemID: id, type: "Backdrop", tag: backdropImageTags?.first),
            episodeNumber: episode,
            // Jellyfin web's rule; Schedules Direct flags only season premieres.
            isNew: isPremiere == true || (isSeries == true && isRepeat != true),
            year: isMovie == true ? productionYear : nil,
            contentRating: officialRating,
            isMovie: isMovie ?? false,
            isLive: isLive ?? false
        )
    }
}

nonisolated extension JFLivePlaybackInfo {
    /// The static stream when the server allows direct streaming (an M3U
    /// tuner's TS sources), else a remote HLS source's own URL (FAST channels:
    /// the server refuses to direct stream HLS and would remux it, #372), else
    /// its HLS transcode. Jellyfin URLs carry the live stream id the close needs.
    func streamURL(channelItemID: String, baseURL: URL, token: String) -> URL? {
        guard let source = mediaSources?.first, let liveStreamId = source.liveStreamId else { return nil }
        let base = baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        var components: URLComponents?
        if source.supportsDirectStream == true {
            components = URLComponents(string: "\(base)/Videos/\(channelItemID)/stream.ts")
            components?.queryItems = [
                URLQueryItem(name: "static", value: "true"),
                URLQueryItem(name: "mediaSourceId", value: source.id),
                URLQueryItem(name: "liveStreamId", value: liveStreamId),
                URLQueryItem(name: "playSessionId", value: playSessionId),
                URLQueryItem(name: "ApiKey", value: token)
            ]
        } else if source.container == "hls", let path = source.path, let url = URL(string: path),
                  url.scheme == "http" || url.scheme == "https" {
            return url
        } else if let path = source.transcodingUrl {
            components = URLComponents(string: base + path)
            if !(components?.queryItems ?? []).contains(where: { $0.name.lowercased() == "livestreamid" }) {
                components?.queryItems?.append(URLQueryItem(name: "LiveStreamId", value: liveStreamId))
            }
        }
        return components?.url
    }
}

// MARK: - DTOs

nonisolated struct JFLiveQuery<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]?
    let totalRecordCount: Int?
}

nonisolated struct JFLiveChannel: Decodable, Sendable {
    nonisolated struct UserData: Decodable, Sendable { let isFavorite: Bool? }
    let id: String?
    let name: String?
    let number: String?
    let channelNumber: String?
    let imageTags: [String: String]?
    let userData: UserData?
}

nonisolated struct JFLiveProgram: Decodable, Sendable {
    let id: String?
    let channelId: String?
    let name: String?
    let episodeTitle: String?
    let overview: String?
    let startDate: String?
    let endDate: String?
    let genres: [String]?
    let officialRating: String?
    let productionYear: Int?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let imageTags: [String: String]?
    let backdropImageTags: [String]?
    let isSeries: Bool?
    let isMovie: Bool?
    let isSports: Bool?
    let isNews: Bool?
    let isKids: Bool?
    let isLive: Bool?
    let isPremiere: Bool?
    let isRepeat: Bool?
}

/// `LiveTv/Timers/Defaults`, posted back unchanged (but for the new-only
/// choice) to create a timer or series timer. `ServiceName` is required:
/// without it the server answers 500.
nonisolated struct JFTimerDefaults: Codable, Sendable {
    let serviceName: String?
    let channelId: String?
    let programId: String?
    let name: String?
    let overview: String?
    let startDate: String?
    let endDate: String?
    let keepUntil: String?
    let prePaddingSeconds: Int?
    let postPaddingSeconds: Int?
    let isPrePaddingRequired: Bool?
    let isPostPaddingRequired: Bool?
    let priority: Int?
    let keepUpTo: Int?
    let recordAnyTime: Bool?
    let recordAnyChannel: Bool?
    var recordNewOnly: Bool?
    let skipEpisodesInLibrary: Bool?
    let days: [String]?
    let dayPattern: String?
}

nonisolated struct JFTimer: Decodable, Sendable {
    nonisolated struct Program: Decodable, Sendable {
        let episodeTitle: String?
        let imageTags: [String: String]?
    }
    let id: String?
    let status: String?
    let name: String?
    let channelId: String?
    let channelName: String?
    let programId: String?
    let seriesTimerId: String?
    let startDate: String?
    let endDate: String?
    let programInfo: Program?
}

nonisolated struct JFSeriesTimer: Decodable, Sendable {
    let id: String?
    let name: String?
    let channelName: String?
    let recordNewOnly: Bool?
    let recordAnyChannel: Bool?
}

nonisolated struct JFLivePlaybackInfo: Decodable, Sendable {
    nonisolated struct Source: Decodable, Sendable {
        let id: String?
        let liveStreamId: String?
        let path: String?
        let container: String?
        let supportsDirectStream: Bool?
        let transcodingUrl: String?
    }
    let mediaSources: [Source]?
    let playSessionId: String?
}

/// PlaybackInfo that opens the live stream (`AutoOpenLiveStream`). A profile
/// that direct-plays any video gets the static stream; the HLS profile is the
/// fallback for a tuner that cannot direct stream.
nonisolated struct JFLivePlaybackRequest: Encodable, Sendable {
    nonisolated struct Profile: Encodable, Sendable {
        let maxStreamingBitrate = 400_000_000
        let directPlayProfiles = [["Type": "Video"]]
        let transcodingProfiles = [JFPlaybackInfoRequest.Transcoding(
            container: "ts", type: "Video", videoCodec: "h264,hevc", audioCodec: "aac,ac3,eac3",
            protocol: "hls", context: "Streaming", maxAudioChannels: "6", breakOnNonKeyFrames: true)]
    }
    let userId: String
    let autoOpenLiveStream = true
    let enableDirectPlay = true
    let enableDirectStream = true
    let enableTranscoding = true
    let maxStreamingBitrate = 400_000_000
    let deviceProfile = Profile()
}
