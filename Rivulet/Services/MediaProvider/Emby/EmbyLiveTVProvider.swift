// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyLiveTVProvider.swift
//  Rivulet
//
//  The signed-in Emby server's Live TV as a Live TV source. It comes and goes
//  with the sign-in (`sync`), never through an add-source step, and is never
//  saved. NOT MEASURED against a licensed server: Live TV needs Emby Premiere,
//  and the free test server answers every read with an empty 200, so only the
//  empty case is observed. Everything else follows the SDK schema and the
//  Jellyfin shape. No recording: the seam's DVR protocol is not adopted.
//

import Foundation

actor EmbyLiveTVProvider: LiveTVProvider {
    let sourceType: LiveTVSourceType = .emby
    let sourceId: String
    let displayName: String

    private let client: EmbyClient
    private let userID: String
    private var cachedChannels: [UnifiedChannel] = []

    init(provider: EmbyProvider) {
        sourceId = provider.id
        displayName = String(localized: "\(provider.displayName) Live TV")
        client = provider.client
        userID = provider.userID
    }

    var isConnected: Bool { true }

    // MARK: - Automatic source

    /// Set when the user hid the server's Live TV.
    static let hiddenKey = "liveTVHideEmby"
    /// The server's Live TV while hidden, so Settings can list it as Off.
    @MainActor static var hiddenSource: LiveTVDataStore.LiveTVSourceInfo?
    /// Each sync supersedes the last, so a probe still in flight at sign-out cannot install a source.
    @MainActor private static var syncTask: Task<Void, Never>?

    /// Shows or hides the signed-in server's Live TV; the task ends once the source is found again.
    @MainActor
    static func setHidden(_ hide: Bool) -> Task<Void, Never>? {
        UserDefaults.standard.set(hide, forKey: hiddenKey)
        let id = EmbySession.account?.providerID
        return sync(MediaProviderRegistry.shared.secondaryProviders.first { $0.id == id } as? EmbyProvider)
    }

    /// Adds the server's Live TV only when it lists a channel: a free server answers every read
    /// with an empty 200, and `LiveTv/Info.IsEnabled` is true without a licence. A failed check changes nothing.
    @MainActor @discardableResult
    static func sync(_ provider: EmbyProvider?) -> Task<Void, Never>? {
        let store = LiveTVDataStore.shared
        syncTask?.cancel()
        guard let provider else {
            hiddenSource = nil
            store.setServerSource(nil, of: .emby)
            return nil
        }
        let task = Task { @MainActor in
            let probe: EmbyLiveQuery<EmbyLiveChannel>
            do {
                probe = try await provider.client.get("LiveTv/Channels", [
                    URLQueryItem(name: "UserId", value: provider.userID),
                    URLQueryItem(name: "Limit", value: "1")
                ])
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            guard !(probe.items ?? []).isEmpty else {
                hiddenSource = nil
                store.setServerSource(nil, of: .emby)
                return
            }
            guard !UserDefaults.standard.bool(forKey: hiddenKey) else {
                hiddenSource = LiveTVDataStore.LiveTVSourceInfo(
                    id: provider.id, sourceType: .emby, displayName: String(localized: "\(provider.displayName) Live TV"),
                    channelCount: 0, isConnected: false, lastSync: nil)
                store.setServerSource(nil, of: .emby)
                return
            }
            hiddenSource = nil
            if !store.hasSource(id: provider.id) {
                store.setServerSource(EmbyLiveTVProvider(provider: provider), of: .emby)
            }
        }
        syncTask = task
        return task
    }

    // MARK: - Channels

    // ponytail: the lineup is cached for the provider's life (a sign-in);
    // Refresh Channels or a relaunch picks up server changes.
    func fetchChannels() async throws -> [UnifiedChannel] {
        cachedChannels.isEmpty ? try await refreshChannels() : cachedChannels
    }

    func refreshChannels() async throws -> [UnifiedChannel] {
        let result: EmbyLiveQuery<EmbyLiveChannel> = try await client.get("LiveTv/Channels", [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "AddCurrentProgram", value: "false"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary"),
            URLQueryItem(name: "EnableUserData", value: "true")
        ])
        let channels = (result.items ?? []).compactMap {
            $0.unifiedChannel(sourceId: sourceId, baseURL: client.baseURL)
        }
        cachedChannels = channels
        return channels
    }

    // MARK: - Guide

    /// One request for the whole window, filtered to the lineup here, so a long channel list
    /// never rides in the URL. Programmes still airing at the window's start are included.
    func fetchEPG(for channels: [UnifiedChannel], startDate: Date,
                  endDate: Date) async throws -> [String: [UnifiedProgram]] {
        let result: EmbyLiveQuery<EmbyLiveProgram> = try await client.get("LiveTv/Programs",
            Self.programQuery(userID: userID) + [
                URLQueryItem(name: "MinEndDate", value: Self.queryDate(startDate)),
                URLQueryItem(name: "MaxStartDate", value: Self.queryDate(endDate))
            ])
        return EmbyLiveProgram.guide(result.items ?? [], channels: channels, baseURL: client.baseURL)
    }

    /// The programme airing now, or nil when the guide has none or the call fails.
    func getCurrentProgram(for channel: UnifiedChannel) async -> UnifiedProgram? {
        let now = Self.queryDate(Date())
        let result: EmbyLiveQuery<EmbyLiveProgram>? = try? await client.get("LiveTv/Programs",
            Self.programQuery(userID: userID) + [
                URLQueryItem(name: "ChannelIds", value: channelItemID(channel)),
                URLQueryItem(name: "MinEndDate", value: now),
                URLQueryItem(name: "MaxStartDate", value: now),
                URLQueryItem(name: "Limit", value: "1")
            ])
        return result?.items?.first?.unifiedProgram(channelId: channel.id, baseURL: client.baseURL)
    }

    private static func programQuery(userID: String) -> [URLQueryItem] {
        [
            URLQueryItem(name: "UserId", value: userID),
            URLQueryItem(name: "Fields", value: "Overview,Genres"),
            URLQueryItem(name: "EnableImageTypes", value: "Primary,Thumb,Backdrop"),
            URLQueryItem(name: "EnableUserData", value: "false"),
            URLQueryItem(name: "SortBy", value: "StartDate")
        ]
    }

    /// `2026-11-04T13:52:12Z`; the server reads UTC.
    private static func queryDate(_ date: Date) -> String { date.formatted(Date.ISO8601FormatStyle()) }

    private func channelItemID(_ channel: UnifiedChannel) -> String {
        String(channel.id.dropFirst("\(sourceType.rawValue):\(sourceId):".count))
    }

    // MARK: - Playback

    nonisolated func buildStreamURL(for channel: UnifiedChannel) -> URL? { nil }

    /// Opens the live stream (one tuner) and plays it through Emby. Every open needs one close,
    /// which `closeLiveStream` sends from the keepalive's stop.
    func resolveStreamURL(for channel: UnifiedChannel) async throws -> URL? {
        let channelItemID = channelItemID(channel)
        let info: EmbyPlaybackInfoResponse
        do {
            info = try await client.post("Items/\(channelItemID)/PlaybackInfo", body: EmbyLivePlaybackRequest(userId: userID))
        } catch MediaProviderError.backendSpecific(let message) where message.localizedCaseInsensitiveContains("tuner") {
            throw LiveTVProviderError.tunersBusy
        }
        guard let url = info.liveStreamURL(channelID: channelItemID, client: client) else {
            throw LiveTVProviderError.channelNotFound(channel.name)
        }
        // A remote HLS source plays from its origin, so the stream Emby opened has no consumer.
        if Self.closeRequest(for: url) == nil, let source = info.mediaSources?.first, let liveStreamID = source.liveStreamId {
            await Self.close(.init(itemID: channelItemID, liveStreamID: liveStreamID, mediaSourceID: source.id,
                                   playSessionID: info.playSessionId, encodeDeviceID: nil), client: client)
        }
        if Task.isCancelled {
            await PlexLiveTimelineKeepalive.release(url, sourceID: sourceId)
            return nil
        }
        return url
    }

    /// Everything a stop needs, read back off the stream URL.
    struct CloseRequest: Sendable, Equatable {
        var itemID: String
        var liveStreamID: String
        var mediaSourceID: String?
        var playSessionID: String?
        /// Set for an HLS transcode: the device its encode runs under, to end it.
        var encodeDeviceID: String?
    }

    /// Keepalive hook (tvOS): closes the Emby live stream `url` plays, and stops its transcode if
    /// it is one. No-op for any other URL.
    @MainActor
    static func closeLiveStream(_ url: URL) {
        guard let parsed = closeRequest(for: url) else { return }
        let client = EmbyClient(baseURL: parsed.base, token: parsed.token)
        var request = parsed.request
        if request.encodeDeviceID == "" { request.encodeDeviceID = client.deviceID }
        Task { await close(request, client: client) }
    }

    /// Both calls, always: `LiveStreams/Close` answers 204 for any id, so it proves nothing, and
    /// the stopped report is what the server's session accounting listens to.
    static func close(_ request: CloseRequest, client: EmbyClient) async {
        try? await client.post("Sessions/Playing/Stopped", body: EmbyLiveStopReport(
            itemId: request.itemID, mediaSourceId: request.mediaSourceID,
            playSessionId: request.playSessionID, liveStreamId: request.liveStreamID, positionTicks: 0))
        try? await client.post("LiveStreams/Close", query: [URLQueryItem(name: "LiveStreamId", value: request.liveStreamID)])
        if let device = request.encodeDeviceID, let session = request.playSessionID {
            try? await client.delete("Videos/ActiveEncodings", query: [
                URLQueryItem(name: "DeviceId", value: device),
                URLQueryItem(name: "PlaySessionId", value: session)
            ])
        }
    }

    /// Nil for a URL that is not an Emby live stream (no `LiveStreamId` and `api_key`). An empty
    /// `encodeDeviceID` on a transcode means "this device": the URL did not name one.
    nonisolated static func closeRequest(for url: URL) -> (base: URL, token: String, request: CloseRequest)? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let videos = components.path.range(of: "/videos/", options: [.caseInsensitive, .backwards]) else { return nil }
        let items = components.queryItems ?? []
        let value = { (name: String) in items.first { $0.name.lowercased() == name.lowercased() }?.value }
        guard let liveStreamID = value("LiveStreamId"), let token = value("api_key") else { return nil }
        let itemID = components.path[videos.upperBound...].prefix { $0 != "/" }
        guard !itemID.isEmpty else { return nil }
        let isTranscode = components.path.lowercased().hasSuffix(".m3u8")
        components.path = String(components.path[..<videos.lowerBound])
        components.query = nil
        guard let base = components.url else { return nil }
        return (base, token, CloseRequest(
            itemID: String(itemID), liveStreamID: liveStreamID, mediaSourceID: value("MediaSourceId"),
            playSessionID: value("PlaySessionId"), encodeDeviceID: isTranscode ? (value("DeviceId") ?? "") : nil))
    }
}

