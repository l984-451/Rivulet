// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

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
    case xtream = "xtream"
    case jellyfin = "jellyfin"
    case emby = "emby"
    case tvheadend = "tvheadend"

    /// Follows a signed-in media server: added and removed with it, never saved.
    var followsServer: Bool {
        switch self {
        case .plex, .jellyfin, .emby: true
        case .dispatcharr, .genericM3U, .xtream, .tvheadend: false
        }
    }

    var displayName: String {
        switch self {
        case .plex: return "Plex Live TV"
        case .dispatcharr: return "Dispatcharr"
        case .genericM3U: return "M3U Playlist"
        case .xtream: return "Xtream Codes"
        case .jellyfin: return "Jellyfin Live TV"
        case .emby: return "Emby Live TV"
        case .tvheadend: return "Tvheadend"
        }
    }

    var iconName: String {
        switch self {
        case .plex: return "server.rack"
        case .dispatcharr: return "antenna.radiowaves.left.and.right"
        case .genericM3U: return "list.bullet"
        case .xtream: return "person.badge.key"
        case .jellyfin: return "server.rack"
        case .emby: return "server.rack"
        case .tvheadend: return "tv"
        }
    }
}

// MARK: - Channel Number

/// A channel number as the source writes it: "7", or an OTA sub-channel "10.1" (#430).
nonisolated struct ChannelNumber: Hashable, Comparable, Sendable, LosslessStringConvertible,
                                  ExpressibleByIntegerLiteral {
    let major: Int
    let minor: Int?

    static let max = ChannelNumber(major: .max)

    init(major: Int, minor: Int? = nil) {
        self.major = major
        self.minor = minor
    }

    init(integerLiteral value: Int) { self.init(major: value) }

    /// "10", "10.1" or "10-1".
    init?(_ text: String) {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .split(maxSplits: 1, omittingEmptySubsequences: false) { $0 == "." || $0 == "-" }
        guard let major = parts.first.flatMap({ Int($0) }) else { return nil }
        self.init(major: major, minor: parts.count > 1 ? Int(parts[1]) : nil)
    }

    var description: String { minor.map { "\(major).\($0)" } ?? "\(major)" }

    static func < (lhs: ChannelNumber, rhs: ChannelNumber) -> Bool {
        (lhs.major, lhs.minor ?? -1) < (rhs.major, rhs.minor ?? -1)
    }
}

// MARK: - Unified Channel

/// A unified channel representation that works across all Live TV sources
nonisolated struct UnifiedChannel: Identifiable, Hashable, Sendable {
    let id: String
    let sourceType: LiveTVSourceType
    let sourceId: String
    let channelNumber: ChannelNumber?
    let name: String
    let callSign: String?
    let logoURL: URL?
    let streamURL: URL?
    let tvgId: String?
    let groupTitle: String?
    let isHD: Bool
    let httpHeaders: [String: String]?

    /// Marked a favourite on the source (Plex "Favourite Channels").
    ///
    /// Separate from `groupTitle` rather than being another group name, for two
    /// reasons the group field cannot express: a favourite stays in its tuner's
    /// group as well, and the guide has to honour the ORDER the user arranged
    /// on the source, which is not channel-number order.
    let isFavourite: Bool

    /// Position within the source's favourites list. Lower sorts first; nil
    /// falls to the end, ordered by channel number as usual.
    let favouriteRank: Int?

    /// Position of `groupTitle` in its source's own category order.
    let groupRank: Int?

    init(
        id: String,
        sourceType: LiveTVSourceType,
        sourceId: String,
        channelNumber: ChannelNumber? = nil,
        name: String,
        callSign: String? = nil,
        logoURL: URL? = nil,
        streamURL: URL? = nil,
        tvgId: String? = nil,
        groupTitle: String? = nil,
        isHD: Bool = false,
        httpHeaders: [String: String]? = nil,
        isFavourite: Bool = false,
        favouriteRank: Int? = nil,
        groupRank: Int? = nil
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
        self.httpHeaders = httpHeaders
        self.isFavourite = isFavourite
        self.favouriteRank = favouriteRank
        self.groupRank = groupRank
    }

    /// Create a unique identifier combining source and channel
    nonisolated static func makeId(sourceType: LiveTVSourceType, sourceId: String, channelId: String) -> String {
        "\(sourceType.rawValue):\(sourceId):\(channelId)"
    }

    /// This channel with a different logo and every other field carried over.
    ///
    /// The one place a channel is rebuilt field by field. Hand-rolled copies
    /// compile cleanly when a defaulted field is added and then silently reset
    /// it: the XMLTV logo pass dropped playlist headers and the favourite rank
    /// exactly that way.
    func withLogo(_ logo: URL?) -> UnifiedChannel {
        UnifiedChannel(
            id: id,
            sourceType: sourceType,
            sourceId: sourceId,
            channelNumber: channelNumber,
            name: name,
            callSign: callSign,
            logoURL: logo,
            streamURL: streamURL,
            tvgId: tvgId,
            groupTitle: groupTitle,
            isHD: isHD,
            httpHeaders: httpHeaders,
            isFavourite: isFavourite,
            favouriteRank: favouriteRank,
            groupRank: groupRank
        )
    }

    func withGroupRank(_ rank: Int?) -> UnifiedChannel {
        UnifiedChannel(
            id: id, sourceType: sourceType, sourceId: sourceId, channelNumber: channelNumber,
            name: name, callSign: callSign, logoURL: logoURL, streamURL: streamURL, tvgId: tvgId,
            groupTitle: groupTitle, isHD: isHD, httpHeaders: httpHeaders,
            isFavourite: isFavourite, favouriteRank: favouriteRank, groupRank: rank
        )
    }
}

