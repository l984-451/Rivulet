//
//  LiveTVDataStore.swift
//  Rivulet
//
//  Central state management for Live TV channels and EPG across all sources
//

import Foundation
import Combine
import Sentry

@MainActor
class LiveTVDataStore: ObservableObject {
    static let shared = LiveTVDataStore()

    // MARK: - Published State

    /// All channels from all sources, merged and sorted
    @Published var channels: [UnifiedChannel] = []

    /// Current EPG data (channelId -> programs)
    @Published var epg: [String: [UnifiedProgram]] = [:]

    /// Favorite channel IDs
    @Published var favoriteIds: Set<String> = [] {
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

    /// Whether EPG has been preloaded in background
    @Published private(set) var isEPGPreloaded = false

    private let userDefaults = UserDefaults.standard
    private let favoritesKey = "liveTVFavoriteChannelIds"
    private let sourcesKey = "liveTVSourceConfigurations"

    // MARK: - Source Configuration (Persistable)

    struct SourceConfiguration: Codable {
        let id: String
        let type: String  // "dispatcharr", "m3u", "plex"
        let name: String
        let baseURL: String?
        let m3uURL: String?
        let epgURL: String?
        let apiToken: String?
    }

    // MARK: - Source Info

    struct LiveTVSourceInfo: Identifiable, Sendable {
        let id: String
        let sourceType: LiveTVSourceType
        let displayName: String
        let channelCount: Int
        let isConnected: Bool
        let lastSync: Date?
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

    /// Channels filtered to favorites only
    var favoriteChannels: [UnifiedChannel] {
        channels.filter { favoriteIds.contains($0.id) }
    }

    /// Channels grouped by category/group
    var channelsByGroup: [String: [UnifiedChannel]] {
        var groups: [String: [UnifiedChannel]] = [:]
        for channel in channels {
            let group = channel.groupTitle ?? "Other"
            if groups[group] == nil {
                groups[group] = []
            }
            groups[group]?.append(channel)
        }
        return groups
    }

    /// Available group names, sorted
    var availableGroups: [String] {
        channelsByGroup.keys.sorted()
    }

    /// Check if any Live TV source is configured
    var hasConfiguredSources: Bool {
        !providers.isEmpty
    }

    // MARK: - Initialization

    private init() {
        loadFavorites()
        loadSavedSources()
    }

    // MARK: - Source Management

    /// Add a Dispatcharr source
    func addDispatcharrSource(baseURL: URL, name: String, apiToken: String? = nil) async {
        let sourceId = "dispatcharr:\(baseURL.absoluteString)"
        let provider = IPTVProvider(
            dispatcharrURL: baseURL,
            sourceId: sourceId,
            displayName: name,
            apiToken: apiToken
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

    /// Add a Plex Live TV source
    func addPlexSource(provider: any LiveTVProvider) async {
        providers[provider.sourceId] = provider
        saveSources()
        await updateSourceInfo()
    }

    /// Remove a source by ID
    func removeSource(id: String) async {
        providers.removeValue(forKey: id)
        saveSources()
        await updateSourceInfo()

        // Remove channels from this source
        channels.removeAll { $0.sourceId == id }

        // Remove EPG for these channels
        let channelIds = Set(channels.filter { $0.sourceId == id }.map { $0.id })
        for channelId in channelIds {
            epg.removeValue(forKey: channelId)
        }

    }

    // MARK: - Source Persistence

    /// Load saved source configurations and recreate providers
    private func loadSavedSources() {
        guard let data = userDefaults.data(forKey: sourcesKey),
              let configs = try? JSONDecoder().decode([SourceConfiguration].self, from: data) else {
            print("📺 LiveTVDataStore: No saved sources found")
            return
        }

        for config in configs {
            switch config.type {
            case "dispatcharr":
                if let urlString = config.baseURL, let url = URL(string: urlString) {
                    let provider = IPTVProvider(
                        dispatcharrURL: url,
                        sourceId: config.id,
                        displayName: config.name,
                        apiToken: config.apiToken
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
                        apiToken: iptvProvider.apiToken
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

    /// Update source info for UI
    private func updateSourceInfo() async {
        var infos: [LiveTVSourceInfo] = []

        for (id, provider) in providers {
            let isConnected = await provider.isConnected
            let channelCount = channels.filter { $0.sourceId == id }.count

            infos.append(LiveTVSourceInfo(
                id: id,
                sourceType: provider.sourceType,
                displayName: provider.displayName,
                channelCount: channelCount,
                isConnected: isConnected,
                lastSync: nil  // TODO: Track last sync time
            ))
        }

        sources = infos.sorted { $0.displayName < $1.displayName }
    }

    // MARK: - Channel Loading

    /// Load channels from all sources
    func loadChannels() async {
        guard !providers.isEmpty else {
            return
        }

        // Cancel existing task if any
        channelLoadTask?.cancel()

        isLoadingChannels = true
        channelsError = nil

        channelLoadTask = Task {
            var allChannels: [UnifiedChannel] = []
            var errors: [String] = []

            // Fetch from all providers in parallel
            await withTaskGroup(of: (String, Result<[UnifiedChannel], Error>).self) { group in
                for (id, provider) in providers {
                    group.addTask {
                        do {
                            let channels = try await provider.fetchChannels()
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

            await MainActor.run {
                self.channels = allChannels
                self.isLoadingChannels = false
                if !errors.isEmpty {
                    self.channelsError = errors.joined(separator: "\n")
                }
            }

            await updateSourceInfo()
        }

        await channelLoadTask?.value
    }

    /// Refresh channels from all sources
    func refreshChannels() async {
        guard !providers.isEmpty else { return }

        isLoadingChannels = true
        channelsError = nil

        var allChannels: [UnifiedChannel] = []
        var errors: [String] = []

        // Refresh from all providers in parallel
        await withTaskGroup(of: (String, Result<[UnifiedChannel], Error>).self) { group in
            for (id, provider) in providers {
                group.addTask {
                    do {
                        let channels = try await provider.refreshChannels()
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
                }
            }
        }

        // Sort channels
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

        channels = allChannels
        isLoadingChannels = false
        if !errors.isEmpty {
            channelsError = errors.joined(separator: "\n")
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

        epgLoadTask = Task {
            var allEPG: [String: [UnifiedProgram]] = [:]
            var issues: [EPGFetchIssue] = []

            // Group channels by source
            let channelsBySource = Dictionary(grouping: channels, by: { $0.sourceId })

            // Fetch EPG from each provider
            await withTaskGroup(of: (String, Result<[String: [UnifiedProgram]], Error>).self) { group in
                for (sourceId, sourceChannels) in channelsBySource {
                    guard let provider = providers[sourceId] else {
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
                self.applyXMLTVChannelLogos(finalLogos)
            }
        }

        await epgLoadTask?.value
    }

    /// Fills in channel artwork from XMLTV `<channel><icon>` logos for any
    /// channel that didn't get a logo from its M3U `tvg-logo`.
    private func applyXMLTVChannelLogos(_ logos: [String: URL]) {
        guard !logos.isEmpty else { return }
        var didChange = false
        let updated = channels.map { channel -> UnifiedChannel in
            guard channel.logoURL == nil, let logo = logos[channel.id] else { return channel }
            didChange = true
            return UnifiedChannel(
                id: channel.id,
                sourceType: channel.sourceType,
                sourceId: channel.sourceId,
                channelNumber: channel.channelNumber,
                name: channel.name,
                callSign: channel.callSign,
                logoURL: logo,
                streamURL: channel.streamURL,
                tvgId: channel.tvgId,
                groupTitle: channel.groupTitle,
                isHD: channel.isHD
            )
        }
        if didChange { channels = updated }
    }

    /// Converts a thrown EPG fetch error into a short, user-readable phrase
    /// for the guide banner. Keep these deliberately concrete — "EPG server
    /// returned HTTP 404" tells the user where to look, whereas the raw
    /// `error.localizedDescription` is often opaque.
    static func shortEPGFailureReason(for error: Error) -> String {
        if let xmltv = error as? XMLTVParseError {
            switch xmltv {
            case .httpError(let code):
                return "EPG server returned HTTP \(code)"
            case .parseFailed:
                return "EPG data could not be parsed"
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
                await MainActor.run {
                    self.isEPGPreloaded = true
                }
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
            isEPGPreloaded = true
        }
    }

    // MARK: - Program Helpers

    /// Get the current program for a channel
    func getCurrentProgram(for channel: UnifiedChannel) -> UnifiedProgram? {
        guard let programs = epg[channel.id] else { return nil }
        let now = Date()
        return programs.first { $0.startTime <= now && $0.endTime > now }
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

    // MARK: - Favorites

    func toggleFavorite(_ channel: UnifiedChannel) {
        if favoriteIds.contains(channel.id) {
            favoriteIds.remove(channel.id)
        } else {
            favoriteIds.insert(channel.id)
        }
    }

    func isFavorite(_ channel: UnifiedChannel) -> Bool {
        favoriteIds.contains(channel.id)
    }

    private func loadFavorites() {
        if let saved = userDefaults.array(forKey: favoritesKey) as? [String] {
            favoriteIds = Set(saved)
        }
    }

    private func saveFavorites() {
        userDefaults.set(Array(favoriteIds), forKey: favoritesKey)
    }

    // MARK: - Stream URL

    /// Build the stream URL for a channel
    /// Resolve a PLAYABLE stream URL, performing any provider-side session
    /// setup first (Plex cloud-EPG/DVB channels need a tune before the
    /// transcoder will serve them). Prefer this over `buildStreamURL(for:)`
    /// at playback time; the sync variant remains for availability checks.
    func resolveStreamURL(for channel: UnifiedChannel) async -> URL? {
        guard let provider = providers[channel.sourceId] else {
            return channel.streamURL
        }
        return await provider.resolveStreamURL(for: channel)
    }

    func buildStreamURL(for channel: UnifiedChannel) -> URL? {
        guard let provider = providers[channel.sourceId] else {
            // No provider found - fallback to channel's embedded stream URL
            let breadcrumb = Breadcrumb(level: .info, category: "livetv_stream")
            breadcrumb.message = "Using channel's embedded stream URL (no provider)"
            breadcrumb.data = [
                "channel_name": channel.name,
                "channel_id": channel.id,
                "source_id": channel.sourceId,
                "source_type": String(describing: channel.sourceType),
                "has_stream_url": channel.streamURL != nil
            ]
            SentryBridge.addBreadcrumb(breadcrumb)
            return channel.streamURL
        }

        let url = provider.buildStreamURL(for: channel)

        // Log stream URL build result (GitHub #64 - DVB diagnostics)
        if let url = url {
            let successBreadcrumb = Breadcrumb(level: .info, category: "livetv_stream")
            successBreadcrumb.message = "Stream URL built successfully"
            successBreadcrumb.data = [
                "channel_name": channel.name,
                "channel_id": channel.id,
                "source_id": channel.sourceId,
                "source_type": String(describing: channel.sourceType),
                "stream_type": url.path.contains("/transcode/") ? "plex_transcode" : (url.path.contains("/live/") ? "iptv" : "direct"),
                "url_host": url.host ?? "unknown",
                "url_path": url.path
            ]
            SentryBridge.addBreadcrumb(successBreadcrumb)
        } else {
            let breadcrumb = Breadcrumb(level: .warning, category: "livetv_stream")
            breadcrumb.message = "Provider returned nil stream URL"
            breadcrumb.data = [
                "channel_name": channel.name,
                "channel_id": channel.id,
                "source_id": channel.sourceId,
                "source_type": String(describing: channel.sourceType),
                "embedded_stream_url": channel.streamURL?.absoluteString ?? "none"
            ]
            SentryBridge.addBreadcrumb(breadcrumb)
        }

        return url
    }

    // MARK: - Reset

    func reset() {
        channelLoadTask?.cancel()
        epgLoadTask?.cancel()
        providers.removeAll()
        channels = []
        epg = [:]
        sources = []
        channelsError = nil
        epgIssues = []
        isLoadingChannels = false
        isLoadingEPG = false
    }
}
