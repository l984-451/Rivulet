// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTVDataStore.swift
//  Rivulet
//
//  Central state management for Live TV channels and EPG across all sources
//

import Foundation
import Combine
import UIKit

@MainActor
class LiveTVDataStore: ObservableObject {
    static let shared = LiveTVDataStore()

    // MARK: - Published State

    /// All channels from all sources, merged and sorted
    @Published var channels: [UnifiedChannel] = []

    /// Current EPG data (channelId -> programs)
    @Published var epg: [String: [UnifiedProgram]] = [:]

    /// End of the currently loaded EPG window. The guide extends past this as
    /// the user scrolls toward the right edge (see `extendEPG`). nil until the
    /// first `loadEPG` completes.
    @Published private(set) var epgLoadedThrough: Date?

    /// True while an incremental `extendEPG` fetch is in flight; the guide's
    /// scroll-edge trigger checks this so it never stacks concurrent extensions.
    @Published private(set) var isExtendingEPG = false

    /// Safety ceiling for lazy extension: never fetch EPG more than this far
    /// past "now". Most providers cap their grid well inside this anyway; the
    /// bound just stops an endless right-scroll from firing pointless fetches.
    private let epgMaxHoursAhead = 72

    /// Channels played lately, newest first: What's On's Recently Watched row.
    @Published private(set) var recentChannelIds: [String] = []

    /// What For You learns from, oldest first. See `LiveSuggestions`.
    private(set) var viewings: [LiveViewing] = []

    /// The Live TV setting that turns For You and its learning on and off.
    static let suggestionsKey = "liveTVSuggestions"
    var suggestionsEnabled: Bool { userDefaults.object(forKey: Self.suggestionsKey) as? Bool ?? true }

    /// Channels favorited in Rivulet, from any source, in the viewer's order.
    @Published private(set) var favoriteIds: [String] = [] {
        didSet {
            saveFavorites()
        }
    }

    /// Loading states
    @Published var isLoadingChannels = false
    @Published var isLoadingEPG = false

    /// Error states
    @Published var channelsError: String?
    /// Per-source EPG failures. Populated after a `loadEPG` run that had at
    /// least one provider throw. Used by the Live TV guide to surface a
    /// user-readable "EPG unavailable" banner so users can tell that an empty
    /// guide is caused by a third-party / configuration problem rather than
    /// by Rivulet itself.
    @Published var epgIssues: [EPGFetchIssue] = []

    /// Active provider configurations
    @Published private(set) var sources: [LiveTVSourceInfo] = []

    // MARK: - Private Properties

    private var providers: [String: any LiveTVProvider] = [:]
    private var channelLoadTask: Task<Void, Never>?
    private var epgLoadTask: Task<Void, Never>?
    private var backgroundPreloadTask: Task<Void, Never>?

    // MARK: - Freshness tracking

    /// When the channel list and the EPG grid were last successfully loaded.
    /// nil until the first successful load. These drive `refreshIfStale`, the
    /// single entry point every surface uses to decide whether the guide it is
    /// about to show is still trustworthy.
    private(set) var lastChannelsLoad: Date?
    private(set) var lastEPGLoad: Date?

    /// How old the guide may get before a visit re-fetches it. `nonisolated`
    /// because it is a default argument below, and default arguments are
    /// evaluated in the caller's context, so reaching a @MainActor constant
    /// from there is an error under the Swift 6 language mode.
    nonisolated static let defaultMaxAge: TimeInterval = 30 * 60

    /// EPG window a staleness refresh fetches. Matches the guide's own
    /// initial window (EPGTheme.initialGuideHours); the guide extends from
    /// there as the user scrolls right.
    static let refreshWindowHours = 6

    /// Guards `refreshIfStale` so several surfaces appearing at once (the tab
    /// switching in while a foreground notification lands) run ONE refresh.
    private var staleRefreshTask: Task<Void, Never>?

    private let userDefaults = UserDefaults.standard
    private let favoritesKey = "liveTVFavoriteChannelIds"
    private let recentsKey = "liveTVRecentChannelIds"
    private let viewingsKey = "liveTVViewings"
    private let sourcesKey = "liveTVSourceConfigurations"

    // MARK: - Source Configuration (Persistable)

    struct SourceConfiguration: Codable {
        let id: String
        let type: String  // "dispatcharr", "m3u", "plex"
        let name: String
        let baseURL: String?
        let m3uURL: String?
        let epgURL: String?
        var apiToken: String?

        /// Dispatcharr channel profile, nil for every channel. Optional so that
        /// source configurations written before this field existed still decode:
        /// a missing key leaves it nil, which is the previous all-channels
        /// behavior.
        var channelProfile: String?

        init(id: String, type: String, name: String, baseURL: String?, m3uURL: String?,
             epgURL: String?, apiToken: String?, channelProfile: String? = nil) {
            self.id = id
            self.type = type
            self.name = name
            self.baseURL = baseURL
            self.m3uURL = m3uURL
            self.epgURL = epgURL
            self.apiToken = apiToken
            self.channelProfile = channelProfile
        }
    }

    // MARK: - Source Info

    struct LiveTVSourceInfo: Identifiable, Sendable {
        let id: String
        let sourceType: LiveTVSourceType
        let displayName: String
        let channelCount: Int
        let isConnected: Bool
        let lastSync: Date?

        /// Dispatcharr channel profile scoping this source, nil for all channels.
        /// Shown read-only on the source detail page so a user can tell at a
        /// glance why they are seeing a subset of their channels.
        var channelProfile: String?
    }

    // MARK: - EPG Errors