// MARK: - Mapping

nonisolated extension EmbyLiveChannel {
    func unifiedChannel(sourceId: String, baseURL: URL) -> UnifiedChannel? {
        guard let id, let name else { return nil }
        return UnifiedChannel(
            id: UnifiedChannel.makeId(sourceType: .emby, sourceId: sourceId, channelId: id.value),
            sourceType: .emby,
            sourceId: sourceId,
            channelNumber: (channelNumber ?? number).flatMap(ChannelNumber.init),
            name: name,
            logoURL: EmbyMediaMapper.imageURL(baseURL, itemID: id, type: "Primary", tag: imageTags?["Primary"]),
            isFavourite: userData?.isFavorite ?? false
        )
    }
}

nonisolated extension EmbyLiveProgram {
    static func guide(_ programs: [EmbyLiveProgram], channels: [UnifiedChannel],
                      baseURL: URL) -> [String: [UnifiedProgram]] {
        let prefix = channels.first.map { "\($0.sourceType.rawValue):\($0.sourceId):" } ?? ""
        let known = Set(channels.map(\.id))
        var guide: [String: [UnifiedProgram]] = [:]
        for dto in programs {
            guard let channelItemID = dto.channelId else { continue }
            let channelId = prefix + channelItemID.value
            guard known.contains(channelId),
                  let program = dto.unifiedProgram(channelId: channelId, baseURL: baseURL) else { continue }
            guide[channelId, default: []].append(program)
        }
        return guide.mapValues { $0.sorted { $0.startTime < $1.startTime } }
    }

    func unifiedProgram(channelId: String, baseURL: URL) -> UnifiedProgram? {
        guard let id, let name, let start = EmbyJSON.date(startDate), let end = EmbyJSON.date(endDate),
              end > start else { return nil }
        var episode: String?
        if isSeries == true, let indexNumber {
            episode = parentIndexNumber.map { String(localized: "S\($0) E\(indexNumber)") } ?? String(localized: "E\(indexNumber)")
        }
        let genreList = (genres ?? []).joined(separator: ", ")
        let flagged = isSports == true ? "Sports" : isNews == true ? "News"
            : isKids == true ? "Kids" : isMovie == true ? "Movie" : nil
        return UnifiedProgram(
            id: id.value,
            channelId: channelId,
            title: name,
            subtitle: episodeTitle,
            description: overview,
            startTime: start,
            endTime: end,
            category: genreList.isEmpty ? flagged : genreList,
            iconURL: EmbyMediaMapper.imageURL(baseURL, itemID: id, type: "Primary", tag: imageTags?["Primary"]),
            landscapeURL: EmbyMediaMapper.imageURL(baseURL, itemID: id, type: "Thumb", tag: imageTags?["Thumb"])
                ?? EmbyMediaMapper.imageURL(baseURL, itemID: id, type: "Backdrop", tag: backdropImageTags?.first),
            episodeNumber: episode,
            isNew: isPremiere == true || (isSeries == true && isRepeat != true),
            year: isMovie == true ? productionYear : nil,
            contentRating: officialRating,
            isMovie: isMovie ?? false,
            isLive: isLive ?? false
        )
    }
}

