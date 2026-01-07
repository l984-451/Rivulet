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

    private let dispatcharrService: DispatcharrService?

    // Cached data
    private var cachedChannels: [UnifiedChannel] = []
    private var cachedEPG: [String: [UnifiedProgram]] = [:]
    private var lastChannelFetch: Date?
    private var lastEPGFetch: Date?

    // Cache duration
    private let channelCacheDuration: TimeInterval = 300  // 5 minutes
    private let epgCacheDuration: TimeInterval = 3600     // 1 hour

    // MARK: - Initialization

    /// Initialize for Dispatcharr source
    init(dispatcharrURL: URL, sourceId: String, displayName: String) {
        self.sourceType = .dispatcharr
        self.sourceId = sourceId
        self.displayName = displayName

        // Clean the URL in case it already contains /output/m3u or /output/epg
        // This handles URLs that were saved before the cleanup was added
        let cleanedURL = Self.cleanDispatcharrURL(dispatcharrURL)

        self.baseURL = cleanedURL
        self.dispatcharrService = DispatcharrService(baseURL: cleanedURL)
        self.m3uURL = cleanedURL.appendingPathComponent("output/m3u")
        self.epgURL = cleanedURL.appendingPathComponent("output/epg")
    }

    /// Clean a Dispatcharr URL by removing /output/m3u or /output/epg paths
    private static func cleanDispatcharrURL(_ url: URL) -> URL {
        var urlString = url.absoluteString

        // Strip /output/m3u or /output/epg paths if present
        if let range = urlString.range(of: "/output/m3u", options: .caseInsensitive) {
            urlString = String(urlString[..<range.lowerBound])
        } else if let range = urlString.range(of: "/output/epg", options: .caseInsensitive) {
            urlString = String(urlString[..<range.lowerBound])
        }

        return URL(string: urlString) ?? url
    }

    /// Initialize for generic M3U source
    init(m3uURL: URL, epgURL: URL?, sourceId: String, displayName: String) {
        self.sourceType = .genericM3U
        self.sourceId = sourceId
        self.displayName = displayName
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
            print("📺 IPTVProvider [\(displayName)]: Returning \(cachedChannels.count) cached channels")
            return cachedChannels
        }

        return try await refreshChannels()
    }

    func refreshChannels() async throws -> [UnifiedChannel] {
        guard let url = m3uURL else {
            throw LiveTVProviderError.sourceNotConfigured
        }

        print("📺 IPTVProvider [\(displayName)]: Fetching channels from \(url)")

        let parser = M3UParser()
        let parsedChannels: [M3UParser.ParsedChannel]

        do {
            if let dispatcharr = dispatcharrService {
                parsedChannels = try await dispatcharr.fetchChannels()
            } else {
                parsedChannels = try await parser.parse(from: url)
            }
        } catch {
            // Capture IPTV channel fetch failure to Sentry
            let capturedSourceType = self.sourceType
            let capturedDisplayName = self.displayName
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "iptv", key: "component")
                scope.setTag(value: String(describing: capturedSourceType), key: "source_type")
                scope.setExtra(value: capturedDisplayName, key: "source_name")
                scope.setExtra(value: url.absoluteString, key: "m3u_url")
            }
            throw error
        }

        print("📺 IPTVProvider [\(displayName)]: ✅ Parsed \(parsedChannels.count) channels")

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
            print("📺 IPTVProvider [\(displayName)]: Returning cached EPG")
            return filterEPG(cachedEPG, channels: channels, startDate: startDate, endDate: endDate)
        }

        print("📺 IPTVProvider [\(displayName)]: Fetching EPG from \(epgURL)")

        let xmltvParser = XMLTVParser()
        let parseResult: XMLTVParser.ParseResult

        do {
            if let dispatcharr = dispatcharrService {
                parseResult = try await dispatcharr.fetchParsedEPG()
            } else {
                parseResult = try await xmltvParser.parse(from: epgURL)
            }
        } catch {
            // Capture EPG fetch failure to Sentry
            let capturedDisplayName = self.displayName
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "iptv", key: "component")
                scope.setTag(value: "epg_fetch", key: "operation")
                scope.setExtra(value: capturedDisplayName, key: "source_name")
                scope.setExtra(value: epgURL.absoluteString, key: "epg_url")
            }
            throw error
        }

        print("📺 IPTVProvider [\(displayName)]: ✅ Parsed EPG with \(parseResult.programs.count) channel schedules")

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

        // Update cache
        cachedEPG = unifiedEPG
        lastEPGFetch = Date()

        return filterEPG(unifiedEPG, channels: channels, startDate: startDate, endDate: endDate)
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
}