    /// A user-facing description of a single failed EPG fetch. Produced from
    /// the thrown error in `loadEPG` so the Live TV guide view can distinguish
    /// "third-party EPG server is down" from "Rivulet is broken".
    struct EPGFetchIssue: Identifiable, Equatable, Sendable {
        let id = UUID()
        let sourceId: String
        let sourceName: String
        let reason: String
    }

    // MARK: - Computed Properties

    /// Check if any Live TV source is configured
    var hasConfiguredSources: Bool {
        !providers.isEmpty
    }

    // MARK: - Initialization

    private init() {
        loadFavorites()
        recentChannelIds = userDefaults.stringArray(forKey: recentsKey) ?? []
        viewings = userDefaults.data(forKey: viewingsKey)
            .flatMap { try? JSONDecoder().decode([LiveViewing].self, from: $0) } ?? []
        loadSavedSources()
        observeAppLifecycle()
    }

    // MARK: - Freshness / refresh

    /// True when the guide on screen can no longer be trusted, for either of
    /// two independent reasons:
    ///
    /// 1. AGE — the grid was fetched more than `maxAge` ago, so "now playing"
    ///    has almost certainly moved on.
    /// 2. COVERAGE — the loaded EPG window no longer reaches the current time.
    ///    This is the case behind "I came back and the guide wasn't loaded":
    ///    the window is anchored at the load time, so after a long sleep every
    ///    programme in it is in the past and the grid renders empty even though
    ///    `epg` is non-empty. Age alone would miss a short window (the tab
    ///    loads only 6 hours), so both are checked.
    ///
    /// A never-loaded (or emptied) store is always stale.
    func isStale(maxAge: TimeInterval = defaultMaxAge, now: Date = Date()) -> Bool {
        if channels.isEmpty || epg.isEmpty { return true }
        guard let lastEPGLoad, let lastChannelsLoad else { return true }
        if now.timeIntervalSince(lastEPGLoad) > maxAge { return true }
        if now.timeIntervalSince(lastChannelsLoad) > maxAge { return true }
        if let through = epgLoadedThrough, through <= now { return true }
        return false
    }

    /// Re-fetch channels + EPG when `isStale`, otherwise do nothing. This is
    /// the entry point for every "user arrived at a Live TV surface" and
    /// "app came back to the foreground" moment; it is cheap to call often.
    ///
    /// Concurrent callers share one refresh: the tab's `.task` and the
    /// foreground notification routinely fire together, and two overlapping
    /// EPG fetches would cancel each other through `epgLoadTask` and leave
    /// the grid empty — the very failure this is meant to fix.
    func refreshIfStale(maxAge: TimeInterval = defaultMaxAge) async {
        guard !providers.isEmpty else { return }
        if let staleRefreshTask {
            await staleRefreshTask.value
            return
        }
        guard isStale(maxAge: maxAge) else { return }

        let task = Task { [weak self] in
            guard let self else { return }
            // Channels first: the EPG fetch is keyed by the channel list, so
            // a source whose line-up changed needs the new list in hand.
            await self.loadChannels()
            guard !self.channels.isEmpty else { return }
            await self.loadEPG(startDate: Date(), hours: Self.refreshWindowHours)
        }
        staleRefreshTask = task
        await task.value
        staleRefreshTask = nil
    }