nonisolated extension EmbyPlaybackInfoResponse {
    /// The static stream when the server allows direct streaming (an M3U tuner's TS sources), else
    /// a remote HLS source's own URL (the server would only remux it), else its HLS transcode.
    /// Server paths come without `/emby`; the token rides as `api_key` and the live stream id is
    /// always present, because the close reads both back off the URL.
    func liveStreamURL(channelID: String, client: EmbyClient) -> URL? {
        guard let source = mediaSources?.first, let liveStreamID = source.liveStreamId else { return nil }
        if source.supportsDirectStream == true {
            return client.authenticatedURL("Videos/\(channelID)/stream.ts", [
                URLQueryItem(name: "Static", value: "true"),
                URLQueryItem(name: "MediaSourceId", value: source.id),
                URLQueryItem(name: "LiveStreamId", value: liveStreamID),
                URLQueryItem(name: "PlaySessionId", value: playSessionId)
            ].filter { $0.value != nil })
        }
        if source.container == "hls", let path = source.path, let url = URL(string: path),
           url.scheme == "http" || url.scheme == "https" {
            return url
        }
        guard let path = source.transcodingUrl, let url = client.resolve(path),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var query = components.queryItems ?? []
        let has = { (name: String) in query.contains { $0.name.lowercased() == name.lowercased() } }
        if !has("LiveStreamId") { query.append(URLQueryItem(name: "LiveStreamId", value: liveStreamID)) }
        if !has("api_key"), let token = client.token { query.append(URLQueryItem(name: "api_key", value: token)) }
        components.queryItems = query
        return components.url
    }
}

