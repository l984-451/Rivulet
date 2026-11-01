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
import CryptoKit
import UIKit

@MainActor
class LiveTVDataStore: ObservableObject {
    static let shared = LiveTVDataStore()

    // MARK: - Published State

    /// All channels from all sources, merged and sorted
    @Published var channels: [UnifiedChannel] = []

    /// Current EPG data (channelId -> programs)
    @Published var epg: [String: [UnifiedProgram]] = [:] {
        didSet { rememberEventSlots() }
    }

    /// Channels whose guide has carried an event slot (a pregame block or "No
    /// game scheduled"), so a guide gap on one means no game is on. Kept
    /// because midweek the loaded window holds no such block.
    private(set) var eventSlotIds: Set<String> = []

    /// End of the currently loaded EPG window. `fillGuide` moves it out to
    /// `epgMaxHoursAhead` after each `loadEPG`. nil until the first load completes.
    @Published private(set) var epgLoadedThrough: Date?

    /// How far ahead the guide fills. Plex serves 8 days; providers with less
    /// just return nothing past their end.
    static let epgMaxHoursAhead = 192
    /// Hours per background fill request.
    private static let fillChunkHours = 12
    private var fillTask: Task<Void, Never>?
    private var keepFreshTask: Task<Void, Never>?
    /// VOD players currently up. While any is, the half-day fill holds: the far-off guide (a 16 MB,
    /// ~6 s `/grid` response per half day on a slow PMS) is not needed behind a film, and filling it
    /// then cost the player network and main-actor time. A count, not a flag, so a player that
    /// disappears after the next one started does not resume the fill under it.
    private var playersHoldingGuideFill = 0
    /// Last full `loadEPG`. Past 6 hours a refresh reloads every day, not
    /// just the next hours, so far-off schedule changes show up too.
    private var lastFullEPGLoad: Date?

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

