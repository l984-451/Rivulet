//
//  LiveTVProvider.swift
//  Rivulet
//
//  Core protocol and unified types for Live TV sources (Plex, Dispatcharr, M3U)
//

import Foundation

// MARK: - Source Type

/// Types of Live TV sources supported
enum LiveTVSourceType: String, Codable, CaseIterable, Sendable {
    case plex = "plex"
    case dispatcharr = "dispatcharr"
    case genericM3U = "m3u"

    var displayName: String {
        switch self {
        case .plex: return "Plex Live TV"
        case .dispatcharr: return "Dispatcharr"
        case .genericM3U: return "M3U Playlist"
        }
    }

    var iconName: String {
        switch self {
        case .plex: return "server.rack"
        case .dispatcharr: return "antenna.radiowaves.left.and.right"
        case .genericM3U: return "list.bullet"
        }
    }
}

// MARK: - Unified Channel

/// A unified channel representation that works across all Live TV sources
struct UnifiedChannel: Identifiable, Hashable, Sendable {
    let id: String
    let sourceType: LiveTVSourceType
    let sourceId: String
    let channelNumber: Int?
    let name: String
    let callSign: String?
    let logoURL: URL?
    let streamURL: URL?
    let tvgId: String?
    let groupTitle: String?
    let isHD: Bool

    init(
        id: String,
        sourceType: LiveTVSourceType,
        sourceId: String,
        channelNumber: Int? = nil,
        name: String,
        callSign: String? = nil,
        logoURL: URL? = nil,
        streamURL: URL? = nil,
        tvgId: String? = nil,
        groupTitle: String? = nil,
        isHD: Bool = false
    ) {
        self.id = id
        self.sourceType = sourceType
        self.sourceId = sourceId
        self.channelNumber = channelNumber
        self.name = name
        self.callSign = callSign
        self.logoURL = logoURL
        self.streamURL = streamURL
        self.tvgId = tvgId
        self.groupTitle = groupTitle
        self.isHD = isHD
    }

    /// Create a unique identifier combining source and channel
    nonisolated static func makeId(sourceType: LiveTVSourceType, sourceId: String, channelId: String) -> String {
        "\(sourceType.rawValue):\(sourceId):\(channelId)"
    }
}

// MARK: - Unified Program (EPG)

/// A unified EPG program representation
struct UnifiedProgram: Identifiable, Hashable, Sendable {
    let id: String
    let channelId: String
    let title: String
    let subtitle: String?
    let description: String?
    let startTime: Date
    let endTime: Date
    let category: String?
    let iconURL: URL?
    /// Preferred 2:3 (portrait) artwork for the guide poster, if the EPG offers one.
    let posterURL: URL?
    /// Preferred 16:9 (landscape) artwork for the guide background, if offered.
    let landscapeURL: URL?
    let episodeNumber: String?
    let isNew: Bool

    init(
        id: String,
        channelId: String,
        title: String,
        subtitle: String? = nil,
        description: String? = nil,
        startTime: Date,
        endTime: Date,
        category: String? = nil,
        iconURL: URL? = nil,
        posterURL: URL? = nil,
        landscapeURL: URL? = nil,
        episodeNumber: String? = nil,
        isNew: Bool = false
    ) {
        self.id = id
        self.channelId = channelId
        self.title = title
        self.subtitle = subtitle
        self.description = description
        self.startTime = startTime
        self.endTime = endTime
        self.category = category
        self.iconURL = iconURL
        self.posterURL = posterURL
        self.landscapeURL = landscapeURL
        self.episodeNumber = episodeNumber
        self.isNew = isNew
    }

    /// Check if this program is currently airing
    var isCurrentlyAiring: Bool {
        let now = Date()
        return startTime <= now && endTime > now
    }

    /// Duration in minutes
    var durationMinutes: Int {
        Int(endTime.timeIntervalSince(startTime) / 60)
    }

    /// Current progress (0.0 to 1.0) if currently airing
    var currentProgress: Double? {
        guard isCurrentlyAiring else { return nil }
        let now = Date()
        let elapsed = now.timeIntervalSince(startTime)
        let total = endTime.timeIntervalSince(startTime)
        guard total > 0 else { return nil }
        return min(1.0, max(0.0, elapsed / total))
    }

    /// Formatted time range (e.g., "8:00 PM - 9:00 PM")
    var timeRangeFormatted: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: startTime)) - \(formatter.string(from: endTime))"
    }
}

// MARK: - Live TV Provider Protocol

/// Protocol that all Live TV sources must implement
protocol LiveTVProvider: Sendable {
    /// The type of this source
    var sourceType: LiveTVSourceType { get }

    /// Unique identifier for this source instance
    var sourceId: String { get }

    /// Display name for the UI
    var displayName: String { get }

    /// Whether the source is currently connected/available
    var isConnected: Bool { get async }

    /// Fetch all channels from this source
    func fetchChannels() async throws -> [UnifiedChannel]

    /// Refresh channels (force reload from network)
    func refreshChannels() async throws -> [UnifiedChannel]

    /// Fetch EPG data for the specified channels and time range
    func fetchEPG(
        for channels: [UnifiedChannel],
        startDate: Date,
        endDate: Date
    ) async throws -> [String: [UnifiedProgram]]  // channelId -> programs

    /// Get the current program for a channel
    func getCurrentProgram(for channel: UnifiedChannel) async -> UnifiedProgram?

    /// Build the stream URL for a channel (may add auth tokens, etc.)
    func buildStreamURL(for channel: UnifiedChannel) -> URL?

    /// Resolve a PLAYABLE stream URL, performing any server-side session setup
    /// first (e.g. the Plex Live TV tune step for cloud-EPG/DVB DVRs). Defaults
    /// to `buildStreamURL(for:)` for providers with directly playable URLs.
    func resolveStreamURL(for channel: UnifiedChannel) async -> URL?

    /// Channel logos discovered in the EPG/XMLTV data, keyed by unified channel
    /// id. Used to fill in channel artwork when the playlist (M3U) didn't supply
    /// a `tvg-logo`. Defaults to empty for sources without XMLTV channel icons.
    func channelLogosFromEPG() async -> [String: URL]
}

extension LiveTVProvider {
    /// Default: no XMLTV channel logos available.
    func channelLogosFromEPG() async -> [String: URL] { [:] }

    /// Default: the built URL is directly playable.
    func resolveStreamURL(for channel: UnifiedChannel) async -> URL? {
        buildStreamURL(for: channel)
    }
}

// MARK: - Provider Errors

enum LiveTVProviderError: LocalizedError {
    case notConnected
    case authenticationRequired
    case sourceNotConfigured
    case networkError(Error)
    case parseError(String)
    case noChannelsFound
    case channelNotFound(String)
    case epgNotAvailable

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Source is not connected"
        case .authenticationRequired:
            return "Authentication required"
        case .sourceNotConfigured:
            return "Source is not configured"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .parseError(let message):
            return "Parse error: \(message)"
        case .noChannelsFound:
            return "No channels found"
        case .channelNotFound(let id):
            return "Channel not found: \(id)"
        case .epgNotAvailable:
            return "EPG data is not available"
        }
    }
}