// MARK: - Unified Program (EPG)

/// A unified EPG program representation
nonisolated struct UnifiedProgram: Identifiable, Hashable, Sendable {
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
    /// The source's own identifier for what is airing (Plex `plex://episode/…`).
    /// DVR scheduling is keyed by it; nil for sources without one.
    let sourceGuid: String?
    let year: Int?
    let contentRating: String?
    let isMovie: Bool
    /// The source flagged this airing live (Plex's `live`).
    let isLive: Bool

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
        isNew: Bool = false,
        sourceGuid: String? = nil,
        year: Int? = nil,
        contentRating: String? = nil,
        isMovie: Bool = false,
        isLive: Bool = false
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
        self.sourceGuid = sourceGuid
        self.year = year
        self.contentRating = contentRating
        self.isMovie = isMovie
        self.isLive = isLive
    }

    /// `title` without the guide's live or upcoming marker. Display only:
    /// Dispatcharr series rules match the raw title.
    var displayTitle: String { Self.displayTitle(title) }

    /// A live airing, as opposed to a replay: the source flagged it, or the
    /// guide marked the title ("Live: SportsCenter").
    var isLiveAiring: Bool { isLive || title.prefixMatch(of: Self.liveMarker) != nil }

    /// A stand-in that fills a channel until its event starts at `endTime`
    /// ("UPCOMING: Jets @ Bears", EPG & Sports Editor's pregame block).
    var isPregameBlock: Bool { title.prefixMatch(of: Self.upcomingMarker) != nil }

    /// When the thing this programme is about starts: a pregame block's event
    /// starts as the block ends.
    var eventStart: Date { isPregameBlock ? endTime : startTime }

    /// An event slot with nothing in it ("No game scheduled" on an empty NFL
    /// slot), as opposed to a programme.
    var isEmptySlot: Bool { title.prefixMatch(of: Self.emptySlot) != nil }

    // Anchored with ^, so prefixMatch tries once instead of at every position.
    private static let liveMarker = /^\s*(?:\[live\]|\(live\)|live\s*[:|]|live\s+[-–]\s)\s*/.ignoresCase()
    private static let upcomingMarker = /^\s*upcoming\s*[:|]\s*/.ignoresCase()
    private static let emptySlot = /^\s*(?:no (?:game|event|match)e?s?(?: scheduled)?|off[- ]?air)\s*$/.ignoresCase()

    /// "Live: X", "LIVE | X", "Live - X", "[LIVE] X", "UPCOMING: X" → "X". Show
    /// names that start with the word ("Live PD", "LiveNOW from FOX") are left alone.
    static func displayTitle(_ title: String) -> String {
        let stripped = title
            .replacing(liveMarker, with: "", maxReplacements: 1)
            .replacing(upcomingMarker, with: "", maxReplacements: 1)
        return stripped.isEmpty ? title : stripped
    }

    /// The guide's second line: the episode title, else the episode number (#434).
    var guideDetail: String? {
        [subtitle, episodeNumber].lazy.compactMap { $0 }.first { !$0.isEmpty && $0 != title }
    }

    /// The guide's qualifier tag (#429).
    var guideTag: String? { isLiveAiring ? "LIVE" : isNew ? "NEW" : nil }

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

    /// Resolves a playable stream URL, doing any server-side setup first (the Plex
    /// tune for cloud-EPG and DVB DVRs). Defaults to `buildStreamURL(for:)`.
    /// Throws when setup fails so the player can say why.
    func resolveStreamURL(for channel: UnifiedChannel) async throws -> URL?

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
    case tunersBusy

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return String(localized: "Source is not connected")
        case .authenticationRequired:
            return String(localized: "Authentication required")
        case .sourceNotConfigured:
            return String(localized: "Source is not configured")
        case .networkError(let error):
            return String(localized: "Network error: \(error.localizedDescription)")
        case .parseError(let message):
            return String(localized: "Parse error: \(message)")
        case .noChannelsFound:
            return String(localized: "No channels found")
        case .channelNotFound(let id):
            return String(localized: "Channel not found: \(id)")
        case .epgNotAvailable:
            return String(localized: "EPG data is not available")
        case .tunersBusy:
            return String(localized: "Couldn't tune this channel. All tuners may be busy.")
        }
    }
}

