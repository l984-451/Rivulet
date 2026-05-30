//
//  PlexMetadata.swift
//  Rivulet
//
//  Ported from plex_watchOS - Metadata.swift
//  Extended for video content (movies, TV shows, episodes)
//  Original created by Bain Gurley on 4/29/24.
//

import Foundation

// MARK: - Cast & Crew Models

/// Actor/cast member with role information
struct PlexRole: Codable, Identifiable, Sendable {
    var id: String { "\(tag ?? "unknown")-\(role ?? "unknown")-\(thumb ?? "")" }
    var tag: String?        // Actor name
    var role: String?       // Character name
    var thumb: String?      // Photo URL
}

/// Director/Writer/Producer
struct PlexCrewMember: Codable, Identifiable, Sendable {
    var id: String { "\(tag ?? "unknown")-\(thumb ?? "")" }
    var tag: String?
    var thumb: String?
}

/// Plex image entry (clearLogo, coverPoster, background, snapshot, etc.)
/// Returned on metadata items as an `Image` array. The `url` field is a
/// server-relative path that still needs `X-Plex-Token` to fetch.
struct PlexImage: Codable, Hashable, Sendable {
    var alt: String?
    var type: String?   // e.g. "clearLogo", "coverPoster", "background", "snapshot"
    var url: String?
}

/// Generic tag model (genres, collections, etc.)
struct PlexTag: Codable, Identifiable, Hashable, Sendable {
    var id: String { idString ?? tag ?? UUID().uuidString }
    var _id: Int?          // Collection/genre ID from Plex API (decoded from "id")
    var tag: String?

    /// String version of the numeric ID for use with collection API
    var idString: String? {
        _id.map { String($0) }
    }

    enum CodingKeys: String, CodingKey {
        case _id = "id"
        case tag
    }
}

/// External ID reference (e.g. "tmdb://12345", "tvdb://67890", "imdb://tt1234567")
struct PlexGuid: Codable, Sendable {
    var id: String?
}

/// Trailer/Extra content
struct PlexExtra: Codable, Identifiable, Sendable {
    var id: String { ratingKey ?? UUID().uuidString }
    var ratingKey: String?
    var key: String?
    var type: String?
    var title: String?
    var subtype: String?    // "trailer", "behindTheScenes", etc.
    var thumb: String?
    var duration: Int?
    var extraType: Int?     // 1=trailer
    var Media: [PlexMedia]?

    /// User-added extras have a local file path under /Volumes/...; Plex's
    /// IVA-supplied extras stream from /services/iva/assets/... and carry
    /// no file field.
    var hasLocalFile: Bool {
        (Media?.first?.Part?.first?.file?.isEmpty == false)
    }
}

/// Container for extras in Plex API response
struct PlexExtrasContainer: Codable, Sendable {
    var Metadata: [PlexExtra]?
}

/// Container for OnDeck (next episode to watch) in Plex API response
/// Plex may return `Metadata` as either an array or a single dictionary.
struct PlexOnDeck: Codable, Sendable {
    var Metadata: [PlexMetadata]?

    enum CodingKeys: String, CodingKey {
        case Metadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Try array first, then fall back to single dict wrapped in an array
        if let array = try? container.decodeIfPresent([PlexMetadata].self, forKey: .Metadata) {
            Metadata = array
        } else if let single = try? container.decodeIfPresent(PlexMetadata.self, forKey: .Metadata) {
            Metadata = [single]
        } else {
            Metadata = nil
        }
    }
}

// MARK: - Marker Model

/// Plex media marker (intro, credits, commercial)
struct PlexMarker: Codable, Identifiable, Sendable {
    var id: Int?
    var type: String?              // "intro", "credits", "commercial"
    var startTimeOffset: Int?      // Start time in milliseconds
    var endTimeOffset: Int?        // End time in milliseconds

    /// Start time in seconds
    var startTimeSeconds: TimeInterval {
        guard let start = startTimeOffset else { return 0 }
        return TimeInterval(start) / 1000.0
    }

    /// End time in seconds
    var endTimeSeconds: TimeInterval {
        guard let end = endTimeOffset else { return 0 }
        return TimeInterval(end) / 1000.0
    }

