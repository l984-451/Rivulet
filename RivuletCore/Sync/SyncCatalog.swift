// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Which `UserDefaults` keys iCloud carries. An explicit list: a new key does not sync by accident.
nonisolated enum SyncCatalog {
    /// Device-local: this device's switch, and what the mirror last agreed with the cloud.
    static let enabledKey = "iCloudSyncEnabled"
    static let stateKey = "iCloudSyncState"
    static let accountStateKey = "iCloudAccountState"
    static let accountPrintKey = "iCloudAccountPrint"
    static let heldKey = "iCloudSyncHeld"

    static let exactKeys: Set<String> = [
        // Home and Library
        "showHomeHero", "homeHeroContent", "showLibraryHero", "showLibraryRecentRows",
        "showLibraryRecommendations", "enablePersonalizedRecommendations", "showDiscoverTab", "showWatchlistTab", "showFavoritesTab",
        // Playback
        "autoplayLimit", "autoplayCountdown", "showPostVideoUpNext", "promptResumeOrRestart",
        "continueWatchingInstantResume", "skipPreviewCarousel", "useIntroDB", "cinemaTrailersCount",
        "detailRatingSource", "generatedSubtitlesFallback", "playerShowsClockTimes",
        "showSkipIntro", "showSkipRecap", "showSkipCredits", "showSkipAds",
        "autoSkipIntro", "autoSkipRecap", "autoSkipCredits", "autoSkipAds",
        SkipLengthKeys.forward, SkipLengthKeys.back,
        // Content filter (not its list source URL, which can embed access)
        "contentFilter.enabled", "contentFilter.profanityStrength", "contentFilter.customWords",
        // Live TV (not recents, viewings or event slots: device habit)
        "liveTVLayout", "liveTVKeepPlayingInGuide", "combineLiveTVSources", "confirmExitMultiview",
        "liveTVSuggestions", "liveTVFavoriteChannelIds", "liveTVUnfavoritedChannelIds",
        "liveTVHiddenPlexServers", "liveTVHideJellyfin", "liveTVHideEmby",
        // Servers the user turned off, by machine id
        "plexDisabledServers",
    ]

    /// Keys stored once per Plex Home profile (`_user_<id>`) or non-Plex server (`_provider_<id>`).
    static let profileFamilies: [String] = [
        "hiddenHomeRowIdentifiers", "homeRowOrder", "homeCollectionPins", "homePlaylistPins", "heroPlaylistPins",
        "homeHeroSources", "showHomeFavoriteMovies", "showHomeFavoriteShows", "libraryCollectionPins",
        "hiddenLibraryKeys", "libraryOrder", "libraryOrderAllServers", "librarySortOptions", "libraryViewMode",
        "trackIntent.subtitle", "trackIntent.audio",
    ]

    /// The words `DiagnosticsReport.settingsSnapshot` redacts by.
    static let secretWords = ["token", "pin", "password", "secret", "url", "server", "address", "user", "email", "name"]

    /// Allowlisted names that hit a secret word and are reviewed to be harmless:
    /// collection and playlist pins, "skip intro" (skIPINtro), machine ids of servers the user switched off,
    /// and the library order across all servers.
    static let reviewedSecretWordKeys: Set<String> = [
        "homeCollectionPins", "homePlaylistPins", "heroPlaylistPins", "libraryCollectionPins", "showSkipIntro", "autoSkipIntro",
        "liveTVHiddenPlexServers", "plexDisabledServers", "libraryOrderAllServers",
    ]

    static func isSynced(_ key: String) -> Bool {
        if exactKeys.contains(key) { return true }
        if profileFamilies.contains(where: { key.hasPrefix($0 + "_user_") || key.hasPrefix($0 + "_provider_") })
            || profileFamilies.contains(key) { return true }
        if key.hasPrefix("mediaLibrarySort.") { return key.count > "mediaLibrarySort.".count }
        // contentFilter.<category>.enabled
        if key.hasPrefix("contentFilter."), key.hasSuffix(".enabled") {
            let middle = key.dropFirst("contentFilter.".count).dropLast(".enabled".count)
            return !middle.isEmpty && !middle.contains(".")
        }
        return false
    }

    /// Lists of Live TV channel ids. Ids that embed an address or a login stay on the device they were made on.
    static let channelListKeys: Set<String> = ["liveTVFavoriteChannelIds", "liveTVUnfavoritedChannelIds"]

    /// A channel id is "<type>:<source id>:<channel>". Plex and Dispatcharr source ids hold the server address
    /// (which differs per device), and an M3U id from before the re-key held the whole playlist URL, login included.
    /// Anything URL-shaped or carrying a login stays home.
    static func isSyncableChannelId(_ id: String) -> Bool {
        let lower = id.lowercased()
        return !lower.contains("://") && !lower.contains("@") && !lower.contains("password=")
            && !lower.contains("username=") && !lower.contains("?")
    }

    /// The local value as the cloud may see it.
    static func outgoing(_ key: String, _ value: Any) -> Any {
        guard channelListKeys.contains(key), let ids = value as? [String] else { return value }
        return ids.filter(isSyncableChannelId)
    }

    /// What this device keeps after taking the cloud's value: the cloud's ids, then the local ones that stay home.
    static func incoming(_ key: String, cloud: Any?, local: Any?) -> Any? {
        guard channelListKeys.contains(key) else { return cloud }
        let shared = (cloud as? [String] ?? []).filter(isSyncableChannelId)
        let home = (local as? [String] ?? []).filter { !isSyncableChannelId($0) }
        let merged = shared + home
        return merged.isEmpty && cloud == nil ? nil : merged
    }

    /// NSUbiquitousKeyValueStore raises on a key over 128 UTF-16 units.
    static func fitsKVS(key: String) -> Bool { key.utf16.count <= 128 }
}
