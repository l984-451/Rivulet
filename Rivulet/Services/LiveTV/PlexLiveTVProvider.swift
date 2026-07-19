// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexLiveTVProvider.swift
//  Rivulet
//
//  LiveTVProvider implementation for Plex Live TV
//

import Foundation
import Sentry

/// LiveTVProvider implementation for Plex Live TV
actor PlexLiveTVProvider: LiveTVProvider {

    // MARK: - Properties

    let sourceType: LiveTVSourceType = .plex
    let sourceId: String
    let displayName: String

    let serverURL: String  // Exposed for persistence
    private let authToken: String
    private let networkManager = PlexNetworkManager.shared

    // Cached data
    private var cachedChannels: [UnifiedChannel] = []
    private var cachedEPG: [String: [UnifiedProgram]] = [:]
    /// Time range the merged `cachedEPG` covers, so a cache hit is served only
    /// when it spans the requested window (see the lazy-load note in fetchEPG).
    private var cachedEPGRange: (start: Date, end: Date)?
    private var lastChannelFetch: Date?
    private var lastEPGFetch: Date?
    private var capabilities: PlexLiveTVCapabilities?

    // Cache duration
    private let channelCacheDuration: TimeInterval = 300  // 5 minutes
    private let epgCacheDuration: TimeInterval = 1800     // 30 minutes

    // MARK: - Initialization

    init(serverURL: String, authToken: String, serverName: String) {
        self.serverURL = serverURL
        self.authToken = authToken
        self.sourceId = "plex:\(serverURL)"
        self.displayName = "\(serverName) Live TV"
    }

    // MARK: - LiveTVProvider Protocol

    var isConnected: Bool {
        get async {
            // Check if Plex Live TV is available
            do {
                if let caps = capabilities {
                    return caps.liveTVEnabled
                }
                let caps = try await networkManager.getLiveTVCapabilities(
                    serverURL: serverURL,
                    authToken: authToken
                )
                return caps.liveTVEnabled
            } catch {
                return false
            }
        }
    }

    func fetchChannels() async throws -> [UnifiedChannel] {
        // Return cached if still valid
        if let lastFetch = lastChannelFetch,
           Date().timeIntervalSince(lastFetch) < channelCacheDuration,
           !cachedChannels.isEmpty {

            // Log cache hit (GitHub #64 - DVB diagnostics)
            let breadcrumb = Breadcrumb(level: .info, category: "plex_livetv")
            breadcrumb.message = "Returning cached Live TV channels"
            breadcrumb.data = [
                "channel_count": cachedChannels.count,
                "cache_age_seconds": Int(Date().timeIntervalSince(lastFetch)),
                "server_host": URL(string: serverURL)?.host ?? "unknown"
            ]
            SentryBridge.addBreadcrumb(breadcrumb)

            return cachedChannels
        }

        return try await refreshChannels()
    }

    func refreshChannels() async throws -> [UnifiedChannel] {

        // Log refresh start (GitHub #64 - DVB diagnostics)
        let startBreadcrumb = Breadcrumb(level: .info, category: "plex_livetv")
        startBreadcrumb.message = "Starting Plex Live TV channel refresh"
        startBreadcrumb.data = [
            "server_host": URL(string: serverURL)?.host ?? "unknown",
            "source_id": sourceId
        ]
        SentryBridge.addBreadcrumb(startBreadcrumb)

        // First check capabilities
        let caps: PlexLiveTVCapabilities
        do {
            caps = try await networkManager.getLiveTVCapabilities(
                serverURL: serverURL,
                authToken: authToken
            )
        } catch {
            // Capture Plex Live TV capability check failure
            let capturedServerURL = self.serverURL
            SentryBridge.capture(error: error) { scope in
                scope.setTag(value: "plex_livetv", key: "component")
                scope.setTag(value: "capability_check", key: "operation")
                scope.setExtra(value: capturedServerURL, key: "server_url")
            }
            throw error
        }
        capabilities = caps

        // Log capabilities result (GitHub #64 - DVB diagnostics)
        let capsBreadcrumb = Breadcrumb(level: .info, category: "plex_livetv")
        capsBreadcrumb.message = "Plex Live TV capabilities checked"
        capsBreadcrumb.data = [
            "allow_tuners": caps.allowTuners,
            "live_tv_enabled": caps.liveTVEnabled,
            "has_dvr": caps.hasDVR,
            "server_host": URL(string: serverURL)?.host ?? "unknown"
        ]
        SentryBridge.addBreadcrumb(capsBreadcrumb)

        guard caps.liveTVEnabled else {
            throw LiveTVProviderError.notConnected
        }

        // Fetch channels
        let plexChannels: [PlexLiveTVChannel]
        do {
            plexChannels = try await networkManager.getLiveTVChannels(
                serverURL: serverURL,
                authToken: authToken
            )
        } catch {
            // Capture Plex Live TV channel fetch failure
            let capturedServerURL = self.serverURL
            SentryBridge.capture(error: error) { scope in
                scope.setTag(value: "plex_livetv", key: "component")
                scope.setTag(value: "channel_fetch", key: "operation")
                scope.setExtra(value: capturedServerURL, key: "server_url")
            }
            throw error
        }

        // Convert to UnifiedChannel
        let channels = plexChannels.map { plexChannel in
            plexChannel.toUnifiedChannel(
                sourceId: sourceId,
                serverURL: serverURL,
                authToken: authToken
            )
        }

        // Log channel breakdown (GitHub #64 - DVB diagnostics)
        let channelsWithStreamURL = channels.filter { $0.streamURL != nil }.count
        let channelsNeedingTranscode = channels.count - channelsWithStreamURL
        let breakdownBreadcrumb = Breadcrumb(level: .info, category: "plex_livetv")
        breakdownBreadcrumb.message = "Plex Live TV channel refresh completed"
        breakdownBreadcrumb.data = [
            "total_channels": channels.count,
            "channels_with_stream_url": channelsWithStreamURL,
            "channels_needing_transcode": channelsNeedingTranscode,
            "server_host": URL(string: serverURL)?.host ?? "unknown"
        ]
        SentryBridge.addBreadcrumb(breakdownBreadcrumb)

        // Update cache
        cachedChannels = channels
        lastChannelFetch = Date()

        return channels
    }

    func fetchEPG(
        for channels: [UnifiedChannel],
        startDate: Date,
        endDate: Date
    ) async throws -> [String: [UnifiedProgram]] {
        // Return cached if still valid and covers the requested range
        // Serve from cache only when it's fresh AND actually COVERS the
        // requested range. The guide's lazy horizontal loading asks for later
        // windows ([loadedEnd, loadedEnd+chunk]); a range-blind cache would
        // return the initial grid filtered to empty and stall the extension.
        if let lastFetch = lastEPGFetch,
           Date().timeIntervalSince(lastFetch) < epgCacheDuration,
           let range = cachedEPGRange,
           range.start <= startDate, range.end >= endDate,
           !cachedEPG.isEmpty {
            return filterEPG(cachedEPG, channels: channels, startDate: startDate, endDate: endDate)
        }

        // Build channel ID list for filtering
        let channelRatingKeys = channels.compactMap { channel -> String? in
            // Extract the rating key from the unified ID (plex:serverURL:ratingKey)
            let components = channel.id.split(separator: ":")
            return components.count >= 3 ? String(components.last!) : nil
        }

        // Fetch guide data
        let guideChannels: [PlexLiveTVGuideChannel]
        do {
            guideChannels = try await networkManager.getLiveTVGuide(
                serverURL: serverURL,
                authToken: authToken,
                channelIds: channelRatingKeys.isEmpty ? nil : channelRatingKeys,
                startTime: startDate,
                endTime: endDate
            )
        } catch {
            // Capture Plex Live TV EPG fetch failure
            let capturedServerURL = self.serverURL
            let capturedChannelCount = channels.count
            SentryBridge.capture(error: error) { scope in
                scope.setTag(value: "plex_livetv", key: "component")
                scope.setTag(value: "epg_fetch", key: "operation")
                scope.setExtra(value: capturedServerURL, key: "server_url")
                scope.setExtra(value: capturedChannelCount, key: "channel_count")
            }
            throw error
        }

        // Build unified channel ID lookup
        // Use uniquingKeysWith to handle duplicate ratingKeys (keep first occurrence)
        let ratingKeyToUnifiedId = Dictionary(
            channels.map { channel -> (String, String) in
                let components = channel.id.split(separator: ":")
                let ratingKey = components.count >= 3 ? String(components.last!) : channel.id
                return (ratingKey, channel.id)
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Convert to UnifiedProgram
        var unifiedEPG: [String: [UnifiedProgram]] = [:]
        var matchedChannels = 0
        var unmatchedChannels: [String] = []

        for guideChannel in guideChannels {
            guard let ratingKey = guideChannel.ratingKey else {
                print("📺 PlexLiveTVProvider: Guide channel missing ratingKey")
                continue
            }

            guard let unifiedChannelId = ratingKeyToUnifiedId[ratingKey] else {
                unmatchedChannels.append(ratingKey)
                continue
            }

            guard let programs = guideChannel.Metadata else {
                continue
            }

            matchedChannels += 1

            let unifiedPrograms = programs.compactMap { plexProgram -> UnifiedProgram? in
                let result = plexProgram.toUnifiedProgram(unifiedChannelId: unifiedChannelId, serverURL: serverURL, authToken: authToken)
                if result == nil {
                    print("📺 PlexLiveTVProvider: ⚠️ Failed to convert program '\(plexProgram.title)' - beginsAt: \(plexProgram.beginsAt as Any), endsAt: \(plexProgram.endsAt as Any)")
                }
                return result
            }

            if !unifiedPrograms.isEmpty {
                unifiedEPG[unifiedChannelId] = unifiedPrograms
            }
        }

        // Update cache: MERGE this window into the retained grid (append +
        // de-dupe by id) and widen the covered range, so a later lazy-load
        // window adds to what's cached instead of replacing it.
        for (channelId, programs) in unifiedEPG {
            var existing = cachedEPG[channelId] ?? []
            let known = Set(existing.map(\.id))
            existing.append(contentsOf: programs.filter { !known.contains($0.id) })
            existing.sort { $0.startTime < $1.startTime }
            cachedEPG[channelId] = existing
        }
        if let range = cachedEPGRange {
            cachedEPGRange = (min(range.start, startDate), max(range.end, endDate))
        } else {
            cachedEPGRange = (startDate, endDate)
        }
        lastEPGFetch = Date()

        return unifiedEPG
    }

    func getCurrentProgram(for channel: UnifiedChannel) async -> UnifiedProgram? {
        guard let programs = cachedEPG[channel.id] else {
            return nil
        }

        let now = Date()
        return programs.first { program in
            program.startTime <= now && program.endTime > now
        }
    }

    nonisolated func buildStreamURL(for channel: UnifiedChannel) -> URL? {
        guard let originalURL = channel.streamURL else {

            // Log missing stream URL (GitHub #64 - DVB diagnostics)
            let breadcrumb = Breadcrumb(level: .warning, category: "plex_livetv")
            breadcrumb.message = "No stream URL available for channel"
            breadcrumb.data = [
                "channel_name": channel.name,
                "channel_id": channel.id,
                "operation": "build_stream_url"
            ]
            SentryBridge.addBreadcrumb(breadcrumb)

            return nil
        }

        // For Plex transcode URLs, generate a fresh session ID each time
        // The session ID was baked in when channels were fetched, but Plex
        // may reject reused session IDs for subsequent playback attempts
        guard originalURL.path.contains("/transcode/") else {
            // HDHomeRun or other direct URLs - use as-is

            // Log direct URL passthrough (GitHub #64 - DVB diagnostics)
            let breadcrumb = Breadcrumb(level: .info, category: "plex_livetv")
            breadcrumb.message = "Using direct stream URL (HDHomeRun)"
            breadcrumb.data = [
                "channel_name": channel.name,
                "channel_id": channel.id,
                "stream_type": "hdhr_direct",
                "url_host": originalURL.host ?? "unknown"
            ]
            SentryBridge.addBreadcrumb(breadcrumb)

            return originalURL
        }

        // Replace the session parameter with a fresh UUID
        guard var components = URLComponents(url: originalURL, resolvingAgainstBaseURL: false) else {
            print("📺 PlexLiveTVProvider.buildStreamURL: Failed to parse URL components for '\(channel.name)'")

            // Log URL parsing failure (GitHub #64 - DVB diagnostics)
            let breadcrumb = Breadcrumb(level: .error, category: "plex_livetv")
            breadcrumb.message = "Failed to parse transcode URL components"
            breadcrumb.data = [
                "channel_name": channel.name,
                "channel_id": channel.id,
                "original_url_path": originalURL.path
            ]
            SentryBridge.addBreadcrumb(breadcrumb)

            return originalURL
        }

        // Extract old session ID for logging
        let oldSessionId = components.queryItems?.first(where: { $0.name == "session" })?.value

        let newSessionId = UUID().uuidString.uppercased()
        var queryItems = components.queryItems ?? []

        // Find and replace the session parameter
        if let sessionIndex = queryItems.firstIndex(where: { $0.name == "session" }) {
            queryItems[sessionIndex] = URLQueryItem(name: "session", value: newSessionId)
        } else {
            // No session parameter exists, add one
            queryItems.append(URLQueryItem(name: "session", value: newSessionId))
        }

        components.queryItems = queryItems
        let newURL = components.url ?? originalURL

        // Log session ID regeneration (GitHub #64 - DVB diagnostics)
        let breadcrumb = Breadcrumb(level: .info, category: "plex_livetv")
        breadcrumb.message = "Generated fresh Plex transcode session"
        breadcrumb.data = [
            "channel_name": channel.name,
            "channel_id": channel.id,
            "stream_type": "plex_transcode",
            "old_session_id": oldSessionId.map { String($0.prefix(8)) } ?? "none",
            "new_session_id": String(newSessionId.prefix(8)),
            "url_host": newURL.host ?? "unknown",
            "url_path": newURL.path
        ]
        SentryBridge.addBreadcrumb(breadcrumb)

        return newURL
    }

    /// Match Plezy's working Live TV handshake: tune with a playback-session
    /// identifier, submit a universal-transcoder decision using the exact
    /// Metadata.key returned by tune, then play the resulting standard HLS.
    func resolveStreamURL(for channel: UnifiedChannel) async -> URL? {
        guard let base = buildStreamURL(for: channel) else { return nil }

        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              var queryItems = components.queryItems,
              let pathIndex = queryItems.firstIndex(where: { $0.name == "path" }),
              let epgPath = queryItems[pathIndex].value,
              epgPath.hasPrefix("/tv.plex.providers.epg") else {
            return base  // Direct URL or non-EPG path — playable as-is.
        }

        // epgPath = /tv.plex.providers.epg.cloud:157/metadata/<channelId>
        let parts = epgPath.split(separator: "/")
        guard parts.count >= 3,
              let dvrKey = parts[0].split(separator: ":").last.map(String.init) else {
            return base
        }
        let channelId = String(parts[2])

        do {
            let tune = try await networkManager.tuneLiveTVChannel(
                serverURL: serverURL,
                authToken: authToken,
                dvrKey: dvrKey,
                channelIdentifier: channelId
            )

            let breadcrumb = Breadcrumb(level: .info, category: "plex_livetv")
            breadcrumb.message = "Using Plezy-compatible Plex Live TV HLS"
            breadcrumb.data = [
                "channel_name": channel.name,
                "channel_id": channel.id,
                "dvr_key": dvrKey,
                "session_uuid": String(tune.sessionUUID.prefix(8)),
                "playback_route": "universal_hls_mpegts_direct_stream"
            ]
            SentryBridge.addBreadcrumb(breadcrumb)
            print(
                "📺 PlexLiveTVProvider: route=plezy-hls-direct-stream"
                + " channel='\(channel.name)' session=\(tune.sessionUUID.prefix(8))"
            )

            // PMS expects the exact Metadata.key returned by tune. Media.uuid
            // and Part.key are internal grab details and produced the 404s in
            // the previous implementation.
            queryItems[pathIndex] = URLQueryItem(name: "path", value: tune.sessionPath)
            if let sessionIndex = queryItems.firstIndex(where: {
                $0.name == "X-Plex-Session-Identifier"
            }) {
                queryItems[sessionIndex] = URLQueryItem(
                    name: "X-Plex-Session-Identifier",
                    value: tune.sessionIdentifier
                )
            }
            components.queryItems = queryItems
            components.percentEncodedQuery = components.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%2B")
            guard let streamURL = components.url else { return base }
            await networkManager.startTranscodeDecision(hlsURL: streamURL, headers: [:])
            return streamURL
        } catch {
            SentryBridge.capture(error: error) { scope in
                scope.setTag(value: "plex_livetv", key: "component")
                scope.setExtra(value: channel.name, key: "channel_name")
                scope.setExtra(value: dvrKey, key: "dvr_key")
                scope.setExtra(value: "tune_failed", key: "operation")
            }
            return nil
        }
    }

    // MARK: - Private Methods

    private func filterEPG(
        _ epg: [String: [UnifiedProgram]],
        channels: [UnifiedChannel],
        startDate: Date,
        endDate: Date
    ) -> [String: [UnifiedProgram]] {
        let channelIds = Set(channels.map { $0.id })

        var filtered: [String: [UnifiedProgram]] = [:]

        for (channelId, programs) in epg {
            guard channelIds.contains(channelId) else { continue }

            let filteredPrograms = programs.filter { program in
                program.endTime > startDate && program.startTime < endDate
            }

            if !filteredPrograms.isEmpty {
                filtered[channelId] = filteredPrograms
            }
        }

        return filtered
    }

    // MARK: - Cache Management

    func clearCache() {
        cachedChannels = []
        cachedEPG = [:]
        cachedEPGRange = nil
        lastChannelFetch = nil
        lastEPGFetch = nil
        capabilities = nil
    }

    // MARK: - Capability Check

    /// Check if Plex Live TV is available (call this before adding as a source)
    static func checkAvailability(serverURL: String, authToken: String) async -> Bool {
        do {
            let caps = try await PlexNetworkManager.shared.getLiveTVCapabilities(
                serverURL: serverURL,
                authToken: authToken
            )
            return caps.liveTVEnabled
        } catch {
            return false
        }
    }
}