    /// Whether this is an intro marker
    var isIntro: Bool {
        type == "intro"
    }

    /// Whether this is a credits/outro marker
    var isCredits: Bool {
        type == "credits"
    }

    /// Whether this is a commercial marker
    var isCommercial: Bool {
        type == "commercial"
    }
}

// MARK: - Main Metadata Model

/// Plex media item metadata (movie, show, season, episode)
struct PlexMetadata: Codable, Identifiable, Hashable, Sendable {
    var id: String {
        return ratingKey ?? UUID().uuidString
    }

    // MARK: - Core Identifiers
    var ratingKey: String?
    var key: String?
    var guid: String?
    var type: String?             // "movie", "show", "season", "episode", "clip"
    var subtype: String?          // clips only: "trailer", "behindTheScenes", etc.
    var extraType: Int?           // clips only: 1=trailer

    // MARK: - Display Info
    var title: String?
    var originalTitle: String?
    var studio: String?
    var contentRating: String?    // "PG-13", "TV-MA", etc.
    var summary: String?
    var tagline: String?
    var year: Int?

    // MARK: - Ratings
    var rating: Double?
    var audienceRating: Double?
    var ratingImage: String?
    var audienceRatingImage: String?

    // MARK: - Artwork
    var thumb: String?
    var art: String?
    var banner: String?
    var Image: [PlexImage]?  // clearLogo, coverPoster, background, etc.
    var Genre: [PlexTag]?
    var Guid: [PlexGuid]?  // External IDs (tmdb://, tvdb://, imdb://)
    var Collection: [PlexTag]?

    // MARK: - Timing
    var duration: Int?            // Milliseconds
    var originallyAvailableAt: String?
    var addedAt: Int?
    var updatedAt: Int?

    // MARK: - Library Context
    var librarySectionTitle: String?
    var librarySectionID: Int?
    var librarySectionKey: String?

    // MARK: - Parent Info (for episodes -> season)
    var parentRatingKey: String?
    var parentGuid: String?
    var parentKey: String?
    var parentTitle: String?
    var parentIndex: Int?         // Season number
    var parentThumb: String?

    // MARK: - Grandparent Info (for episodes -> show)
    var grandparentRatingKey: String?
    var grandparentGuid: String?
    var grandparentKey: String?
    var grandparentTitle: String?
    var grandparentThumb: String?
    var grandparentArt: String?
    var grandparentTheme: String?

    // MARK: - Episode/Season Specific
    var index: Int?               // Episode number in season
    var leafCount: Int?           // Total episodes (for shows/seasons)
    var viewedLeafCount: Int?     // Watched episodes
    var childCount: Int?          // Number of seasons (for shows)

    // MARK: - Watch Status
    var viewCount: Int?
    var viewOffset: Int?          // Resume position in milliseconds
    var lastViewedAt: Int?
    var skipCount: Int?

    // MARK: - User Rating
    var userRating: Double?
    var lastRatedAt: Int?

    // MARK: - Media Files
    var Media: [PlexMedia]?

    // MARK: - Cast & Crew
    var Role: [PlexRole]?
    var Director: [PlexCrewMember]?
    var Writer: [PlexCrewMember]?

    // MARK: - Extras (Trailers, etc.)
    var Extras: PlexExtrasContainer?

    // MARK: - Markers (Intro, Credits, etc.)
    var Marker: [PlexMarker]?

    // MARK: - Chapters
    var Chapter: [PlexChapter]?

    // MARK: - On Deck (Next Episode for Shows)
    var OnDeck: PlexOnDeck?

    // MARK: - Additional Metadata
    var hasPremiumPrimaryExtra: String?
    var primaryExtraKey: String?

    // MARK: - Hashable
    func hash(into hasher: inout Hasher) {
        hasher.combine(ratingKey)
    }

    static func == (lhs: PlexMetadata, rhs: PlexMetadata) -> Bool {
        lhs.ratingKey == rhs.ratingKey
    }

    // MARK: - Convenience Init for Previews/Testing