    /// Source favorites (Plex account favorites) removed in Rivulet. Hidden
    /// here only; the source's own list is left alone.
    @Published private(set) var unfavoritedIds: Set<String> = [] {
        didSet { userDefaults.set(Array(unfavoritedIds), forKey: unfavoritedKey) }
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

    /// Plex servers whose DVR the user hid from Live TV (#406); not in `sources`.
    @Published private(set) var hiddenPlexSources: [LiveTVSourceInfo] = []
    /// The machineIdentifier behind each Plex source id, shown or hidden.
    private(set) var plexMachineIDs: [String: String] = [:]

    // MARK: - Private Properties

    private var providers: [String: any LiveTVProvider] = [:] {
        didSet { providersGeneration += 1 }
    }
    /// Bumped when the source set changes. A load started for an older set is
    /// cancelled; one for the current set is waited on (see `loadChannels`).
    private var providersGeneration = 0
    /// Servers and tokens the Plex sources were checked under.
    private var plexSourceKeys: Set<String> = []
    private var plexSync: Task<Void, Never>?
    /// IPTV sources kept from a restricted profile; still saved, back on an unrestricted one.
    private var withheldIPTVProviders: [String: any LiveTVProvider] = [:]
    private var channelLoad: (task: Task<Void, Never>, generation: Int)?
    private var epgLoad: (task: Task<Void, Never>, generation: Int, channelCount: Int, window: DateInterval)?
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
    /// initial window (EPGTheme.initialGuideHours); `fillGuide` does the rest.
    static let refreshWindowHours = 6

    /// Guards `refreshIfStale` so several surfaces appearing at once (the tab
    /// switching in while a foreground notification lands) run ONE refresh.
    private var staleRefreshTask: Task<Void, Never>?

    private let userDefaults = UserDefaults.standard
    private let favoritesKey = "liveTVFavoriteChannelIds"
    private let unfavoritedKey = "liveTVUnfavoritedChannelIds"
    private let recentsKey = "liveTVRecentChannelIds"
    private let eventSlotsKey = "liveTVEventSlotChannelIds"
    private let viewingsKey = "liveTVViewings"
    private let sourcesKey = "liveTVSourceConfigurations"

    // MARK: - Source Configuration (Persistable)

    struct SourceConfiguration: Codable {
        var id: String
        let type: String  // "dispatcharr", "m3u", "xtream", "plex"
        let name: String
        let baseURL: String?
        /// Kept in the Keychain (`playlistURLKey`); here only if the Keychain refused it.
        var m3uURL: String?
        var epgURL: String?
        var apiToken: String?

        /// Dispatcharr channel profile, nil for every channel. Optional so that
        /// source configurations written before this field existed still decode:
        /// a missing key leaves it nil, which is the previous all-channels
        /// behavior.
        var channelProfile: String?
        /// Xtream Codes or Tvheadend account name. Its password is in the Keychain (`apiTokenKey`).
        var username: String?
        /// Tvheadend: whether the login may record, nil when unknown.
        var canRecord: Bool?

        init(id: String, type: String, name: String, baseURL: String?, m3uURL: String?,
             epgURL: String?, apiToken: String?, channelProfile: String? = nil, username: String? = nil,
             canRecord: Bool? = nil) {
            self.username = username
            self.canRecord = canRecord
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
        secureSavedM3USources()
        loadFavorites()
        recentChannelIds = userDefaults.stringArray(forKey: recentsKey) ?? []
        eventSlotIds = Set(userDefaults.stringArray(forKey: eventSlotsKey) ?? [])
        viewings = userDefaults.data(forKey: viewingsKey)
            .flatMap { try? JSONDecoder().decode([LiveViewing].self, from: $0) } ?? []
        loadSavedSources()
        observeAppLifecycle()
        plexContentTokenChanged()
    }

    // MARK: - Freshness / refresh

    /// True when the guide on screen can't be trusted: fetched more than `maxAge`
    /// ago, or the loaded EPG window no longer reaches now (after a long sleep the
    /// grid renders empty with `epg` non-empty). An empty store is always stale.
    func isStale(maxAge: TimeInterval = defaultMaxAge, now: Date = Date()) -> Bool {
        if channels.isEmpty || epg.isEmpty { return true }
        guard let lastEPGLoad, let lastChannelsLoad else { return true }
        if now.timeIntervalSince(lastEPGLoad) > maxAge { return true }
        if now.timeIntervalSince(lastChannelsLoad) > maxAge { return true }
        if let through = epgLoadedThrough, through <= now { return true }
        return false
    }

    /// Re-fetches channels and EPG when `isStale`; cheap to call on every arrival
    /// and foreground. Concurrent callers share one refresh, because two
    /// overlapping EPG fetches cancel each other through `epgLoad`.
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
            let count = self.channels.count
            await self.loadChannels()
            guard !self.channels.isEmpty else { return }
            let now = Date()
            let near = now.addingTimeInterval(Double(Self.refreshWindowHours) * 3600)
            if self.epg.isEmpty || self.channels.count != count || (self.epgLoadedThrough ?? now) <= near
                || now.timeIntervalSince(self.lastFullEPGLoad ?? .distantPast) > 6 * 3600 {
                await self.loadEPG(startDate: now, hours: Self.refreshWindowHours)
            } else if await self.mergeEPG(from: now, to: near) {
                // The far days stay; only the next hours are re-read for changes.
                self.lastEPGLoad = Date()
            }
        }
        staleRefreshTask = task
        await task.value
        staleRefreshTask = nil
    }

