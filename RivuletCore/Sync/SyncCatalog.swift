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

    /// Whether this build carries the iCloud entitlement. A free Apple ID cannot sign it, and CloudKit
    /// stops the app as soon as a container is made without it. Read from the provisioning profile
    /// Xcode embeds; App Store and TestFlight builds carry none and always have the entitlement.
    static let cloudAvailable: Bool = cloudAvailable(
        profile: Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision")
            .flatMap { try? Data(contentsOf: $0) })

    /// No profile, or one that cannot be read, counts as available; a readable profile must list
    /// the iCloud services.
    static func cloudAvailable(profile: Data?) -> Bool {
        guard let profile,
              let start = profile.range(of: Data("<?xml".utf8)),
              let end = profile.range(of: Data("</plist>".utf8), in: start.lowerBound..<profile.endIndex),
              let plist = try? PropertyListSerialization.propertyList(
                  from: profile.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any] else { return true }
        return entitlements["com.apple.developer.icloud-services"] != nil
    }

    static let exactKeys: Set<String> = [
        // Home and Library
        "showHomeHero", "homeHeroContent", "showLibraryHero", "showLibraryRecentRows",
        "showLibraryRecommendations", "enablePersonalizedRecommendations", "showDiscoverTab", "showWatchlistTab", "showFavoritesTab", "showWatchTogetherTab",
        // Playback
        "autoplayLimit", "autoplayCountdown", "atTheCredits", "promptResumeOrRestart",
        "continueWatchingInstantResume", "skipPreviewCarousel", "showPosterTitles", "useIntroDB", "cinemaTrailersCount",
        "detailRatingSource", "generatedSubtitlesFallback", "playerShowsClockTimes",
        "showSkipIntro", "showSkipRecap", "showSkipAds",
        "autoSkipIntro", "autoSkipRecap", "autoSkipAds",
        SkipLengthKeys.forward, SkipLengthKeys.back,
        // Content filter (not its list source URL, which can embed access)
        "contentFilter.enabled", "contentFilter.profanityStrength", "contentFilter.customWords",
        // Live TV (not recents, viewings or event slots: device habit)
        "liveTVLayout", "combineLiveTVSources", "liveTVFavoriteChannelIds", "liveTVUnfavoritedChannelIds",
        "liveTVHiddenPlexServers", "liveTVHideJellyfin", "liveTVHideEmby",
        // The viewer's own and smart channel lists, and pinned categories
        channelListsKey, "liveTVPinnedCategories",
        // Servers the user turned off, by machine id
        "plexDisabledServers",
        // Photos
        "photoSlideInterval", "photoSlideTransition", "photoSlidePlaysClips",
        // Music
        "musicLoudnessLeveling",
    ]

    /// Keys stored once per Plex Home profile (`_user_<id>`) or non-Plex server (`_provider_<id>`).
    static let profileFamilies: [String] = [
        "hiddenHomeRowIdentifiers", "homeRowOrder", "homeCollectionPins", "homePlaylistPins", "heroPlaylistPins",
        "homeHeroSources", "showHomeFavoriteMovies", "showHomeFavoriteShows", "showHomeFavoriteChannels", "libraryCollectionPins",
        "hiddenLibraryKeys", "hiddenSidebarLibraries", "libraryOrder", "libraryOrderAllServers", "librarySortOptions", "libraryViewMode", "libraryUnwatchedOnly",
        "trackIntent.subtitle", "trackIntent.audio",
    ]

    /// The words `DiagnosticsReport.settingsSnapshot` redacts by.
    static let secretWords = ["token", "pin", "password", "secret", "url", "server", "address", "user", "email", "name"]

    /// Allowlisted names that hit a secret word and are reviewed to be harmless:
    /// collection and playlist pins, "skip intro" (skIPINtro), machine ids of servers the user switched off,
    /// and the library order across all servers.
    static let reviewedSecretWordKeys: Set<String> = [
        "homeCollectionPins", "homePlaylistPins", "heroPlaylistPins", "libraryCollectionPins", "showSkipIntro", "autoSkipIntro",
        "liveTVHiddenPlexServers", "plexDisabledServers", "libraryOrderAllServers", "liveTVPinnedCategories",
    ]

    static func isSynced(_ key: String) -> Bool {
        if exactKeys.contains(key) { return true }
        if profileFamilies.contains(where: { key.hasPrefix($0 + "_user_") || key.hasPrefix($0 + "_provider_") })
            || profileFamilies.contains(key) { return true }
        for prefix in ["mediaLibrarySort.", "photoLibraryQuery."] where key.hasPrefix(prefix) { return key.count > prefix.count }
        // contentFilter.<category>.enabled
        if key.hasPrefix("contentFilter."), key.hasSuffix(".enabled") {
            let middle = key.dropFirst("contentFilter.".count).dropLast(".enabled".count)
            return !middle.isEmpty && !middle.contains(".")
        }
        return false
    }

    /// Lists of Live TV channel ids. Ids that embed an address or a login stay on the device they were made on.
    /// Pins are "<source id>|<category>", so they follow the same rule.
    static let channelListKeys: Set<String> = ["liveTVFavoriteChannelIds", "liveTVUnfavoritedChannelIds",
                                               "liveTVPinnedCategories"]

    /// `LiveChannelListStore.listsKey`: JSON lists whose channel ids and smart-list source ids
    /// follow the channel-id rule, list by list.
    static let channelListsKey = "liveTVChannelLists"

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
        if key == channelListsKey { return lists(value).map { encode($0.map { shared($0) }) } ?? value }
        guard channelListKeys.contains(key), let ids = value as? [String] else { return value }
        return ids.filter(isSyncableChannelId)
    }

    /// What this device keeps after taking the cloud's value: the cloud's ids, then the local ones that stay home.
    static func incoming(_ key: String, cloud: Any?, local: Any?) -> Any? {
        if key == channelListsKey { return incomingLists(cloud: cloud, local: local) }
        guard channelListKeys.contains(key) else { return cloud }
        let shared = (cloud as? [String] ?? []).filter(isSyncableChannelId)
        let home = (local as? [String] ?? []).filter { !isSyncableChannelId($0) }
        let merged = shared + home
        return merged.isEmpty && cloud == nil ? nil : merged
    }

    // MARK: Channel lists

    /// The cloud's lists; a list this device also has keeps the ids that stay home, after the shared ones.
    private static func incomingLists(cloud: Any?, local: Any?) -> Any? {
        guard let cloudLists = lists(cloud as Any) else { return cloud }
        let localById = Dictionary((lists(local as Any) ?? []).compactMap { list in
            (list["id"] as? String).map { ($0, list) }
        }, uniquingKeysWith: { first, _ in first })
        let merged = cloudLists.map { list -> [String: Any] in
            var list = shared(list)
            guard let id = list["id"] as? String, let mine = localById[id] else { return list }
            let home = (mine["channelIds"] as? [String] ?? []).filter { !isSyncableChannelId($0) }
            list["channelIds"] = (list["channelIds"] as? [String] ?? []) + home
            if var rules = list["rules"] as? [String: Any], let myRules = mine["rules"] as? [String: Any] {
                let homeSources = (myRules["sourceIds"] as? [String] ?? []).filter { !isSyncableChannelId($0) }
                rules["sourceIds"] = (rules["sourceIds"] as? [String] ?? []) + homeSources
                list["rules"] = rules
            }
            return list
        }
        return encode(merged)
    }

    /// A list without the ids that stay home.
    private static func shared(_ list: [String: Any]) -> [String: Any] {
        var list = list
        if let ids = list["channelIds"] as? [String] { list["channelIds"] = ids.filter(isSyncableChannelId) }
        if var rules = list["rules"] as? [String: Any], let sources = rules["sourceIds"] as? [String] {
            rules["sourceIds"] = sources.filter(isSyncableChannelId)
            list["rules"] = rules
        }
        return list
    }

    private static func lists(_ value: Any) -> [[String: Any]]? {
        guard let data = value as? Data else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]]
    }

    /// Sorted keys: the same lists always make the same bytes, so the mirror sees no false change.
    private static func encode(_ lists: [[String: Any]]) -> Any {
        (try? JSONSerialization.data(withJSONObject: lists, options: [.sortedKeys])) ?? Data()
    }

    /// NSUbiquitousKeyValueStore raises on a key over 128 UTF-16 units.
    static func fitsKVS(key: String) -> Bool { key.utf16.count <= 128 }
}