    init(
        ratingKey: String? = nil,
        key: String? = nil,
        guid: String? = nil,
        type: String? = nil,
        title: String? = nil,
        originalTitle: String? = nil,
        studio: String? = nil,
        contentRating: String? = nil,
        summary: String? = nil,
        tagline: String? = nil,
        year: Int? = nil,
        rating: Double? = nil,
        audienceRating: Double? = nil,
        ratingImage: String? = nil,
        audienceRatingImage: String? = nil,
        thumb: String? = nil,
        art: String? = nil,
        banner: String? = nil,
        Genre: [PlexTag]? = nil,
        Collection: [PlexTag]? = nil,
        duration: Int? = nil,
        originallyAvailableAt: String? = nil,
        addedAt: Int? = nil,
        updatedAt: Int? = nil,
        librarySectionTitle: String? = nil,
        librarySectionID: Int? = nil,
        librarySectionKey: String? = nil,
        parentRatingKey: String? = nil,
        parentGuid: String? = nil,
        parentKey: String? = nil,
        parentTitle: String? = nil,
        parentIndex: Int? = nil,
        parentThumb: String? = nil,
        grandparentRatingKey: String? = nil,
        grandparentGuid: String? = nil,
        grandparentKey: String? = nil,
        grandparentTitle: String? = nil,
        grandparentThumb: String? = nil,
        grandparentArt: String? = nil,
        grandparentTheme: String? = nil,
        index: Int? = nil,
        leafCount: Int? = nil,
        viewedLeafCount: Int? = nil,
        childCount: Int? = nil,
        viewCount: Int? = nil,
        viewOffset: Int? = nil,
        lastViewedAt: Int? = nil,
        skipCount: Int? = nil,
        userRating: Double? = nil,
        lastRatedAt: Int? = nil,
        Media: [PlexMedia]? = nil,
        Role: [PlexRole]? = nil,
        Director: [PlexCrewMember]? = nil,
        Writer: [PlexCrewMember]? = nil,
        Extras: PlexExtrasContainer? = nil,
        Marker: [PlexMarker]? = nil,
        OnDeck: PlexOnDeck? = nil,
        hasPremiumPrimaryExtra: String? = nil,
        primaryExtraKey: String? = nil
    ) {
        self.ratingKey = ratingKey
        self.key = key
        self.guid = guid
        self.type = type
        self.title = title
        self.originalTitle = originalTitle
        self.studio = studio
        self.contentRating = contentRating
        self.summary = summary
        self.tagline = tagline
        self.year = year
        self.rating = rating
        self.audienceRating = audienceRating
        self.ratingImage = ratingImage
        self.audienceRatingImage = audienceRatingImage
        self.thumb = thumb
        self.art = art
        self.banner = banner
        self.Genre = Genre
        self.Collection = Collection
        self.duration = duration
        self.originallyAvailableAt = originallyAvailableAt
        self.addedAt = addedAt
        self.updatedAt = updatedAt
        self.librarySectionTitle = librarySectionTitle
        self.librarySectionID = librarySectionID
        self.librarySectionKey = librarySectionKey
        self.parentRatingKey = parentRatingKey
        self.parentGuid = parentGuid
        self.parentKey = parentKey
        self.parentTitle = parentTitle
        self.parentIndex = parentIndex
        self.parentThumb = parentThumb
        self.grandparentRatingKey = grandparentRatingKey
        self.grandparentGuid = grandparentGuid
        self.grandparentKey = grandparentKey
        self.grandparentTitle = grandparentTitle
        self.grandparentThumb = grandparentThumb
        self.grandparentArt = grandparentArt
        self.grandparentTheme = grandparentTheme
        self.index = index
        self.leafCount = leafCount
        self.viewedLeafCount = viewedLeafCount
        self.childCount = childCount
        self.viewCount = viewCount
        self.viewOffset = viewOffset
        self.lastViewedAt = lastViewedAt
        self.skipCount = skipCount
        self.userRating = userRating
        self.lastRatedAt = lastRatedAt
        self.Media = Media
        self.Role = Role
        self.Director = Director
        self.Writer = Writer
        self.Extras = Extras
        self.Marker = Marker
        self.OnDeck = OnDeck
        self.hasPremiumPrimaryExtra = hasPremiumPrimaryExtra
        self.primaryExtraKey = primaryExtraKey
    }
}

