// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  IPTVProvider.swift
//  Rivulet
//
//  LiveTVProvider implementation for IPTV sources (Dispatcharr and generic M3U)
//

import Foundation
import Sentry

/// LiveTVProvider implementation for IPTV sources
actor IPTVProvider: LiveTVProvider {

    // MARK: - Properties

    let sourceType: LiveTVSourceType
    let sourceId: String
    let displayName: String

    /// Base URL for Dispatcharr sources (nil for generic M3U)
    nonisolated let baseURL: URL?

    /// M3U playlist URL
    nonisolated let m3uURL: URL?

    /// EPG/XMLTV URL (optional)
    nonisolated let epgURL: URL?

    /// API token for Dispatcharr authentication (nil if not required)
    nonisolated let apiToken: String?

    /// Dispatcharr channel profile scoping this source, or nil for all channels.
    /// The token does not imply a profile: Dispatcharr only filters the playlist
    /// when the profile appears as a path segment. See `DispatcharrService`.
    nonisolated let channelProfile: String?

    let dispatcharrService: DispatcharrService?

    // Cached data
    private(set) var cachedChannels: [UnifiedChannel] = []
    private var cachedEPG: [String: [UnifiedProgram]] = [:]

    /// Channel logos parsed from XMLTV `<channel><icon>`, keyed by unified
    /// channel id. Surfaced via `channelLogosFromEPG()` so the data store can
    /// fill in artwork the M3U playlist didn't provide.
    private var cachedChannelLogos: [String: URL] = [:]
    private var lastChannelFetch: Date?
    private var lastEPGFetch: Date?

    // Cache duration
    private let channelCacheDuration: TimeInterval = 300  // 5 minutes
    private let epgCacheDuration: TimeInterval = 3600     // 1 hour

    // Dispatcharr DVR lookups (IPTVProvider+DVR.swift). The API knows
    // channels by integer id and guide entries by the EPG source's tvg_id,
    // neither of which the playlist carries.
    var dvrChannelIndex: DispatcharrChannelIndex?
    var dvrEPGData: [Int: DispatcharrEPGData] = [:]

    // MARK: - Initialization

    /// Initialize for Dispatcharr source
    init(dispatcharrURL: URL, sourceId: String, displayName: String, apiToken: String? = nil,
         channelProfile: String? = nil) {
        self.sourceType = .dispatcharr
        self.sourceId = sourceId
        self.displayName = displayName
        self.apiToken = apiToken

        // Split off /output/m3u or /output/epg in case the stored URL still
        // carries one. This handles URLs saved before the cleanup was added, and
        // it now also recovers a channel profile that a user pasted as part of
        // the endpoint rather than typing into the profile field.
        let split = DispatcharrService.splitEndpointPath(from: dispatcharrURL.absoluteString)
        let cleanedURL = URL(string: split.baseURL) ?? dispatcharrURL

        // An explicitly configured profile wins over one recovered from the URL,
        // so editing the field is always the last word.
        let profile = DispatcharrService.normalizedProfile(channelProfile) ?? split.channelProfile

        self.baseURL = cleanedURL
        self.channelProfile = profile
        self.dispatcharrService = DispatcharrService(baseURL: cleanedURL, apiToken: apiToken,
                                                     channelProfile: profile)
        self.m3uURL = DispatcharrService.outputURL(base: cleanedURL, kind: "m3u",
                                                   channelProfile: profile)
        self.epgURL = DispatcharrService.outputURL(base: cleanedURL, kind: "epg",
                                                   channelProfile: profile)
    }

    /// Initialize for generic M3U source
    init(m3uURL: URL, epgURL: URL?, sourceId: String, displayName: String) {
        self.sourceType = .genericM3U
        self.sourceId = sourceId
        self.displayName = displayName
        self.apiToken = nil
        self.channelProfile = nil
        self.baseURL = nil
        self.dispatcharrService = nil
        self.m3uURL = m3uURL
        self.epgURL = epgURL
    }

    // MARK: - LiveTVProvider Protocol

    var isConnected: Bool {
        get async {
            // Check if we can reach the M3U URL
            guard let url = m3uURL else { return false }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                let (_, response) = try await URLSession.shared.data(for: request)
                if let httpResponse = response as? HTTPURLResponse {
                    return (200...299).contains(httpResponse.statusCode)
                }
                return false
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
            return cachedChannels
        }

        return try await refreshChannels()
    }

    func refreshChannels() async throws -> [UnifiedChannel] {
        guard let url = m3uURL else {
            throw LiveTVProviderError.sourceNotConfigured
        }

        let parser = M3UParser()
        let parsedChannels: [M3UParser.ParsedChannel]

        do {
            if let dispatcharr = dispatcharrService {
                parsedChannels = try await dispatcharr.fetchChannels()
            } else {
                parsedChannels = try await parser.parse(from: url)
            }
        } catch {
            // Only capture unexpected errors to Sentry — skip HTTP errors (404, etc.)
            // which indicate user-configured M3U URLs that are no longer valid
            let isHTTPError = error is M3UParseError && "\(error)".contains("httpError")
            let isCancelled = (error as NSError).code == NSURLErrorCancelled
            if !isHTTPError && !isCancelled {
                let capturedSourceType = self.sourceType
                let capturedDisplayName = self.displayName
                SentryBridge.capture(error: error) { scope in
                    scope.setTag(value: "iptv", key: "component")
                    scope.setTag(value: String(describing: capturedSourceType), key: "source_type")
                    scope.setExtra(value: capturedDisplayName, key: "source_name")
                    // Xtream/IPTV M3U URLs routinely carry username+password in
                    // the query string.
                    scope.setExtra(value: SensitiveDataRedactor.safeURLString(url), key: "m3u_url")
                }
            }
            throw error
        }

        // Convert to UnifiedChannel
        let channels = parsedChannels.map { parsed in
            parsed.toUnifiedChannel(sourceType: sourceType, sourceId: sourceId)
        }

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
        guard let epgURL = epgURL else {
            throw LiveTVProviderError.epgNotAvailable
        }

        // Return cached if still valid
        if let lastFetch = lastEPGFetch,
           Date().timeIntervalSince(lastFetch) < epgCacheDuration,
           !cachedEPG.isEmpty {
            return filterEPG(cachedEPG, channels: channels, startDate: startDate, endDate: endDate)
        }

        let xmltvParser = XMLTVParser()
        let parseResult: XMLTVParser.ParseResult

        do {
            if let dispatcharr = dispatcharrService {
                parseResult = try await dispatcharr.fetchParsedEPG()
            } else {
                parseResult = try await xmltvParser.parse(from: epgURL)
            }
        } catch {
            // Only capture unexpected EPG errors. The EPG URL is user-supplied
            // third-party content, so upstream HTTP failures, DNS/timeout/TLS
            // errors, and task cancellations are not Rivulet bugs — log them
            // locally and surface via the UI, but don't file Sentry events.
            if shouldCaptureEPGError(error) {
                let capturedDisplayName = self.displayName
                SentryBridge.capture(error: error) { scope in
                    scope.setTag(value: "iptv", key: "component")
                    scope.setTag(value: "epg_fetch", key: "operation")
                    scope.setExtra(value: capturedDisplayName, key: "source_name")
                    scope.setExtra(value: SensitiveDataRedactor.safeURLString(epgURL), key: "epg_url")
                }
            }
            throw error
        }

        // Build unified channel ID -> tvgId mapping
        // Use uniquingKeysWith to handle duplicate tvgIds (keep first occurrence)
        let tvgIdToUnifiedId = Dictionary(
            channels.compactMap { channel in
                channel.tvgId.map { ($0, channel.id) }
            },
            uniquingKeysWith: { first, _ in first }
        )

        // Convert to UnifiedProgram, mapping by tvgId
        var unifiedEPG: [String: [UnifiedProgram]] = [:]

        for (xmltvChannelId, programs) in parseResult.programs {
            // Find the unified channel ID for this XMLTV channel
            guard let unifiedChannelId = tvgIdToUnifiedId[xmltvChannelId] else {
                continue  // No matching channel
            }

            let unifiedPrograms = programs.map { parsed in
                parsed.toUnifiedProgram(unifiedChannelId: unifiedChannelId)
            }

            unifiedEPG[unifiedChannelId] = unifiedPrograms
        }

        // Capture channel logos from the XMLTV `<channel><icon>` elements,
        // mapped onto our unified channel ids. These let the guide show channel
        // artwork even when the M3U playlist had no `tvg-logo`.
        var channelLogos: [String: URL] = [:]
        for (xmltvChannelId, parsedChannel) in parseResult.channels {
            guard let unifiedChannelId = tvgIdToUnifiedId[xmltvChannelId],
                  let iconString = parsedChannel.iconURL,
                  let iconURL = URL(string: iconString) else { continue }
            channelLogos[unifiedChannelId] = iconURL
        }

        // Update cache
        cachedEPG = unifiedEPG
        cachedChannelLogos = channelLogos
        lastEPGFetch = Date()

        return filterEPG(unifiedEPG, channels: channels, startDate: startDate, endDate: endDate)
    }

    /// Channel logos discovered in the XMLTV data (keyed by unified channel id).
    func channelLogosFromEPG() async -> [String: URL] { cachedChannelLogos }

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
        // For IPTV, the stream URL is already in the channel
        return channel.streamURL
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
        lastChannelFetch = nil
        lastEPGFetch = nil
    }

    // MARK: - Error Classification

    /// Returns `true` only when an EPG fetch error looks like a Rivulet bug
    /// rather than a third-party / configuration failure. User-supplied EPG
    /// URLs can return any HTTP status, time out, or fail DNS without it
    /// being our fault, so those get surfaced via the UI but not filed to
    /// Sentry. Parse failures on otherwise-valid responses still get captured.
    private func shouldCaptureEPGError(_ error: Error) -> Bool {
        // Upstream HTTP failure (4xx/5xx from the EPG server)
        if error is XMLTVParseError {
            if case XMLTVParseError.httpError = error {
                return false
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled,
                 NSURLErrorTimedOut,
                 NSURLErrorCannotFindHost,
                 NSURLErrorCannotConnectToHost,
                 NSURLErrorNetworkConnectionLost,
                 NSURLErrorDNSLookupFailed,
                 NSURLErrorNotConnectedToInternet,
                 NSURLErrorBadServerResponse,
                 NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid,
                 NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired:
                return false
            default:
                break
            }
        }

        return true
    }
}