    /// Re-checks the guide every 10 minutes while the app is open, so a guide
    /// left on screen (or behind the player) keeps moving forward.
    private func keepGuideFresh() {
        guard keepFreshTask == nil else { return }
        keepFreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.defaultMaxAge / 3))
                await self?.refreshIfStale()
                self?.fillGuide()
            }
        }
    }

    /// Pulls the rest of the guide in half-day requests after the first
    /// window paints. Stops at the ceiling or on a failure; the next refresh
    /// starts it again.
    private func fillGuide() {
        guard fillTask == nil, !epg.isEmpty, playersHoldingGuideFill == 0 else { return }
        fillTask = Task { [weak self] in
            while !Task.isCancelled, await self?.extendEPG() == true {}
            // A cancelled fill was already replaced by `loadEPG`, or paused for playback.
            if !Task.isCancelled { self?.fillTask = nil }
        }
    }

    /// Holds the half-day fill while a VOD title plays and picks it up where it stopped once the last
    /// player is gone. The near-term refresh keeps running, so a guide behind the player still moves
    /// forward. Each `beginPlaybackGuideHold` is matched by one `endPlaybackGuideHold`.
    func beginPlaybackGuideHold() {
        playersHoldingGuideFill += 1
        fillTask?.cancel()
        fillTask = nil
    }

    func endPlaybackGuideHold() {
        guard playersHoldingGuideFill > 0 else { return }
        playersHoldingGuideFill -= 1
        if playersHoldingGuideFill == 0 { fillGuide() }
    }

    /// Refresh the guide when the app returns to the foreground. tvOS suspends
    /// for long stretches, so this is the most common way the grid goes stale.
    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // A server that was down at launch gets its DVR found now.
                self?.plexContentTokenChanged()
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
        let sourceId = Self.m3uSourceId(for: m3uURL)
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

    /// Add an Xtream Codes source. Re-adding the same login replaces it.
    func addXtreamSource(account: XtreamAccount, name: String) async {
        let sourceId = Self.xtreamSourceId(for: account)
        providers[sourceId] = IPTVProvider(xtream: account, sourceId: sourceId, displayName: name)
        saveSources()
        await updateSourceInfo()
    }

    /// Add a Tvheadend source. Re-adding the same login replaces it.
    func addTvheadendSource(account: TvheadendAccount, name: String, canRecord: Bool? = nil) async {
        let sourceId = Self.tvheadendSourceId(for: account)
        providers[sourceId] = IPTVProvider(tvheadend: account, sourceId: sourceId, displayName: name, canRecord: canRecord)
        saveSources()
        await updateSourceInfo()
    }

    /// From a hash of the server and username, so neither ends up in channel ids.
    /// Anonymous and signed-in sources on one server stay apart.
    static func tvheadendSourceId(for account: TvheadendAccount) -> String {
        let key = account.server.absoluteString.lowercased() + "\n" + (account.username ?? "")
        return "tvheadend:" + SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// From a hash of the server and username, so neither ends up in channel ids.
    static func xtreamSourceId(for account: XtreamAccount) -> String {
        let key = account.server.absoluteString.lowercased() + "\n" + account.username
        return "xtream:" + SHA256.hash(data: Data(key.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    #if DEBUG
    /// DEBUG launch hooks: a source for this run only, never saved.
    func debugAddTransientSource(_ provider: any LiveTVProvider) {
        providers[provider.sourceId] = provider
    }
    #endif

    /// Whether a source with this id is in use.
    func hasSource(id: String) -> Bool { providers[id] != nil }

    /// Installs the source that follows a signed-in server (Plex DVR, Jellyfin
    /// Live TV) in place of any of `type`, or just removes them. Never saved.
    func setServerSource(_ provider: (any LiveTVProvider)?, of type: LiveTVSourceType) {
        let stale = Set(providers.filter { $0.value.sourceType == type }.keys)
        guard provider != nil || !stale.isEmpty else { return }
        dropSources(stale)
        if let provider { providers[provider.sourceId] = provider }
        reloadSources()
    }

    /// Remove a source by ID
    func removeSource(id: String) async {
        withheldIPTVProviders.removeValue(forKey: id)
        KeychainHelper.delete(Self.apiTokenKey(sourceId: id))
        KeychainHelper.delete(Self.playlistURLKey(sourceId: id))
        KeychainHelper.delete(Self.guideURLKey(sourceId: id))
        dropSources([id])
        saveSources()
        await updateSourceInfo()
    }

    /// Takes these sources' providers, channels and guide out of use.
    private func dropSources(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        for id in ids { providers.removeValue(forKey: id) }
        // Collected before the channels go, or there is nothing left to purge.
        let removed = Set(channels.lazy.filter { ids.contains($0.sourceId) }.map(\.id))
        channels.removeAll { ids.contains($0.sourceId) }
        for channelId in removed {
            epg.removeValue(forKey: channelId)
        }
    }

    private func reloadSources() {
        listSources()
        Task {
            await loadChannels()
            await loadEPG()
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
                if let m3uString = KeychainHelper.get(Self.playlistURLKey(sourceId: config.id)) ?? config.m3uURL,
                   let m3uURL = URL(string: m3uString) {
                    let epgURL = (KeychainHelper.get(Self.guideURLKey(sourceId: config.id)) ?? config.epgURL)
                        .flatMap { URL(string: $0) }
                    let provider = IPTVProvider(
                        m3uURL: m3uURL,
                        epgURL: epgURL,
                        sourceId: config.id,
                        displayName: config.name
                    )
                    providers[config.id] = provider
                }

            case "xtream":
                if let server = config.baseURL.flatMap(URL.init(string:)), let username = config.username,
                   let password = KeychainHelper.get(Self.apiTokenKey(sourceId: config.id)) ?? config.apiToken {
                    providers[config.id] = IPTVProvider(
                        xtream: XtreamAccount(server: server, username: username, password: password),
                        sourceId: config.id, displayName: config.name)
                }

            case "tvheadend":
                if let server = config.baseURL.flatMap(URL.init(string:)) {
                    let password = config.username.flatMap { _ in
                        KeychainHelper.get(Self.apiTokenKey(sourceId: config.id)) ?? config.apiToken
                    }
                    providers[config.id] = IPTVProvider(
                        tvheadend: TvheadendAccount(server: server, username: config.username, password: password),
                        sourceId: config.id, displayName: config.name, canRecord: config.canRecord)
                }

            default:
                // "plex" is saved by builds that added Plex by hand; the
                // source now follows the server (`plexContentTokenChanged`).
                break
            }
        }

        applyProfileRestrictions()
        listSources()
        if configs.contains(where: { $0.type == "plex" }) { saveSources() }
    }

    /// Moves IPTV sources out of a restricted profile's reach, and back. True when that changed anything.
    @discardableResult
    private func applyProfileRestrictions() -> Bool {
        if PlexUserProfileManager.shared.isRestrictedProfile {
            // Jellyfin's source leaves with the Jellyfin server, which such a profile does not see.
            let iptv = providers.filter { !$0.value.sourceType.followsServer }
            guard !iptv.isEmpty else { return false }
            withheldIPTVProviders.merge(iptv) { _, new in new }
            dropSources(Set(iptv.keys))
            return true
        }
        guard !withheldIPTVProviders.isEmpty else { return false }
        providers.merge(withheldIPTVProviders) { current, _ in current }
        withheldIPTVProviders = [:]
        return true
    }

    /// Lists the sources now, so the sidebar's Live TV tab exists at once; the
    /// connection probe behind `updateSourceInfo` can take tens of seconds.
    private func listSources() {
        sources = providers.map { id, provider in
            LiveTVSourceInfo(id: id, sourceType: provider.sourceType, displayName: provider.displayName,
                             channelCount: 0, isConnected: false, lastSync: nil,
                             channelProfile: (provider as? IPTVProvider)?.channelProfile)
        }.sorted { $0.displayName < $1.displayName }

        // Update source info (async but we don't wait)
        Task {
            await updateSourceInfo()
        }
    }

    /// The Plex content token or the account's servers changed (sign-in,
    /// sign-out, server or profile switch): each server whose `/livetv/dvrs`
    /// lists a DVR is a Plex source, found again under the new tokens. IPTV
    /// sources hold no Plex token and only move for a restricted profile.
    func plexContentTokenChanged() {
        let restrictionsChanged = applyProfileRestrictions()
        let auth = PlexAuthManager.shared
        var servers: [(key: String, url: String, token: String, name: String, machineID: String?)] = []
        if let key = Self.plexSourceKey(serverURL: auth.selectedServerURL, token: auth.selectedServerToken),
           let url = auth.selectedServerURL, let token = auth.selectedServerToken {
            servers.append((key, url, token, auth.savedServerName ?? "Plex", auth.selectedServerMachineID))
        }
        for extra in PlexExtraServers.shared.current {
            guard let token = PlexExtraServers.shared.token(for: extra),
                  let key = Self.plexSourceKey(serverURL: extra.url, token: token) else { continue }
            servers.append((key, extra.url, token, extra.name, extra.machineID))
        }
        // Hiding a server changes its key, so a toggle resyncs like a sign-in.
        let hidden = hiddenPlexServerIDs
        servers = servers.map { server in
            guard let id = server.machineID, hidden.contains(id) else { return server }
            return (server.key + "\nhidden", server.url, server.token, server.name, id)
        }
        let keys = Set(servers.map(\.key))
        if !keys.isEmpty, keys == plexSourceKeys {
            if restrictionsChanged { reloadSources() }
            return
        }
        plexSync?.cancel()
        plexSourceKeys = []
        plexMachineIDs = [:]
        hiddenPlexSources = []
        let stale = Set(providers.filter { $0.value.sourceType == .plex }.keys)
        dropSources(stale)
        guard !servers.isEmpty else {
            if restrictionsChanged || !stale.isEmpty { reloadSources() }
            return
        }
        plexSync = Task { [weak self] in
            let hasDVR = await withTaskGroup(of: (Int, Bool).self) { group in
                for (index, server) in servers.enumerated() {
                    group.addTask { (index, await PlexLiveTVProvider.checkAvailability(serverURL: server.url, authToken: server.token)) }
                }
                return await group.reduce(into: Set<Int>()) { if $1.1 { $0.insert($1.0) } }
            }
            guard let self, !Task.isCancelled else { return }
            for index in hasDVR.sorted() {
                let server = servers[index]
                let provider = PlexLiveTVProvider(serverURL: server.url, authToken: server.token, serverName: server.name)
                if let id = server.machineID {
                    plexMachineIDs[provider.sourceId] = id
                    if hidden.contains(id) {
                        hiddenPlexSources.append(LiveTVSourceInfo(
                            id: provider.sourceId, sourceType: .plex, displayName: provider.displayName,
                            channelCount: 0, isConnected: false, lastSync: nil))
                        continue
                    }
                }
                providers[provider.sourceId] = provider
            }
            plexSourceKeys = keys
            if !hasDVR.isEmpty || restrictionsChanged || !stale.isEmpty { reloadSources() }
        }
    }

    static let hiddenPlexServersKey = "liveTVHiddenPlexServers"

    private var hiddenPlexServerIDs: Set<String> {
        Set(userDefaults.stringArray(forKey: Self.hiddenPlexServersKey) ?? [])
    }

    func isPlexLiveTVHidden(machineID: String) -> Bool {
        hiddenPlexServerIDs.contains(machineID)
    }

    /// Shows or hides a Plex server's DVR in Live TV; `plexSourcesSynced` waits for the result.
    func setPlexLiveTVHidden(_ hide: Bool, machineID: String) {
        var ids = hiddenPlexServerIDs
        if hide { ids.insert(machineID) } else { ids.remove(machineID) }
        userDefaults.set(ids.sorted(), forKey: Self.hiddenPlexServersKey)
        plexContentTokenChanged()
    }

    func plexSourcesSynced() async {
        await plexSync?.value
    }

    /// What the Plex source is confirmed under; nil without a content token.
    nonisolated static func plexSourceKey(serverURL: String?, token: String?) -> String? {
        guard let serverURL, let token else { return nil }
        return serverURL + "\n" + token
    }

    /// Save current source configurations to UserDefaults
    private func saveSources() {
        var configs: [SourceConfiguration] = []

        for (id, provider) in providers.merging(withheldIPTVProviders, uniquingKeysWith: { current, _ in current }) {
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
                        m3uURL: Self.storeSecret(iptvProvider.m3uURL?.absoluteString,
                                                 key: Self.playlistURLKey(sourceId: id)),
                        epgURL: Self.storeSecret(iptvProvider.epgURL?.absoluteString,
                                                 key: Self.guideURLKey(sourceId: id)),
                        apiToken: nil
                    ))
                }

            case .xtream:
                if let iptvProvider = provider as? IPTVProvider, let account = iptvProvider.xtreamAccount {
                    configs.append(SourceConfiguration(
                        id: id,
                        type: "xtream",
                        name: provider.displayName,
                        baseURL: account.server.absoluteString,
                        m3uURL: nil,
                        epgURL: nil,
                        apiToken: Self.storeAPIToken(account.password, sourceId: id),
                        username: account.username
                    ))
                }

            case .tvheadend:
                if let iptvProvider = provider as? IPTVProvider, let account = iptvProvider.tvheadendAccount {
                    configs.append(SourceConfiguration(
                        id: id,
                        type: "tvheadend",
                        name: provider.displayName,
                        baseURL: account.server.absoluteString,
                        m3uURL: nil,
                        epgURL: nil,
                        apiToken: Self.storeAPIToken(account.password, sourceId: id),
                        username: account.username,
                        canRecord: iptvProvider.tvheadendCanRecord
                    ))
                }

            case .plex, .jellyfin:
                break  // Follows its server; not saved.
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
        storeSecret(token, key: apiTokenKey(sourceId: sourceId))
    }

    /// Puts `value` in the Keychain. Returns what the saved config must still
    /// hold: nil, unless the Keychain refused it and the value would be lost.
    private static func storeSecret(_ value: String?, key: String) -> String? {
        guard let value, !value.isEmpty else {
            KeychainHelper.delete(key)
            return nil
        }
        return KeychainHelper.set(value, forKey: key) ? nil : value
    }

    /// Keychain accounts for an M3U source's playlist and guide URLs, which
    /// often embed the provider's username and password.
    static func playlistURLKey(sourceId: String) -> String { "liveTVSourceM3U_\(sourceId)" }
    static func guideURLKey(sourceId: String) -> String { "liveTVSourceEPG_\(sourceId)" }

    /// An M3U source's id, from a hash of its playlist URL so the URL never
    /// becomes part of the channel ids saved in favorites and recents.
    static func m3uSourceId(for url: URL) -> String {
        "m3u:" + SHA256.hash(data: Data(url.absoluteString.utf8)).prefix(8)
            .map { String(format: "%02x", $0) }.joined()
    }

    private func secureSavedM3USources() {
        guard let data = userDefaults.data(forKey: sourcesKey),
              var configs = try? JSONDecoder().decode([SourceConfiguration].self, from: data),
              Self.secureM3USources(&configs, defaults: userDefaults,
                                    channelListKeys: [favoritesKey, unfavoritedKey, recentsKey, eventSlotsKey],
                                    viewingsKey: viewingsKey),
              let encoded = try? JSONEncoder().encode(configs) else { return }
        userDefaults.set(encoded, forKey: sourcesKey)
    }

    /// Older builds keyed an M3U source by its full playlist URL and saved both
    /// URLs in plain text. Re-keys such a source (renaming its channels in
    /// every saved list, so favorites survive) and moves the URLs into the
    /// Keychain. True when `configs` changed and must be written back.
    static func secureM3USources(_ configs: inout [SourceConfiguration], defaults: UserDefaults,
                                 channelListKeys: [String], viewingsKey: String) -> Bool {
        var changed = false
        for index in configs.indices where configs[index].type == "m3u" {
            guard let m3u = configs[index].m3uURL, let url = URL(string: m3u) else { continue }
            let oldId = configs[index].id
            let newId = m3uSourceId(for: url)
            if newId != oldId {
                renameChannels(from: "m3u:\(oldId):", to: "m3u:\(newId):", defaults: defaults,
                               channelListKeys: channelListKeys, viewingsKey: viewingsKey)
                configs[index].id = newId
            }
            configs[index].m3uURL = storeSecret(m3u, key: playlistURLKey(sourceId: newId))
            configs[index].epgURL = storeSecret(configs[index].epgURL, key: guideURLKey(sourceId: newId))
            changed = true
        }
        return changed
    }

    private static func renameChannels(from oldPrefix: String, to newPrefix: String, defaults: UserDefaults,
                                       channelListKeys: [String], viewingsKey: String) {
        func rename(_ id: String) -> String {
            id.hasPrefix(oldPrefix) ? newPrefix + id.dropFirst(oldPrefix.count) : id
        }
        for key in channelListKeys {
            if let ids = defaults.stringArray(forKey: key) { defaults.set(ids.map(rename), forKey: key) }
        }
        if let data = defaults.data(forKey: viewingsKey),
           let viewings = try? JSONDecoder().decode([LiveViewing].self, from: data) {
            let renamed = viewings.map {
                LiveViewing(channelId: rename($0.channelId), at: $0.at, title: $0.title, labels: $0.labels, genre: $0.genre)
            }
            if let encoded = try? JSONEncoder().encode(renamed) { defaults.set(encoded, forKey: viewingsKey) }
        }
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

    /// Fetches every provider in parallel and merges one sorted lineup. Off the
    /// main actor: a 100k-channel M3U without `tvg-chno` sorts by Unicode collation.
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
                    DiagLog.error(.liveTV, "Channels failed for source \(sourceId.prefix(12)): \(DiagLog.describe(error))")
                }
            }
        }

        DiagLog.notice(.liveTV, "Channels loaded: \(allChannels.count), failed sources: \(errors.count)")
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

        // Arriving on Live TV calls this from several places at once. They share
        // one load: PMS keeps working on a request the client abandons, and
        // that work slows the next one (#338).
        if let loading = channelLoad, loading.generation == providersGeneration {
            await loading.task.value
            if channelLoad?.task == loading.task { channelLoad = nil }
            return
        }
        channelLoad?.task.cancel()

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
        let task = Task.detached { [providerEntries] in
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
        channelLoad = (task, providersGeneration)

        await task.value
        if channelLoad?.task == task { channelLoad = nil }
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

        let endDate = Calendar.current.date(byAdding: .hour, value: hours, to: startDate) ?? startDate
        let window = DateInterval(start: startDate, end: max(startDate, endDate))

        // Same reason as loadChannels: a load in flight is waited out, never
        // abandoned, and answers this call when it covers the same window.
        while let loading = epgLoad, loading.generation == providersGeneration {
            let answers = loading.channelCount == channels.count
                && Self.epgWindow(loading.window, covers: window)
            await loading.task.value
            if epgLoad?.task == loading.task { epgLoad = nil }
            if answers { return }
        }
        epgLoad?.task.cancel()
        fillTask?.cancel()
        fillTask = nil

        isLoadingEPG = true
        epgIssues = []

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
        let task = Task.detached { [channelsBySource, providersById, providerList, sourceNames] in
            var allEPG: [String: [UnifiedProgram]] = [:]
            var issues: [EPGFetchIssue] = []

            // Fetch EPG from each provider
            await withTaskGroup(of: (String, Result<[String: [UnifiedProgram]], Error>).self) { group in
                for (sourceId, sourceChannels) in channelsBySource {
                    guard let provider = providersById[sourceId] else {
                        DiagLog.error(.liveTV, "Guide: no provider for source \(sourceId.prefix(12))")
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
                        DiagLog.error(.liveTV, "Guide failed for source \(sourceId.prefix(12)): \(DiagLog.describe(error))")
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

            DiagLog.notice(.liveTV, "Guide loaded: \(allEPG.count) channels, \(allEPG.values.reduce(0) { $0 + $1.count }) programs, issues: \(issues.count)")
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
                if !finalEPG.isEmpty { self.lastEPGLoad = Date(); self.lastFullEPGLoad = Date() }
            }
        }

        epgLoad = (task, providersGeneration, channels.count, window)

        await task.value
        if epgLoad?.task == task { epgLoad = nil }
        fillGuide()
        if !epg.isEmpty { keepGuideFresh() }
    }

    /// Whether a guide load for `loading` answers a request for `requested`.
    /// An hour of slack: callers arriving together read "now" at different
    /// moments, and the guide rounds its start down to the half hour.
    nonisolated static func epgWindow(_ loading: DateInterval, covers requested: DateInterval) -> Bool {
        loading.start <= requested.start.addingTimeInterval(3600)
            && loading.end >= requested.end.addingTimeInterval(-3600)
    }

    /// Extends the loaded window by one fill chunk. False when there is
    /// nothing left to fetch, no source answered, or a full load replaced the grid.
    private func extendEPG() async -> Bool {
        guard !isLoadingEPG, let from = epgLoadedThrough else { return false }
        let ceiling = Date().addingTimeInterval(Double(Self.epgMaxHoursAhead) * 3600)
        let to = min(from.addingTimeInterval(Double(Self.fillChunkHours) * 3600), ceiling)
        // An hour's minimum, so the moving ceiling doesn't buy a request per tick.
        guard to.timeIntervalSince(from) >= 3600, await mergeEPG(from: from, to: to),
              epgLoadedThrough == from, !Task.isCancelled
        else { return false }
        epgLoadedThrough = to
        return true
    }

    /// Fetches `from..<to` from every source and replaces that range of `epg`
    /// with it. Channels a source returned nothing for keep what they had.
    /// False when every source failed or a full load started meanwhile.
    private func mergeEPG(from: Date, to: Date) async -> Bool {
        guard !providers.isEmpty, !channels.isEmpty else { return false }
        let channelsBySource = Dictionary(grouping: channels, by: { $0.sourceId })

        var newEPG: [String: [UnifiedProgram]] = [:]
        var answered = 0

        await withTaskGroup(of: [String: [UnifiedProgram]]?.self) { group in
            for (sourceId, sourceChannels) in channelsBySource {
                guard let provider = providers[sourceId] else { continue }
                group.addTask {
                    try? await provider.fetchEPG(for: sourceChannels, startDate: from, endDate: to)
                }
            }
            for await result in group {
                guard let result else { continue }
                answered += 1
                newEPG.merge(result) { _, new in new }
            }
        }
        guard !isLoadingEPG, !Task.isCancelled else { return false }
        // No banner on failure: the guide already on screen stays usable.
        epg = Self.merging(newEPG, into: epg, from: from, to: to)
        return answered > 0
    }

    /// `incoming` replaces each of its channels' programmes overlapping
    /// `from..<to`; everything outside that range stays.
    nonisolated static func merging(_ incoming: [String: [UnifiedProgram]],
                                    into epg: [String: [UnifiedProgram]],
                                    from: Date, to: Date) -> [String: [UnifiedProgram]] {
        var merged = epg
        for (channelId, programs) in incoming {
            let kept = (merged[channelId] ?? []).filter { $0.endTime <= from || $0.startTime >= to }
            let ids = Set(programs.map(\.id))
            merged[channelId] = (kept.filter { !ids.contains($0.id) } + programs)
                .sorted { $0.startTime < $1.startTime }
        }
        return merged
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
    /// Dispatcharr with an API key can use them; Jellyfin needs the user's right.
    private static func recorder(_ provider: any LiveTVProvider) -> (any LiveTVRecordingProvider)? {
        guard let recorder = provider as? any LiveTVRecordingProvider, recorder.supportsRecording else { return nil }
        return recorder
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
        if isFavorite(channel) {
            favoriteIds.removeAll { $0 == channel.id }
            if channel.isFavourite { unfavoritedIds.insert(channel.id) }
        } else {
            favoriteIds.append(channel.id)
            unfavoritedIds.remove(channel.id)
        }
    }

    func isFavorite(_ channel: UnifiedChannel) -> Bool {
        favoriteIds.contains(channel.id) || (channel.isFavourite && !unfavoritedIds.contains(channel.id))
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
        Self.favorites(in: channels, order: favoriteIds, unfavorited: unfavoritedIds)
    }

    /// Rivulet's favorites in the viewer's order, then any the source marks
    /// (Plex account favorites) in the source's order, less those removed here.
    static func favorites(in channels: [UnifiedChannel], order: [String],
                          unfavorited: Set<String> = []) -> [UnifiedChannel] {
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        // Typed key: the inline tuple comparison times out Xcode 26.3's type checker.
        let key = { (channel: UnifiedChannel) -> (Int, Int, ChannelNumber) in
            (position[channel.id] ?? .max, channel.favouriteRank ?? .max, channel.channelNumber ?? .max)
        }
        return channels
            .filter { position[$0.id] != nil || ($0.isFavourite && !unfavorited.contains($0.id)) }
            .sorted { key($0) < key($1) }
    }

    private func rememberEventSlots() {
        let seen = epg.compactMap { id, programs in
            programs.contains { $0.isPregameBlock || $0.isEmptySlot } ? id : nil
        }
        guard !eventSlotIds.isSuperset(of: seen) else { return }
        eventSlotIds.formUnion(seen)
        userDefaults.set(Array(eventSlotIds), forKey: eventSlotsKey)
    }

    private func loadFavorites() {
        if let saved = userDefaults.array(forKey: favoritesKey) as? [String] {
            favoriteIds = saved
        }
        unfavoritedIds = Set(userDefaults.stringArray(forKey: unfavoritedKey) ?? [])
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

    /// The Dispatcharr server behind a channel and its proxy channel uuid, for
    /// stream switching. nil for any other source and for Xtream-form URLs.
    func dispatcharrChannel(for channel: UnifiedChannel) -> (service: DispatcharrService, uuid: String)? {
        guard let service = (providers[channel.sourceId] as? IPTVProvider)?.dispatcharrService,
              service.apiToken != nil,
              let uuid = channel.streamURL.flatMap(DispatcharrService.channelUUID(fromStreamURL:))
        else { return nil }
        return (service, uuid)
    }

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