// MARK: - Computed Properties

extension PlexMetadata {
    /// Best-effort extraction of TMDB ID from the guid or Guid array
    var tmdbId: Int? {
        // Try primary guid first
        if let guid, let id = PlexMetadata.extractTmdbId(from: guid) {
            return id
        }
        // Fall back to Guid array (legacy Plex agents store external IDs here)
        if let guids = Guid {
            for g in guids {
                if let gid = g.id, let id = PlexMetadata.extractTmdbId(from: gid) {
                    return id
                }
            }
        }
        return nil
    }

    /// TMDB ID for the parent show (extracts from grandparentGuid for episodes)
    var showTmdbId: Int? {
        guard let guid = grandparentGuid else { return nil }
        return PlexMetadata.extractTmdbId(from: guid)
    }

    /// TMDB ID for the related show when the item is a season or episode.
    var parentShowTmdbId: Int? {
        switch type {
        case "episode":
            return grandparentGuid.flatMap(PlexMetadata.extractTmdbId)
        case "season":
            return parentGuid.flatMap(PlexMetadata.extractTmdbId)
        default:
            return nil
        }
    }

    /// Relative path of the clearLogo image from the Plex `Image` array, if present.
    /// Returns a server-relative path that still needs the server URL + X-Plex-Token to fetch.
    var clearLogoPath: String? {
        Image?.first(where: { $0.type == "clearLogo" })?.url
    }

    /// Preferred show/series title for hero branding.
    var seriesTitleForDisplay: String? {
        switch type {
        case "episode":
            return grandparentTitle ?? title
        case "season":
            return parentTitle ?? grandparentTitle ?? title
        default:
            return title
        }
    }

    /// Season label for UI that needs to keep season context while borrowing show branding.
    var seasonDisplayTitle: String? {
        guard type == "season" else { return nil }

        if let title, !title.isEmpty {
            return title
        }

        guard let index else { return nil }
        return index == 0 ? "Specials" : "Season \(index)"
    }

    /// Extract a TMDB ID from a Plex guid string
    nonisolated static func extractTmdbId(from guid: String) -> Int? {
        extractExternalId(from: guid, prefixes: ["tmdb://", "themoviedb://"])
    }

    /// Extract a numeric ID from a guid string matching any of the given prefixes
    nonisolated static func extractExternalId(from guid: String, prefixes: [String]) -> Int? {
        let lower = guid.lowercased()
        for prefix in prefixes {
            if lower.contains(prefix) {
                let parts = lower.components(separatedBy: prefix)
                guard parts.count > 1 else { continue }
                let remainder = parts[1]
                if let idPart = remainder.split(whereSeparator: { $0 == "?" || $0 == "&" || $0 == "/" }).first,
                   let id = Int(idPart) {
                    return id
                }
            }
        }
        return nil
    }

    /// Normalized TMDB media type for the item
    var tmdbMediaType: TMDBMediaType {
        if type == "show" || type == "episode" {
            return .tv
        }
        return .movie
    }

    /// Lowercased genre tags from Plex metadata
    var genreTags: [String] {
        Genre?.compactMap { $0.tag?.lowercased() } ?? []
    }

    /// Lowercased cast names
    var castNames: [String] {
        Role?.compactMap { $0.tag?.lowercased() } ?? []
    }

    /// Lowercased directors
    var directorNames: [String] {
        Director?.compactMap { $0.tag?.lowercased() } ?? []
    }