    /// Refresh the guide when the app returns to the foreground. tvOS suspends
    /// for long stretches, so this is the most common way the grid goes stale.
    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.refreshIfStale()
            }
        }
    }

    // MARK: - Source Management

    /// Add a Dispatcharr source
    func addDispatcharrSource(baseURL: URL, name: String, apiToken: String? = nil,
                              channelProfile: String? = nil) async {
        let sourceId = "dispatcharr:\(baseURL.absoluteString)"
        let provider = IPTVProvider(
            dispatcharrURL: baseURL,
            sourceId: sourceId,
            displayName: name,
            apiToken: apiToken,
            channelProfile: channelProfile
        )
        providers[sourceId] = provider
        saveSources()
        await updateSourceInfo()
    }

    /// Add a generic M3U source
    func addM3USource(m3uURL: URL, epgURL: URL?, name: String) async {
        let sourceId = "m3u:\(m3uURL.absoluteString)"
        let provider = IPTVProvider(
            m3uURL: m3uURL,
            epgURL: epgURL,
            sourceId: sourceId,
            displayName: name
        )
        providers[sourceId] = provider
        saveSources()
        await updateSourceInfo()
    }

    #if DEBUG
    /// DEBUG launch hooks: a source for this run only, never saved.
    func debugAddTransientSource(_ provider: any LiveTVProvider) {
        providers[provider.sourceId] = provider
    }
    #endif

    /// Add a Plex Live TV source
    func addPlexSource(provider: any LiveTVProvider) async {
        providers[provider.sourceId] = provider
        saveSources()
        await updateSourceInfo()
    }

    /// Remove a source by ID
    func removeSource(id: String) async {
        providers.removeValue(forKey: id)
        KeychainHelper.delete(Self.apiTokenKey(sourceId: id))
        saveSources()
        await updateSourceInfo()

        // Collected before the channels go, or there is nothing left to purge.
        let removed = Set(channels.lazy.filter { $0.sourceId == id }.map(\.id))
        channels.removeAll { $0.sourceId == id }
        for channelId in removed {
            epg.removeValue(forKey: channelId)
        }
    }

    // MARK: - Source Persistence

    /// Load saved source configurations and recreate providers
    private func loadSavedSources() {
        guard let data = userDefaults.data(forKey: sourcesKey),
              var configs = try? JSONDecoder().decode([SourceConfiguration].self, from: data) else {
            print("📺 LiveTVDataStore: No saved sources found")
            return
        }
        if Self.moveAPITokensToKeychain(&configs), let data = try? JSONEncoder().encode(configs) {
            userDefaults.set(data, forKey: sourcesKey)
        }

        for config in configs {
            switch config.type {
            case "dispatcharr":
                if let urlString = config.baseURL, let url = URL(string: urlString) {
                    let provider = IPTVProvider(
                        dispatcharrURL: url,
                        sourceId: config.id,
                        displayName: config.name,
                        apiToken: KeychainHelper.get(Self.apiTokenKey(sourceId: config.id)) ?? config.apiToken,
                        channelProfile: config.channelProfile
                    )
                    providers[config.id] = provider
                }

            case "m3u":
                if let m3uString = config.m3uURL, let m3uURL = URL(string: m3uString) {
                    let epgURL = config.epgURL.flatMap { URL(string: $0) }
                    let provider = IPTVProvider(
                        m3uURL: m3uURL,
                        epgURL: epgURL,
                        sourceId: config.id,
                        displayName: config.name
                    )
                    providers[config.id] = provider
                }

            case "plex":
                // Restore Plex source using PlexAuthManager's saved credentials
                if let serverURL = config.baseURL {
                    let authManager = PlexAuthManager.shared
                    if let authToken = authManager.selectedServerToken {
                        let serverName = authManager.savedServerName ?? "Plex"
                        let provider = PlexLiveTVProvider(
                            serverURL: serverURL,
                            authToken: authToken,
                            serverName: serverName
                        )
                        providers[config.id] = provider
                    } else {
                    }
                }

            default:
                break
            }
        }

        // Update source info (async but we don't wait)
        Task {
            await updateSourceInfo()
        }
    }

    /// Save current source configurations to UserDefaults
    private func saveSources() {
        var configs: [SourceConfiguration] = []

        for (id, provider) in providers {
            switch provider.sourceType {
            case .dispatcharr:
                if let iptvProvider = provider as? IPTVProvider {
                    configs.append(SourceConfiguration(
                        id: id,
                        type: "dispatcharr",
                        name: provider.displayName,
                        baseURL: iptvProvider.baseURL?.absoluteString,
                        m3uURL: nil,
                        epgURL: nil,
                        apiToken: Self.storeAPIToken(iptvProvider.apiToken, sourceId: id),
                        channelProfile: iptvProvider.channelProfile
                    ))
                }

            case .genericM3U:
                if let iptvProvider = provider as? IPTVProvider {
                    configs.append(SourceConfiguration(
                        id: id,
                        type: "m3u",
                        name: provider.displayName,
                        baseURL: nil,
                        m3uURL: iptvProvider.m3uURL?.absoluteString,
                        epgURL: iptvProvider.epgURL?.absoluteString,
                        apiToken: nil
                    ))
                }

            case .plex:
                if let plexProvider = provider as? PlexLiveTVProvider {
                    configs.append(SourceConfiguration(
                        id: id,
                        type: "plex",
                        name: provider.displayName,
                        baseURL: plexProvider.serverURL,
                        m3uURL: nil,
                        epgURL: nil,
                        apiToken: nil
                    ))
                }
            }
        }

        if let data = try? JSONEncoder().encode(configs) {
            userDefaults.set(data, forKey: sourcesKey)
        }
    }

    /// Keychain account holding a source's Dispatcharr API key.
    static func apiTokenKey(sourceId: String) -> String { "liveTVSourceToken_\(sourceId)" }

    /// Puts `token` in the Keychain. Returns what the saved config must still
    /// hold: nil, unless the Keychain refused it and the key would be lost.
    private static func storeAPIToken(_ token: String?, sourceId: String) -> String? {
        let key = apiTokenKey(sourceId: sourceId)
        guard let token, !token.isEmpty else {
            KeychainHelper.delete(key)
            return nil
        }
        return KeychainHelper.set(token, forKey: key) ? nil : token
    }

    /// Moves API keys saved in plain text by older builds into the Keychain.
    /// True when `configs` changed and must be written back.
    static func moveAPITokensToKeychain(_ configs: inout [SourceConfiguration]) -> Bool {
        var changed = false
        for index in configs.indices where configs[index].apiToken != nil {
            configs[index].apiToken = storeAPIToken(configs[index].apiToken, sourceId: configs[index].id)
            changed = changed || configs[index].apiToken == nil
        }
        return changed
    }

    // MARK: - Legacy iOS source

    /// The single source the old iOS Live TV store kept in its own keys.
    enum LegacyIOSSource: Equatable {
        case dispatcharr(baseURL: URL, channelProfile: String?, apiToken: String?)
        case m3u(m3uURL: URL, epgURL: URL?)
    }

    private static let legacyIOSKeys = ["m3uURL", "xmltvURL", "authorizationHeader", "userAgent", "referer"]
        .map { "ios.liveTV.\($0)" }

    /// What the old iOS store left in `defaults`. A Dispatcharr playlist URL
    /// becomes a Dispatcharr source; its fetch headers have nowhere to go.
    static func legacyIOSSource(in defaults: UserDefaults) -> LegacyIOSSource? {
        func value(_ key: String) -> String? {
            defaults.string(forKey: "ios.liveTV.\(key)")?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let m3uString = value("m3uURL"), let m3uURL = URL(string: m3uString), m3uURL.host != nil else {
            return nil
        }
        if m3uURL.path.range(of: "/output/m3u", options: .caseInsensitive) != nil {
            let split = DispatcharrService.splitEndpointPath(from: m3uString)
            guard let base = URL(string: split.baseURL) else { return nil }
            return .dispatcharr(baseURL: base, channelProfile: split.channelProfile,
                                apiToken: apiKey(fromAuthorization: value("authorizationHeader")))
        }
        let epg = value("xmltvURL").flatMap { $0.isEmpty ? nil : URL(string: $0) }
        return .m3u(m3uURL: m3uURL, epgURL: epg)
    }

    /// The key in an Authorization value, without its "ApiKey", "Bearer" or "Token" scheme.
    static func apiKey(fromAuthorization header: String?) -> String? {
        guard var value = header, !value.isEmpty else { return nil }
        for scheme in ["ApiKey ", "Bearer ", "Token "] where value.lowercased().hasPrefix(scheme.lowercased()) {
            value = value.dropFirst(scheme.count).trimmingCharacters(in: .whitespaces)
            break
        }
        return value.isEmpty ? nil : value
    }

    /// Adds the source the old iOS store kept, then deletes its keys, so this
    /// runs once. The iOS app calls it at launch.
    func migrateLegacyIOSSource(defaults: UserDefaults = .standard) async {
        let source = Self.legacyIOSSource(in: defaults)
        Self.legacyIOSKeys.forEach(defaults.removeObject(forKey:))
        switch source {
        case .dispatcharr(let baseURL, let profile, let token):
            await addDispatcharrSource(baseURL: baseURL, name: "Live TV", apiToken: token, channelProfile: profile)
        case .m3u(let m3uURL, let epgURL):
            await addM3USource(m3uURL: m3uURL, epgURL: epgURL, name: "IPTV")
        case nil:
            break
        }
    }

    /// Update source info for UI
    private func updateSourceInfo() async {
        var infos: [LiveTVSourceInfo] = []

        // One pass instead of a filter per provider: on a large lineup the
        // per-provider filter is O(providers × channels) on the main actor,
        // a second main-thread sweep right behind the channel load.
        var channelCounts: [String: Int] = [:]
        for channel in channels {
            channelCounts[channel.sourceId, default: 0] += 1
        }

        for (id, provider) in providers {
            let isConnected = await provider.isConnected

            infos.append(LiveTVSourceInfo(
                id: id,
                sourceType: provider.sourceType,
                displayName: provider.displayName,
                channelCount: channelCounts[id] ?? 0,
                isConnected: isConnected,
                lastSync: nil,  // TODO: Track last sync time
                channelProfile: (provider as? IPTVProvider)?.channelProfile
            ))
        }

        sources = infos.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Channel Loading

    /// Fetch every provider in parallel and merge the results into one sorted
    /// lineup.
    ///
    /// `nonisolated` so both callers below can run it off the main actor. On a
    /// large M3U this is 100k+ channels, and the sort falls through to Unicode
    /// string collation because most playlists omit `tvg-chno` — enough work to
    /// stall the focus engine if it lands on the main thread.
    private nonisolated static func fetchAndMergeChannels(
        from providerEntries: [(key: String, value: any LiveTVProvider)],
        refreshing: Bool
    ) async -> (channels: [UnifiedChannel], errors: [String]) {
        var allChannels: [UnifiedChannel] = []
        var errors: [String] = []

        await withTaskGroup(of: (String, Result<[UnifiedChannel], Error>).self) { group in
            for (id, provider) in providerEntries {
                group.addTask {
                    do {
                        let channels = refreshing
                            ? try await provider.refreshChannels()
                            : try await provider.fetchChannels()
                        return (id, .success(channels))
                    } catch {
                        return (id, .failure(error))
                    }
                }
            }

            for await (sourceId, result) in group {
                switch result {
                case .success(let channels):
                    allChannels.append(contentsOf: channels)
                case .failure(let error):
                    errors.append("\(sourceId): \(error.localizedDescription)")
                    print("📺 LiveTVDataStore: ❌ Failed to load from \(sourceId): \(error)")
                }
            }
        }

        // Sort channels by number, then name
        allChannels.sort { c1, c2 in
            if let n1 = c1.channelNumber, let n2 = c2.channelNumber {
                return n1 < n2
            } else if c1.channelNumber != nil {
                return true
            } else if c2.channelNumber != nil {
                return false
            } else {
                return c1.name < c2.name
            }
        }

        return (allChannels, errors)
    }

    /// Load channels from all sources
    func loadChannels() async {
        guard !providers.isEmpty else {
            return
        }

        // Cancel existing task if any
        channelLoadTask?.cancel()

        isLoadingChannels = true
        channelsError = nil

        // Snapshot providers up-front so the task body never touches the
        // @MainActor-bound dictionary.
        let providerEntries = Array(providers)

        // Detached, not `Task {}`: a Task created inside a @MainActor method
        // inherits MainActor isolation, which would put the merge and sort back
        // on the main thread while the home screen is still loading. Priority
        // does not change isolation, so `Task(priority:)` is not a substitute.
        // The MainActor.run below is the only main hop.
        channelLoadTask = Task.detached { [providerEntries] in
            let merged = await Self.fetchAndMergeChannels(from: providerEntries, refreshing: false)

            // A cancelled (superseded) task must NOT publish: its partial
            // results would clobber whatever the newer loadChannels wrote, and
            // that newer task owns isLoadingChannels from here on.
            guard !Task.isCancelled else { return }

            await MainActor.run {
                self.channels = merged.channels
                self.isLoadingChannels = false
                if !merged.errors.isEmpty {
                    self.channelsError = merged.errors.joined(separator: "\n")
                }
                // Only a run that actually produced channels counts as fresh;
                // an all-providers-failed run must stay stale so the next
                // visit retries rather than sitting on an empty list for 30
                // minutes.
                if !merged.channels.isEmpty { self.lastChannelsLoad = Date() }
            }

            await self.updateSourceInfo()
        }

        await channelLoadTask?.value
    }

    /// Refresh channels from all sources
    func refreshChannels() async {
        guard !providers.isEmpty else { return }

        isLoadingChannels = true
        channelsError = nil

        // Detached for the same reason as loadChannels — this one is reached
        // from a Settings action, so the freeze would be squarely on a tap.
        let providerEntries = Array(providers)
        let merged = await Task.detached { [providerEntries] in
            await Self.fetchAndMergeChannels(from: providerEntries, refreshing: true)
        }.value

        channels = merged.channels
        isLoadingChannels = false
        if !merged.errors.isEmpty {
            channelsError = merged.errors.joined(separator: "\n")
        }

        await updateSourceInfo()
    }

    // MARK: - EPG Loading

    /// Load EPG for the specified time range
    func loadEPG(startDate: Date = Date(), hours: Int = 24) async {
        guard !providers.isEmpty, !channels.isEmpty else {
            return
        }

        epgLoadTask?.cancel()

        isLoadingEPG = true
        epgIssues = []

        let endDate = Calendar.current.date(byAdding: .hour, value: hours, to: startDate) ?? startDate

        // Snapshot provider display names up-front so the task group doesn't
        // need to touch the @MainActor-bound providers dictionary after
        // suspension.
        let sourceNames: [String: String] = providers.reduce(into: [:]) { acc, entry in
            acc[entry.key] = entry.value.displayName
        }

        // Snapshot providers so we can gather XMLTV channel logos after the EPG
        // fetch without touching the @MainActor providers dictionary post-suspension.
        let providerList = Array(providers.values)
        let providersById = providers

        // Grouping has to read `channels`, so it stays here on the main actor;
        // the merge of every source's programs below does not, and is the part
        // that scales with the lineup.
        let channelsBySource = Dictionary(grouping: channels, by: { $0.sourceId })

        // Detached for the same reason as loadChannels: `Task {}` would inherit
        // MainActor and put the EPG merge on the main thread.
        epgLoadTask = Task.detached { [channelsBySource, providersById, providerList, sourceNames] in
            var allEPG: [String: [UnifiedProgram]] = [:]
            var issues: [EPGFetchIssue] = []

            // Fetch EPG from each provider
            await withTaskGroup(of: (String, Result<[String: [UnifiedProgram]], Error>).self) { group in
                for (sourceId, sourceChannels) in channelsBySource {
                    guard let provider = providersById[sourceId] else {
                        print("📺 LiveTVDataStore: ⚠️ No provider found for sourceId: \(sourceId)")
                        continue
                    }

                    group.addTask {
                        do {
                            let epg = try await provider.fetchEPG(
                                for: sourceChannels,
                                startDate: startDate,
                                endDate: endDate
                            )
                            return (sourceId, .success(epg))
                        } catch {
                            return (sourceId, .failure(error))
                        }
                    }
                }

                for await (sourceId, result) in group {
                    switch result {
                    case .success(let epg):
                        for (channelId, programs) in epg {
                            allEPG[channelId] = programs
                        }
                    case .failure(let error):
                        // A superseding loadEPG cancels this task, which
                        // surfaces as NSURLError -999 / CancellationError in
                        // the fetch. That's not a source failure — don't show
                        // it in the guide banner.
                        if error is CancellationError || (error as NSError).code == NSURLErrorCancelled {
                            continue
                        }
                        print("📺 LiveTVDataStore: ⚠️ EPG load failed for \(sourceId): \(error)")
                        let sourceName = sourceNames[sourceId] ?? sourceId
                        issues.append(EPGFetchIssue(
                            sourceId: sourceId,
                            sourceName: sourceName,
                            reason: Self.shortEPGFailureReason(for: error)
                        ))
                    }
                }
            }

            // Gather channel logos discovered in the XMLTV data so the guide can
            // show channel artwork even when the M3U had no `tvg-logo`.
            var xmltvLogos: [String: URL] = [:]
            for provider in providerList {
                let logos = await provider.channelLogosFromEPG()
                xmltvLogos.merge(logos) { existing, _ in existing }
            }

            // A cancelled (superseded) task must NOT publish: its empty/partial
            // results would clobber whatever the newer loadEPG task wrote.
            guard !Task.isCancelled else { return }

            let finalEPG = allEPG
            let finalIssues = issues
            let finalLogos = xmltvLogos
            await MainActor.run {
                self.epg = finalEPG
                self.isLoadingEPG = false
                self.epgIssues = finalIssues
                self.epgLoadedThrough = endDate
                self.applyXMLTVChannelLogos(finalLogos)
                // See the note in loadChannels: an empty grid is not "fresh".
                if !finalEPG.isEmpty { self.lastEPGLoad = Date() }
            }
        }

        await epgLoadTask?.value
    }

    /// Extend the loaded EPG window forward by `hours`, MERGING the new grid
    /// into `epg` (append + de-dupe by program id, keep each channel sorted by
    /// start). Drives the guide's lazy horizontal loading: the grid calls this
    /// as focus/scroll approaches the loaded right edge, so more programming
    /// appears before the user reaches empty space. No-op while another load or
    /// extension is running, once the window reaches `epgMaxHoursAhead`, or
    /// before the first `loadEPG` set `epgLoadedThrough`.
    func extendEPG(byHours hours: Int) async {
        guard !providers.isEmpty, !channels.isEmpty,
              !isLoadingEPG, !isExtendingEPG,
              let from = epgLoadedThrough
        else { return }

        // Respect the look-ahead ceiling; clamp the new end to it.
        let ceiling = Calendar.current.date(byAdding: .hour, value: epgMaxHoursAhead, to: Date()) ?? from
        guard from < ceiling else { return }
        let requestedEnd = Calendar.current.date(byAdding: .hour, value: hours, to: from) ?? from
        let to = min(requestedEnd, ceiling)
        guard to > from else { return }

        isExtendingEPG = true
        defer { isExtendingEPG = false }

        let sourceNames: [String: String] = providers.reduce(into: [:]) { acc, entry in
            acc[entry.key] = entry.value.displayName
        }
        let channelsBySource = Dictionary(grouping: channels, by: { $0.sourceId })

        var newEPG: [String: [UnifiedProgram]] = [:]
        var issues: [EPGFetchIssue] = []

        await withTaskGroup(of: (String, Result<[String: [UnifiedProgram]], Error>).self) { group in
            for (sourceId, sourceChannels) in channelsBySource {
                guard let provider = providers[sourceId] else { continue }
                group.addTask {
                    do {
                        let epg = try await provider.fetchEPG(for: sourceChannels, startDate: from, endDate: to)
                        return (sourceId, .success(epg))
                    } catch {
                        return (sourceId, .failure(error))
                    }
                }
            }
            for await (sourceId, result) in group {
                switch result {
                case .success(let epg):
                    for (channelId, programs) in epg { newEPG[channelId] = programs }
                case .failure(let error):
                    if error is CancellationError || (error as NSError).code == NSURLErrorCancelled { continue }
                    issues.append(EPGFetchIssue(
                        sourceId: sourceId,
                        sourceName: sourceNames[sourceId] ?? sourceId,
                        reason: Self.shortEPGFailureReason(for: error)))
                }
            }
        }

        // Merge: append new programs, de-dupe by id (providers re-serve the
        // boundary programme), keep sorted by start.
        var merged = epg
        for (channelId, incoming) in newEPG {
            var existing = merged[channelId] ?? []
            let known = Set(existing.map(\.id))
            existing.append(contentsOf: incoming.filter { !known.contains($0.id) })
            existing.sort { $0.startTime < $1.startTime }
            merged[channelId] = existing
        }
        epg = merged
        epgLoadedThrough = to
        if !issues.isEmpty { epgIssues = issues }
    }

    /// Fills in channel artwork from XMLTV `<channel><icon>` logos for any
    /// channel that didn't get a logo from its M3U `tvg-logo`.
    private func applyXMLTVChannelLogos(_ logos: [String: URL]) {
        guard !logos.isEmpty else { return }
        var didChange = false
        let updated = channels.map { channel -> UnifiedChannel in
            guard channel.logoURL == nil, let logo = logos[channel.id] else { return channel }
            didChange = true
            return channel.withLogo(logo)
        }
        if didChange { channels = updated }
    }

    /// Converts a thrown EPG fetch error into a short, user-readable phrase
    /// for the guide banner. Keep these deliberately concrete — "EPG server
    /// returned HTTP 404" tells the user where to look, whereas the raw
    /// `error.localizedDescription` is often opaque.
    nonisolated static func shortEPGFailureReason(for error: Error) -> String {
        if let xmltv = error as? XMLTVParseError {
            switch xmltv {
            case .httpError(let code):
                return "EPG server returned HTTP \(code)"
            case .parseFailed:
                return "EPG data could not be parsed"
            case .tooLarge:
                return "EPG data is too large"
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCancelled:
                return "EPG request cancelled"
            case NSURLErrorTimedOut:
                return "EPG server didn't respond in time"
            case NSURLErrorCannotFindHost:
                return "EPG server hostname could not be resolved"
            case NSURLErrorCannotConnectToHost:
                return "Could not connect to EPG server"
            case NSURLErrorNetworkConnectionLost:
                return "Network connection was lost"
            case NSURLErrorDNSLookupFailed:
                return "DNS lookup failed for EPG server"
            case NSURLErrorNotConnectedToInternet:
                return "Not connected to the internet"
            case NSURLErrorBadServerResponse:
                return "EPG server returned invalid data"
            case NSURLErrorSecureConnectionFailed,
                 NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateUntrusted,
                 NSURLErrorServerCertificateHasUnknownRoot,
                 NSURLErrorServerCertificateNotYetValid:
                return "EPG server TLS certificate issue"
            case NSURLErrorClientCertificateRejected,
                 NSURLErrorClientCertificateRequired:
                return "EPG server requires a client certificate"
            default:
                break
            }
        }

        return error.localizedDescription
    }

    // MARK: - Background Preloading

    /// Start background preloading of channels and EPG data with low priority.
    /// Call this at app startup to have data ready when user visits Live TV.
    func startBackgroundPreload() {
        // Cancel any existing preload
        backgroundPreloadTask?.cancel()

        backgroundPreloadTask = Task(priority: .background) {

            // Wait a short delay to let critical startup tasks complete
            try? await Task.sleep(nanoseconds: 2_000_000_000)  // 2 seconds

            guard !Task.isCancelled else { return }

            // Only preload if we have sources configured
            guard hasConfiguredSources else {
                return
            }

            // Load channels first (if not already loaded)
            if channels.isEmpty && !isLoadingChannels {
                await loadChannels()
            }

            guard !Task.isCancelled else { return }

            // Then load EPG (if not already loaded)
            if epg.isEmpty && !isLoadingEPG && !channels.isEmpty {
                await loadEPG(startDate: Date(), hours: 6)
            }
        }
    }

    /// Elevate preload priority when user is about to view Live TV.
    /// If data is already loaded, this does nothing. Otherwise it cancels
    /// background task and starts high priority load.
    func elevatePreloadPriority() async {
        // If already loaded, nothing to do
        guard epg.isEmpty else {
            return
        }

        // Cancel background task
        backgroundPreloadTask?.cancel()
        backgroundPreloadTask = nil

        // Load with default (high) priority
        if channels.isEmpty && !isLoadingChannels {
            await loadChannels()
        }

        if epg.isEmpty && !isLoadingEPG && !channels.isEmpty {
            await loadEPG(startDate: Date(), hours: 6)
        }
    }

    // MARK: - Program Helpers

    /// Get the current program for a channel
    func getCurrentProgram(for channel: UnifiedChannel) -> UnifiedProgram? {
        guard let programs = epg[channel.id] else { return nil }
        let now = Date()
        return programs.first { $0.startTime <= now && $0.endTime > now }
    }

    /// The programme airing on `channel` at `date`. A timeshifted viewer is
    /// watching the past, so "current" is the programme at the playhead, not
    /// at the wall clock.
    func program(for channel: UnifiedChannel, at date: Date) -> UnifiedProgram? {
        epg[channel.id]?.first { $0.startTime <= date && $0.endTime > date }
    }

    /// Get the next program for a channel
    func getNextProgram(for channel: UnifiedChannel) -> UnifiedProgram? {
        guard let programs = epg[channel.id] else { return nil }
        let now = Date()
        return programs.first { $0.startTime > now }
    }

    /// Get programs for a channel within a time range
    func getPrograms(for channel: UnifiedChannel, startDate: Date, endDate: Date) -> [UnifiedProgram] {
        guard let programs = epg[channel.id] else { return [] }
        return programs.filter { $0.endTime > startDate && $0.startTime < endDate }
    }

    // MARK: - DVR

    /// Upcoming and in-progress recordings across every source that records.
    /// Drives the guide's recording marks and the Recordings page; refreshed
    /// when a Live TV surface appears and after every change made here.
    @Published private(set) var scheduledRecordings: [LiveTVScheduledRecording] = []

    private func recordingProvider(for sourceId: String) -> (any LiveTVRecordingProvider)? {
        providers[sourceId].flatMap(Self.recorder)
    }

    /// `provider` as a recorder, when it records. Every IPTV source has the
    /// recording methods (Dispatcharr and plain M3U share a type), but only
    /// Dispatcharr with an API key can use them.
    private static func recorder(_ provider: any LiveTVProvider) -> (any LiveTVRecordingProvider)? {
        if let iptv = provider as? IPTVProvider, !iptv.supportsRecording { return nil }
        return provider as? any LiveTVRecordingProvider
    }

    private var recordingProviders: [any LiveTVRecordingProvider] {
        providers.values.compactMap(Self.recorder)
    }

    /// Whether any configured source can record at all.
    var hasRecordingSources: Bool {
        !recordingProviders.isEmpty
    }

    /// Whether `channel`'s source can record.
    func canRecord(_ channel: UnifiedChannel) -> Bool {
        recordingProvider(for: channel.sourceId) != nil
    }

    /// The ways `channel`'s source can record `program`.
    func recordOptions(for program: UnifiedProgram, on channel: UnifiedChannel) async throws -> [LiveTVRecordOption] {
        guard let provider = recordingProvider(for: channel.sourceId) else {
            throw LiveTVRecordingError.notSupported
        }
        return try await provider.recordOptions(for: program, on: channel)
    }

    func record(_ option: LiveTVRecordOption, program: UnifiedProgram, on channel: UnifiedChannel) async throws {
        guard let provider = recordingProvider(for: channel.sourceId) else {
            throw LiveTVRecordingError.notSupported
        }
        try await provider.record(option, program: program, on: channel)
        await refreshScheduledRecordings()
    }

    /// The live recording (scheduled or in progress) that covers `program`.
    func activeRecording(for program: UnifiedProgram) -> LiveTVScheduledRecording? {
        Self.activeRecording(for: program, in: scheduledRecordings)
    }

    static func activeRecording(for program: UnifiedProgram,
                                in recordings: [LiveTVScheduledRecording]) -> LiveTVScheduledRecording? {
        recordings.first { ($0.status == .scheduled || $0.status == .recording) && $0.covers(program) }
    }

    /// Ids of the guide programmes set to record, for the guide's marks. Only
    /// the channels a recording names are looked at, so this stays cheap on
    /// a large lineup.
    func recordingProgramIds(in guide: [String: [UnifiedProgram]]) -> Set<String> {
        let active = scheduledRecordings.filter { $0.status == .scheduled || $0.status == .recording }
        guard !active.isEmpty else { return [] }
        var ids = Set<String>()
        for (channelId, recordings) in Dictionary(grouping: active, by: { $0.channelId ?? "" })
        where !channelId.isEmpty {
            for program in guide[channelId] ?? [] where recordings.contains(where: { $0.covers(program) }) {
                ids.insert(program.id)
            }
        }
        return ids
    }

    func refreshScheduledRecordings() async {
        let recorders = recordingProviders
        guard !recorders.isEmpty else {
            if !scheduledRecordings.isEmpty { scheduledRecordings = [] }
            return
        }
        var all: [LiveTVScheduledRecording] = []
        for provider in recorders {
            // One source failing must not blank the others' recordings.
            if let recordings = try? await provider.scheduledRecordings() {
                all.append(contentsOf: recordings)
            }
        }
        all.sort { $0.startTime < $1.startTime }
        if all != scheduledRecordings { scheduledRecordings = all }
    }

    func cancel(_ recording: LiveTVScheduledRecording) async throws {
        guard let provider = recordingProvider(for: recording.sourceId) else {
            throw LiveTVRecordingError.notSupported
        }
        try await provider.cancel(recording)
        await refreshScheduledRecordings()
    }

    /// Every standing rule, across sources.
    func recordingRules() async -> [LiveTVRecordingRule] {
        var rules: [LiveTVRecordingRule] = []
        for provider in recordingProviders {
            if let sourceRules = try? await provider.recordingRules() {
                rules.append(contentsOf: sourceRules)
            }
        }
        return rules
    }

    /// Cancel the series rule that made `recording`.
    func cancelSeries(of recording: LiveTVScheduledRecording) async throws {
        guard let ruleId = recording.ruleId,
              let provider = recordingProvider(for: recording.sourceId) else {
            throw LiveTVRecordingError.notSupported
        }
        try await provider.delete(LiveTVRecordingRule(id: ruleId, sourceId: recording.sourceId,
                                                      title: recording.title, detail: nil))
        await refreshScheduledRecordings()
    }

    func delete(_ rule: LiveTVRecordingRule) async throws {
        guard let provider = recordingProvider(for: rule.sourceId) else {
            throw LiveTVRecordingError.notSupported
        }
        try await provider.delete(rule)
        await refreshScheduledRecordings()
    }

    // MARK: - Favorites

    func toggleFavorite(_ channel: UnifiedChannel) {
        if let index = favoriteIds.firstIndex(of: channel.id) {
            favoriteIds.remove(at: index)
        } else {
            favoriteIds.append(channel.id)
        }
    }

    func isFavorite(_ channel: UnifiedChannel) -> Bool {
        favoriteIds.contains(channel.id)
    }

    /// Moves a favorite one place earlier or later.
    func moveFavorite(_ channelId: String, up: Bool) {
        guard let index = favoriteIds.firstIndex(of: channelId) else { return }
        let target = up ? index - 1 : index + 1
        guard favoriteIds.indices.contains(target) else { return }
        favoriteIds.swapAt(index, target)
    }

    /// List-style reorder. Offsets index the favorites whose channel is loaded,
    /// which is what a reorder list shows (`favoriteIds` mapped through `channels`).
    func moveFavorites(fromOffsets source: IndexSet, toOffset destination: Int) {
        favoriteIds = Self.moving(favoriteIds, shown: Set(channels.map(\.id)),
                                  fromOffsets: source, toOffset: destination)
    }

    /// `ids` with the shown ones reordered; ids not shown keep their slots.
    static func moving(_ ids: [String], shown: Set<String>,
                       fromOffsets source: IndexSet, toOffset destination: Int) -> [String] {
        let slots = ids.indices.filter { shown.contains(ids[$0]) }
        let visible = slots.map { ids[$0] }
        guard source.allSatisfy(visible.indices.contains), (0...visible.count).contains(destination) else { return ids }
        var reordered = visible.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        reordered.insert(contentsOf: source.map { visible[$0] },
                         at: destination - source.count(in: 0..<destination))
        var result = ids
        for (slot, id) in zip(slots, reordered) { result[slot] = id }
        return result
    }

    /// The favorites among `channels`, in order.
    func favorites(in channels: [UnifiedChannel]) -> [UnifiedChannel] {
        Self.favorites(in: channels, order: favoriteIds)
    }

    /// Rivulet's favorites in the viewer's order, then any the source marks
    /// (Plex account favorites) in the source's order.
    static func favorites(in channels: [UnifiedChannel], order: [String]) -> [UnifiedChannel] {
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // Typed key: the inline tuple comparison times out Xcode 26.3's type checker.
        let key = { (channel: UnifiedChannel) -> (Int, Int, Int) in
            (position[channel.id] ?? .max, channel.favouriteRank ?? .max, channel.channelNumber ?? .max)
        }
        return channels
            .filter { position[$0.id] != nil || $0.isFavourite }
            .sorted { key($0) < key($1) }
    }

    private func loadFavorites() {
        if let saved = userDefaults.array(forKey: favoritesKey) as? [String] {
            favoriteIds = saved
        }
    }

    private func saveFavorites() {
        userDefaults.set(favoriteIds, forKey: favoritesKey)
    }

    // MARK: - Recently watched

    /// `channel` started playing, full screen or in multiview: it heads
    /// Recently Watched now, and For You learns from it once it has played a
    /// minute, so channel surfing teaches nothing. Cancel the returned task
    /// when it stops playing.
    func beganWatching(_ channel: UnifiedChannel) -> Task<Void, Never> {
        noteWatched(channel)
        return Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.recordViewing(channel)
        }
    }

    /// Erases what For You has learned. Recently Watched is untouched.
    func forgetViewings() {
        viewings = []
        userDefaults.removeObject(forKey: viewingsKey)
    }

    private func noteWatched(_ channel: UnifiedChannel) {
        var ids = recentChannelIds.filter { $0 != channel.id }
        ids.insert(channel.id, at: 0)
        recentChannelIds = Array(ids.prefix(12))
        userDefaults.set(recentChannelIds, forKey: recentsKey)
    }

    /// Learns from `channel`'s programme right now, when suggestions are on.
    private func recordViewing(_ channel: UnifiedChannel) {
        guard suggestionsEnabled else { return }
        let program = getCurrentProgram(for: channel).flatMap { $0.id.contains(":placeholder:") ? nil : $0 }
        viewings.append(LiveViewing(
            channelId: channel.id, at: Date(), title: program?.title,
            labels: LiveGenre.specificLabels(of: program).sorted(),
            genre: LiveGenre.of(channel, airing: program, guide: epg[channel.id] ?? [])?.rawValue))
        viewings = Array(viewings.suffix(300))
        if let data = try? JSONEncoder().encode(viewings) {
            userDefaults.set(data, forKey: viewingsKey)
        }
    }

    // MARK: - Stream URL

    /// Resolve a PLAYABLE stream URL, performing any provider-side session
    /// setup first (Plex cloud-EPG/DVB channels need a tune before the
    /// transcoder will serve them).
    func resolveStreamURL(for channel: UnifiedChannel) async throws -> URL? {
        guard let provider = providers[channel.sourceId] else {
            return channel.streamURL
        }
        return try await provider.resolveStreamURL(for: channel)
    }
}