// MARK: - Parser Conversions

// These live here rather than beside the parsers because they build the unified
// model declared in this file, not because of any platform split: everything
// involved is shared. Keeping them out of the parsers is what let those files
// drop their `#if os(tvOS)` (see CLAUDE.md, Platform Boundary).

extension M3UParser.ParsedChannel {
    /// What a channel's id is built from. Playlists repeat it (SD and HD feeds share a tvg-id).
    nonisolated var channelKey: String { key ?? tvgId ?? tvgName ?? name }

    /// Convert to UnifiedChannel. `occurrence` counts earlier entries with the same
    /// `channelKey` in the source; the 2nd and later get "#n" so ids stay unique and
    /// the first keeps the id saved favorites point at.
    nonisolated func toUnifiedChannel(sourceType: LiveTVSourceType, sourceId: String, occurrence: Int = 0) -> UnifiedChannel {
        let channelId = occurrence == 0 ? channelKey : "\(channelKey)#\(occurrence)"
        let id = UnifiedChannel.makeId(sourceType: sourceType, sourceId: sourceId, channelId: channelId)

        return UnifiedChannel(
            id: id,
            sourceType: sourceType,
            sourceId: sourceId,
            channelNumber: channelNumber,
            name: tvgName ?? name,
            callSign: nil,
            logoURL: tvgLogo.flatMap { URL(string: $0) },
            streamURL: streamURL,
            tvgId: tvgId,
            groupTitle: groupTitle,
            isHD: isHD,
            httpHeaders: httpHeaders.isEmpty ? nil : httpHeaders,
            groupRank: groupRank
        )
    }
}

extension XMLTVParser.ParsedProgram {
    /// Convert to UnifiedProgram
    func toUnifiedProgram(unifiedChannelId: String) -> UnifiedProgram {
        // Create unique ID from channel and start time
        let id = "\(unifiedChannelId):\(Int(start.timeIntervalSince1970))"

        return UnifiedProgram(
            id: id,
            channelId: unifiedChannelId,
            title: title,
            subtitle: subtitle,
            description: description,
            startTime: start,
            endTime: stop,
            category: category,
            iconURL: icon.flatMap { URL(string: $0) },
            posterURL: posterIcon.flatMap { URL(string: $0) },
            landscapeURL: landscapeIcon.flatMap { URL(string: $0) },
            episodeNumber: episodeNum,
            isNew: isNew,
            year: year
        )
    }
}