    /// Duration formatted as "Xh Ym" or "Ym"
    var durationFormatted: String? {
        guard let durationMs = duration else { return nil }
        let totalMinutes = durationMs / 1000 / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Resume position formatted
    var viewOffsetFormatted: String? {
        guard let offset = viewOffset else { return nil }
        let totalMinutes = offset / 1000 / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Remaining time formatted (duration - viewOffset)
    var remainingTimeFormatted: String? {
        guard let offset = viewOffset, let total = duration, total > offset else { return nil }
        let remainingMs = total - offset
        let totalMinutes = remainingMs / 1000 / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else {
            return "\(minutes)m"
        }
    }

    /// Progress as percentage (0.0 - 1.0)
    var watchProgress: Double? {
        guard let offset = viewOffset, let total = duration, total > 0 else { return nil }
        return Double(offset) / Double(total)
    }

    /// Check if item has been partially watched (has active playback progress)
    var isInProgress: Bool {
        guard let progress = watchProgress else { return false }
        return progress > 0.02 && progress < 0.9
    }

    /// Format a viewOffset (ms) for the resume prompt: H:MM:SS when ≥ 1 hour,
    /// M:SS otherwise — matches stock Plex / Infuse "Resume from …" wording.
    static func formatResumeTime(_ viewOffsetMs: Int) -> String {
        let totalSeconds = max(0, viewOffsetMs) / 1000
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    /// Check if item should show as "watched" (completed, no active re-watch in progress)
    /// - Shows/Seasons: all episodes must be watched (viewedLeafCount >= leafCount)
    /// - Movies/Episodes: viewCount > 0 and not currently in progress
    var isWatched: Bool {
        // For shows and seasons, check if all episodes are watched
        if type == "show" || type == "season" {
            guard let total = leafCount, let watched = viewedLeafCount, total > 0 else {
                return false
            }
            return watched >= total
        }

        // For movies and episodes, use viewCount logic
        // If currently in progress (re-watching), don't show as watched
        if isInProgress {
            return false
        }
        // Show as watched if progress >= 90% or has been watched before
        if let progress = watchProgress, progress >= 0.9 {
            return true
        }
        return (viewCount ?? 0) > 0
    }

    /// Episode string (e.g., "S01E05")
    var episodeString: String? {
        guard type == "episode" else { return nil }
        let season = parentIndex ?? 0
        let episode = index ?? 0
        return String(format: "S%02dE%02d", season, episode)
    }

    /// Full episode title (e.g., "S01E05 - Episode Title")
    var fullEpisodeTitle: String? {
        guard let epString = episodeString, let title = title else { return nil }
        return "\(epString) - \(title)"
    }

    /// Best thumbnail URL (falls back through parent/grandparent)
    var bestThumb: String? {
        thumb ?? parentThumb ?? grandparentThumb
    }

    /// Best art URL (falls back through parent/grandparent)
    var bestArt: String? {
        art ?? grandparentArt
    }

    /// Media type for display
    var mediaTypeDisplay: String {
        switch type {
        case "movie": return "Movie"
        case "show": return "TV Show"
        case "season": return "Season"
        case "episode": return "Episode"
        default: return type?.capitalized ?? "Unknown"
        }
    }

    /// First media file's streaming key
    var streamKey: String? {
        Media?.first?.Part?.first?.key
    }

    /// Video resolution display (e.g., "4K", "1080p", "720p")
    var videoQualityDisplay: String? {
        guard let resolution = Media?.first?.videoResolution else { return nil }
        switch resolution.lowercased() {
        case "4k", "2160": return "4K"
        case "1080": return "1080p"
        case "720": return "720p"
        case "480", "sd": return "SD"
        default: return resolution.uppercased()
        }
    }

    /// HDR format display (e.g., "Dolby Vision", "HDR10", nil if SDR)
    var hdrFormatDisplay: String? {
        let videoStreams = Media?.first?.Part?.first?.Stream?.filter { $0.isVideo } ?? []
        if videoStreams.contains(where: { $0.isDolbyVision }) {
            return "Dolby Vision"
        } else if videoStreams.contains(where: { $0.isHDR }) {
            return "HDR"
        }
        return nil
    }

    /// Whether this content has Dolby Vision
    var hasDolbyVision: Bool {
        let videoStreams = Media?.first?.Part?.first?.Stream?.filter { $0.isVideo } ?? []
        return videoStreams.contains(where: { $0.isDolbyVision })
    }

    /// Whether this content has any HDR format (HDR10, HDR10+, HLG, or Dolby Vision)
    var hasHDR: Bool {
        if hasDolbyVision { return true }
        let videoStreams = Media?.first?.Part?.first?.Stream?.filter { $0.isVideo } ?? []
        return videoStreams.contains(where: { $0.isHDR })
    }

    /// Primary video stream (first video stream from first media/part)
    /// Used for display criteria configuration (HDR/frame rate matching)
    var primaryVideoStream: PlexStream? {
        Media?.first?.Part?.first?.Stream?.first(where: { $0.isVideo })
    }

    /// Audio format display (e.g., "Atmos", "5.1", "Stereo")
    var audioFormatDisplay: String? {
        guard let media = Media?.first else { return nil }
        let channels = media.audioChannels ?? 2
        let codec = media.audioCodec?.lowercased() ?? ""

        // Get primary audio stream for additional metadata (title, profile)
        let audioStream = media.Part?.first?.Stream?.first(where: { $0.isAudio && ($0.default == true || $0.selected == true) })
            ?? media.Part?.first?.Stream?.first(where: { $0.isAudio })

        let streamTitle = (audioStream?.title ?? "").lowercased()
        let streamDisplayTitle = (audioStream?.displayTitle ?? "").lowercased()
        let streamProfile = (audioStream?.profile ?? "").lowercased()

        // Check for explicit Atmos indicator in stream metadata
        let hasAtmosIndicator = streamTitle.contains("atmos") ||
                                streamDisplayTitle.contains("atmos") ||
                                streamProfile.contains("atmos")

        // Check for DTS:X indicators
        let hasDTSXIndicator = streamTitle.contains("dts:x") ||
                               streamTitle.contains("dts-x") ||
                               streamDisplayTitle.contains("dts:x") ||
                               streamDisplayTitle.contains("dts-x")

        // Check for 7.1 in title when Plex reports fewer channels (Atmos with 5.1 bed)
        let has71InTitle = streamTitle.contains("7.1") || streamDisplayTitle.contains("7.1")

        if hasAtmosIndicator {
            return "Atmos"
        }

        if hasDTSXIndicator {
            return "DTS:X"
        }

        // If title says 7.1 but Plex reports 6 channels, trust the title
        if has71InTitle && channels < 8 {
            if codec == "eac3" {
                return "DDP 7.1"
            } else if codec.contains("truehd") {
                return "TrueHD 7.1"
            } else if codec.contains("dts") {
                return "DTS 7.1"
            }
            return "7.1"
        }

        // Fall back to channel-based detection
        if channels >= 8 {
            if codec.contains("truehd") || codec.contains("atmos") {
                return "Atmos"
            } else if codec.contains("dts") {
                return "DTS:X"
            }
            return "7.1"
        } else if channels >= 6 {
            if codec.contains("truehd") {
                return "TrueHD 5.1"
            } else if codec.contains("dts") && codec.contains("hd") {
                return "DTS-HD 5.1"
            }
            return "5.1"
        } else if channels >= 2 {
            return "Stereo"
        } else {
            return "Mono"
        }
    }

    // MARK: - Cast & Crew Helpers

    /// All cast members
    var cast: [PlexRole] {
        Role ?? []
    }

    /// Primary director name
    var primaryDirector: String? {
        Director?.first?.tag
    }

    /// Primary writer name
    var primaryWriter: String? {
        Writer?.first?.tag
    }

    /// First trailer if available
    var trailer: PlexExtra? {
        Extras?.Metadata?.first { $0.extraType == 1 || $0.subtype == "trailer" }
    }

    /// All extras (trailers, behind the scenes, etc.)
    var allExtras: [PlexExtra] {
        Extras?.Metadata ?? []
    }

    // MARK: - Marker Helpers

    /// Intro marker if available
    var introMarker: PlexMarker? {
        Marker?.first { $0.isIntro }
    }

    /// Credits/outro markers if available (can have multiple, e.g., mid-credits and post-credits)
    var creditsMarkers: [PlexMarker] {
        Marker?.filter { $0.isCredits } ?? []
    }

    /// First credits marker (for post-video trigger timing)
    var firstCreditsMarker: PlexMarker? {
        creditsMarkers.first
    }

    /// Commercial markers if available
    var commercialMarkers: [PlexMarker] {
        Marker?.filter { $0.isCommercial } ?? []
    }

    /// All markers
    var allMarkers: [PlexMarker] {
        Marker ?? []
    }
}