// MARK: - DTOs

nonisolated struct EmbyLiveQuery<Item: Decodable & Sendable>: Decodable, Sendable {
    let items: [Item]?
    let totalRecordCount: Int?
}

nonisolated struct EmbyLiveChannel: Decodable, Sendable {
    nonisolated struct UserData: Decodable, Sendable { let isFavorite: Bool? }
    let id: EmbyID?
    let name: String?
    let number: String?
    let channelNumber: String?
    let imageTags: [String: String]?
    let userData: UserData?
}

nonisolated struct EmbyLiveProgram: Decodable, Sendable {
    let id: EmbyID?
    let channelId: EmbyID?
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

/// PlaybackInfo that opens the live stream. A profile that direct-plays any video gets the
/// static stream; the HLS profile is the fallback for a tuner that cannot direct stream.
nonisolated struct EmbyLivePlaybackRequest: Encodable, Sendable {
    let userId: String
    let autoOpenLiveStream = true
    let isPlayback = true
    let enableDirectPlay = true
    let enableDirectStream = true
    let enableTranscoding = true
    let maxStreamingBitrate = 400_000_000
    let deviceProfile = EmbyPlaybackInfoRequest.Profile(
        maxStreamingBitrate: 400_000_000,
        directPlayProfiles: [.init(type: "Video")],
        transcodingProfiles: [.init(
            container: "ts", type: "Video", videoCodec: "h264,hevc", audioCodec: "aac,ac3,eac3",
            protocol: "hls", context: "Streaming", maxAudioChannels: "6", breakOnNonKeyFrames: true)],
        subtitleProfiles: [])
}

/// `Sessions/Playing/Stopped` for a live stream: the `LiveStreamId` is what lets the server free it.
nonisolated struct EmbyLiveStopReport: Encodable, Sendable {
    let itemId: String
    let mediaSourceId: String?
    let playSessionId: String?
    let liveStreamId: String
    let positionTicks: Int64
}
