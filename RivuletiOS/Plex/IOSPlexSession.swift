// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  IOSPlexSession.swift
//  Rivulet iOS
//
//  The iOS content store and view-facing facade over the SHARED Plex stack:
//  PlexAuthManager owns identity (PIN flow, server selection, tokens) and
//  PlexNetworkManager owns every request. This file holds no endpoint
//  knowledge; it shapes shared results for the iOS views and caches what is
//  expensive to re-resolve (clear logos). The one exception is the playback
//  URL (direct, or a capped transcode from the shared builder), which iOS
//  composes here because iOS has no ContentRouter. Content
//  fetches live in IOSPlexSession+Content.swift.
//
//  It exists for the same reason PlexDataStore does on tvOS: the auth manager
//  hands off to "whatever holds content" through PlexAuthManager.onAuthenticated
//  / .onSignedOut, and this is that object on iOS.
//

import Combine
import Foundation

@MainActor
final class IOSPlexSession: ObservableObject {
    enum State: Equatable {
        case signedOut
        case requestingPIN
        case waitingForPIN
        case findingServers
        case selectingServer
        case connected
        case failed(String)
    }

    @Published private(set) var state: State = .signedOut
    @Published private(set) var pinCode: String?
    @Published private(set) var authenticationURL: URL?
    @Published private(set) var availableServers: [PlexDevice] = []
    @Published private(set) var libraries: [PlexLibrary] = []
    /// Home rows after Continue Watching: promoted hubs of the pinned libraries.
    @Published private(set) var shelves: [PlexHub] = []
    @Published private(set) var continueWatching: PlexHub?
    @Published private(set) var isLoadingContent = false
    @Published private(set) var contentError: String?
    /// Bumped after a watched-state change so open grids and detail pages reload.
    @Published private(set) var watchStateRevision = 0
    /// Bumped on a server or profile switch; the tab stacks rebuild on it.
    @Published private(set) var sessionGeneration = 0
    @Published private(set) var selectedServerName: String?
    @Published private(set) var profileImageURL: URL?
    @Published private(set) var profileDisplayName: String?

    let auth = PlexAuthManager.shared
    let network = PlexNetworkManager.shared
    private var lastContentRefresh: Date?
    private var refreshGeneration = 0
    /// Last good hubs per pinned library, kept when a later fetch of one fails.
    private var libraryHubs: [String: [PlexHub]] = [:]
    private var libraryHubsSession: (serverURL: String, token: String)?
    private var cancellables = Set<AnyCancellable>()
    private var logoURLCache: [String: URL] = [:]
    private var missingLogoKeys = Set<String>()
    private var logoResolutionTasks: [String: Task<URL?, Never>] = [:]

    init() {
        // The auth manager owns identity and hands content off to the host's
        // store: on iOS, this object. Mirrors RivuletApp.init on tvOS.
        PlexAuthManager.onAuthenticated = { [weak self] in await self?.refresh() }
        PlexAuthManager.onSignedOut = { [weak self] in self?.clearContent() }

        auth.$state
            .sink { [weak self] in self?.apply(authState: $0) }
            .store(in: &cancellables)
        auth.$username
            .sink { [weak self] in self?.profileDisplayName = $0 }
            .store(in: &cancellables)
        auth.$userThumbURL
            .sink { [weak self] in self?.profileImageURL = $0 }
            .store(in: &cancellables)

        if isConfigured {
            state = .connected
            Task { await refresh() }
        } else if auth.isAuthenticated {
            // Token but no server: a sign-in that never finished picking one.
            Task { await auth.resumeServerSelection() }
        }
    }

    var isConfigured: Bool {
        auth.selectedServerURL != nil && auth.selectedServerToken != nil
    }

    // MARK: - Auth (delegated)

    func cancelSignIn() { auth.cancelAuthentication() }

    func selectServer(_ server: PlexDevice) async { await auth.selectServer(server) }

    func signOut() {
        // clearContent() runs via the onSignedOut handoff.
        auth.signOut()
    }

    /// Maps the shared auth state machine onto the iOS view states.
    ///
    /// `@Published` emits on willSet, so `auth.state` still holds the OLD
    /// value inside this sink. Everything needed must come from the emitted
    /// value or from properties the manager assigns BEFORE flipping state
    /// (selectedServerURL/token are, by the atomic-flip rule in selectServer).
    private func apply(authState: PlexAuthState) {
        switch authState {
        case .idle:
            pinCode = nil
            authenticationURL = nil
            state = isConfigured ? .connected : .signedOut
        case .requestingPin:
            state = .requestingPIN
        case .waitingForPIN(let code, _):
            pinCode = code
            authenticationURL = Self.authenticationURL(code: code)
            state = .waitingForPIN
        case .authenticated:
            pinCode = nil
            authenticationURL = nil
            selectedServerName = auth.selectedServer?.name ?? auth.savedServerName
            // Content loads through the onAuthenticated handoff; between the
            // token arriving and a server being picked there is nothing to show.
            state = isConfigured ? .connected : .findingServers
        case .selectingServer(let servers):
            availableServers = servers
            state = .selectingServer
        case .error(let message):
            state = .failed(message)
        }
    }

    /// Same link the shared manager's `authURL` builds, computed from the
    /// emitted PIN code because inside a willSet sink the manager's own
    /// `state` (which `authURL` reads) has not been assigned yet.
    private static func authenticationURL(code: String) -> URL? {
        var components = URLComponents(string: "https://app.plex.tv/auth")
        components?.fragment = "?clientID=\(PlexAPI.clientIdentifier)&code=\(code)&context[device][product]=\(PlexAPI.productName)"
        return components?.url
    }

    // MARK: - Content

    func refresh() async {
        guard let session = try? configuration() else { return }
        refreshGeneration += 1
        let generation = refreshGeneration
        // A newer refresh, a sign-out or a server/profile switch owns the UI once this one returns.
        func isCurrent() -> Bool {
            generation == refreshGeneration && (try? configuration()).map { $0 == session } == true
        }
        isLoadingContent = true
        defer { if generation == refreshGeneration { isLoadingContent = false } }
        do {
            let home = try await fetchHome()
            guard isCurrent() else { return }
            if libraryHubsSession.map({ $0 != session }) ?? true {
                libraryHubs = [:]
                continueWatching = nil
                libraryHubsSession = session
            }
            libraries = home.libraries
            if let cw = home.continueWatching { continueWatching = cw }
            let pinned = home.libraries.filter(\.isPinnedToHome)
            libraryHubs = Dictionary(uniqueKeysWithValues: pinned.compactMap { library in
                (home.hubsByLibrary[library.key] ?? libraryHubs[library.key]).map { (library.key, $0) }
            })
            shelves = pinned.flatMap { libraryHubs[$0.key] ?? [] }.filter {
                $0.promoted == true && !$0.isContinueWatching && !$0.items.isEmpty
            }
            selectedServerName = auth.selectedServer?.name ?? auth.savedServerName
            contentError = nil
            lastContentRefresh = .now
            state = .connected
        } catch let error where isCancellationError(error) {
            return
        } catch {
            guard isCurrent() else { return }
            contentError = error.localizedDescription
            return await PlexWatchlistService.shared.fetchWatchlist()
        }
        await PlexWatchlistService.shared.fetchWatchlist()
        // The server answered: send progress made offline, then repaint with it.
        if await flushOfflineProgress() { Task { await watchStateDidChange() } }
    }

    /// Foreground return: refetch only when Home is more than five minutes old.
    func refreshIfStale() async {
        guard let lastContentRefresh, Date.now.timeIntervalSince(lastContentRefresh) > 300 else { return }
        await refresh()
    }

    /// A server or profile switch: open pages belong to the old one, so the tab stacks reset.
    func contentSessionChanged() { sessionGeneration += 1 }

    /// Called after playback or a watched toggle: repaint open pages, then Home.
    func watchStateDidChange() async {
        watchStateRevision += 1
        await refresh()
    }

    // MARK: - Artwork

    /// Which artwork a call site wants. Three distinct shapes, so this is an
    /// enum rather than flags: `.thumb` on an episode is a 16:9 still, while
    /// `.poster` on the same episode is its show's 2:3 poster. Picking the
    /// wrong one letterboxes or crops every tile in the rail.
    enum ArtworkKind {
        /// 2:3 tile art. Episodes resolve to the show poster (tvOS `PosterCell`).
        case poster
        /// The item's own image. 16:9 for episodes, square for music.
        case thumb
        /// Wide background art.
        case backdrop
    }

    func artworkURL(for item: PlexMetadata, kind: ArtworkKind = .thumb, width: Int = 900, height: Int = 1350) -> URL? {
        let path: String? = switch kind {
        case .poster:
            item.posterPath
        case .thumb:
            item.thumb
        case .backdrop:
            item.type == "episode"
                ? (item.grandparentArt ?? item.art ?? item.thumb)
                : (item.art ?? item.thumb)
        }
        return imageURL(path: path, width: width, height: height)
    }

    /// Photo-transcoder URL at the given pixel size. Also takes absolute
    /// URLs (cast photos live on metadata-static.plex.tv).
    func imageURL(path: String?, width: Int, height: Int) -> URL? {
        guard let path, !path.isEmpty, let (serverURL, token) = try? configuration() else { return nil }
        return network.buildThumbnailURL(
            serverURL: serverURL,
            authToken: token,
            thumbPath: path,
            width: width,
            height: height
        )
    }

    /// Resolves the same logo source as tvOS: episodes use their show's full
    /// metadata, while movies and shows use their own. Hub responses omit the
    /// Image array, so results (including misses) are cached per source key.
    func logoURL(for item: PlexMetadata) async -> URL? {
        guard let (serverURL, token) = try? configuration() else { return nil }
        let sourceKey: String?
        switch item.type {
        case "episode":
            sourceKey = item.grandparentRatingKey
        case "season":
            sourceKey = item.parentRatingKey ?? item.ratingKey
        default:
            sourceKey = item.ratingKey
        }
        guard let sourceKey else { return nil }
        // Rating keys repeat across servers, so the cache is per server.
        let cacheKey = "\(serverURL)|\(sourceKey)"

        if let cached = logoURLCache[cacheKey] { return cached }
        if missingLogoKeys.contains(cacheKey) { return nil }

        if item.type != "episode", item.type != "season",
           let direct = Self.directResourceURL(serverURL: serverURL, token: token, path: item.clearLogoPath) {
            logoURLCache[cacheKey] = direct
            return direct
        }

        if let existing = logoResolutionTasks[cacheKey] {
            return await existing.value
        }

        let task = Task<URL?, Never> { [network] in
            guard let metadata = try? await network.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: sourceKey
            ) else { return nil }
            return Self.directResourceURL(serverURL: serverURL, token: token, path: metadata.clearLogoPath)
        }
        logoResolutionTasks[cacheKey] = task
        let resolved = await task.value
        logoResolutionTasks[cacheKey] = nil
        if let resolved {
            logoURLCache[cacheKey] = resolved
        } else {
            missingLogoKeys.insert(cacheKey)
        }
        return resolved
    }

    /// The logo URL if `logoURL(for:)` already resolved it, so a view can draw it on its first frame.
    func cachedLogoURL(for item: PlexMetadata) -> URL? {
        guard let serverURL = auth.selectedServerURL,
              let sourceKey = item.type == "episode" ? item.grandparentRatingKey
                : item.type == "season" ? (item.parentRatingKey ?? item.ratingKey) : item.ratingKey
        else { return nil }
        return logoURLCache["\(serverURL)|\(sourceKey)"]
    }

    /// Resolves logos and downloads them with the art, in row order, four at a
    /// time, so cards scrolled into view are already complete. Each `art` must
    /// be the URL the card itself requests.
    func prefetchArtwork(_ jobs: [(item: PlexMetadata, art: URL?)]) async {
        await withTaskGroup(of: Void.self) { group in
            for (index, job) in jobs.enumerated() {
                if Task.isCancelled { break }
                if index >= 4 { await group.next() }
                group.addTask {
                    if let logo = await self.logoURL(for: job.item) { _ = await IOSArtworkCache.shared.image(for: logo) }
                    if let art = job.art { _ = await IOSArtworkCache.shared.image(for: art) }
                }
            }
        }
    }

    /// Direct, authenticated URL for transparent assets such as clear logos.
    /// The photo transcoder can flatten their alpha channel, so these skip it.
    private static func directResourceURL(serverURL: String, token: String, path: String?) -> URL? {
        guard let path, !path.isEmpty,
              let base = URL(string: serverURL),
              let absolute = URL(string: path, relativeTo: base)?.absoluteURL,
              var components = URLComponents(url: absolute, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "X-Plex-Token" }) {
            queryItems.append(URLQueryItem(name: "X-Plex-Token", value: token))
        }
        components.queryItems = queryItems
        return components.url
    }

    // MARK: - Playback

    /// `quality` overrides the Home or Away setting; `previous` lends its fresh throughput reading.
    func playback(
        for item: PlexMetadata,
        quality: StreamingQuality? = nil,
        previous: IOSPlexPlaybackRequest? = nil
    ) async throws -> IOSPlexPlaybackRequest {
        // A downloaded item plays its file everywhere, online or not.
        // Up Next after a download stays on that download's server.
        if let local = IOSDownloadCenter.shared.localPlayback(for: item, serverID: previous?.downloadServerID) { return local }
        let full = try await metadata(for: item)
        let (serverURL, token) = try configuration()
        guard full.streamKey != nil else { throw IOSPlexSessionError.noPlayableURL }

        var markers = full.Marker ?? []
        if UserDefaults.standard.bool(forKey: "useIntroDB"),
           full.type == "episode",
           let showKey = full.grandparentRatingKey,
           let season = full.parentIndex,
           let episode = full.index {
            // The show's IMDb id lives on the SHOW's guids; an episode's own
            // Guid array carries episode-level ids that IntroDB rejects.
            let show = try? await network.getMetadata(
                serverURL: serverURL,
                authToken: token,
                ratingKey: showKey,
                includeGuids: true
            )
            let guidStrings = (show?.Guid ?? []).compactMap(\.id) + [show?.guid].compactMap { $0 }
            if let imdbID = guidStrings.compactMap(PlexMetadata.extractImdbId(from:)).first {
                let community = await IntroDBClient().markers(imdbID: imdbID, season: season, episode: episode)
                let existingKinds = Set(markers.compactMap(\.type))
                markers.append(contentsOf: community.filter { marker in
                    guard let type = marker.type else { return false }
                    return !existingKinds.contains(type)
                })
            }
        }

        let resume = full.resumeSeconds
        let resumes = full.durationSeconds > 0
            ? WatchProgressPolicy.hasResumePoint(offsetSeconds: resume, runtimeSeconds: full.durationSeconds)
            : WatchProgressPolicy.hasResumePoint(offsetSeconds: resume)
        return try await stream(
            full,
            markers: markers.sorted { ($0.startTimeOffset ?? 0) < ($1.startTimeOffset ?? 0) },
            serverURL: serverURL,
            token: token,
            version: .best,
            quality: quality,
            plan: nil,
            measurement: previous?.freshMeasurement,
            startTime: resumes ? resume : nil
        )
    }

    /// The playing title again at `time`, keeping its version. `plan` skips the
    /// decision (a step-down, a fallback, or a track change that keeps its step).
    func playback(
        reloading request: IOSPlexPlaybackRequest,
        quality: StreamingQuality,
        plan: StreamPlan? = nil,
        at time: TimeInterval
    ) async throws -> IOSPlexPlaybackRequest {
        // `item.Media` leads with the playing version; the transcoder wants its server index.
        var item = request.item
        if var media = item.Media, media.indices.contains(request.mediaIndex) {
            media.insert(media.removeFirst(), at: request.mediaIndex)
            item.Media = media
        }
        return try await stream(
            item,
            markers: request.markers,
            serverURL: request.serverURL,
            token: request.token,
            version: request.item.Media?.first.map { .source("\($0.id)") } ?? .best,
            quality: quality,
            plan: plan,
            measurement: request.freshMeasurement,
            startTime: time > 1 ? time : nil
        )
    }

    /// Picks the version and Original vs a capped transcode, then builds the URL.
    private func stream(
        _ full: PlexMetadata,
        markers: [PlexMarker],
        serverURL: String,
        token: String,
        version: VersionChoice,
        quality: StreamingQuality?,
        plan forced: StreamPlan?,
        measurement: (kbps: Int?, at: Date)?,
        startTime: TimeInterval?
    ) async throws -> IOSPlexPlaybackRequest {
        let isRelay = PlexRelay.isRelayURL(serverURL)
        let quality = quality ?? StreamingQuality.setting(home: StreamingQuality.isHome(serverURL: serverURL))
        let media = full.Media ?? []
        var measurement = measurement
        if forced == nil, measurement == nil, QualityDecision.needsProbe(setting: quality, isRelay: isRelay),
           let key = VersionRanking.select(version, in: media).media.first?.Part?.first?.key,
           let probeURL = Self.directPlayURL(serverURL: serverURL, token: token, partKey: key) {
            // Detached: the probe's read loop must not run on the main actor.
            let kbps = await ThroughputProbe.measure(url: probeURL)
            measurement = (kbps, Date())
        }
        let cap = forced.map { $0.step?.kbps } ?? QualityDecision.capKbps(
            setting: quality, measuredKbps: measurement?.kbps, isRelay: isRelay)
        let selection = VersionRanking.select(version, in: media, capKbps: cap)
        var item = full
        if !selection.media.isEmpty { item.Media = selection.media }
        let chosen = selection.media.first
        let plan = forced ?? QualityDecision.decide(
            setting: quality, sourceKbps: chosen?.sourceKbps, measuredKbps: measurement?.kbps, isRelay: isRelay
        )

        let url: URL
        let headers: [String: String]
        var sessionID: String?
        switch plan {
        case .original:
            guard let key = chosen?.Part?.first?.key,
                  let direct = Self.directPlayURL(serverURL: serverURL, token: token, partKey: key) else {
                throw IOSPlexSessionError.noPlayableURL
            }
            url = direct
            headers = Self.playbackHeaders(token: token)
        case .transcode(let step):
            guard let ratingKey = full.ratingKey,
                  let built = network.buildHLSDirectPlayURL(
                    serverURL: serverURL,
                    authToken: token,
                    ratingKey: ratingKey,
                    mediaIndex: selection.serverIndex,
                    offsetMs: Int((startTime ?? 0) * 1000),
                    useDolbyVision: false,
                    forceVideoTranscode: true,
                    step: step
                  ) else {
                throw IOSPlexSessionError.noPlayableURL
            }
            url = built.url
            headers = built.headers
            sessionID = URLComponents(url: built.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "session" }?.value
        }

        return IOSPlexPlaybackRequest(
            item: item,
            url: url,
            headers: headers,
            markers: markers,
            serverURL: serverURL,
            token: token,
            quality: quality,
            plan: plan,
            sourceKbps: chosen?.sourceKbps,
            mediaIndex: selection.serverIndex,
            transcodeSessionID: sessionID,
            measuredKbps: measurement?.kbps,
            measuredAt: measurement?.at,
            startTime: startTime
        )
    }

    func reportProgress(for request: IOSPlexPlaybackRequest, time: TimeInterval, state: String) async {
        guard let key = request.item.ratingKey else { return }
        let at = Date()
        let offsetMs = Int(time * 1000)
        if request.isLocal {
            IOSDownloadCenter.shared.noteProgress(ratingKey: key, serverID: request.downloadServerID, offsetMs: offsetMs, watched: false, persist: state != "playing")
        }
        guard !request.serverURL.isEmpty else { return }
        do {
            try await network.reportProgress(
                serverURL: request.serverURL,
                authToken: request.token,
                ratingKey: key,
                timeMs: offsetMs,
                state: state,
                duration: request.item.duration
            )
            IOSOfflineProgress.reached(key, at: at)
        } catch {
            IOSOfflineProgress.failed(key, offsetMs: offsetMs, durationMs: request.item.duration, watched: false, at: at)
        }
    }

    private static func directPlayURL(serverURL: String, token: String, partKey: String) -> URL? {
        guard let base = URL(string: serverURL),
              var components = URLComponents(url: base.appending(path: partKey), resolvingAgainstBaseURL: false) else {
            return nil
        }
        var query = components.queryItems ?? []
        query.append(URLQueryItem(name: "X-Plex-Token", value: token))
        query.append(URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier))
        query.append(URLQueryItem(name: "X-Plex-Platform", value: PlexAPI.platform))
        query.append(URLQueryItem(name: "X-Plex-Product", value: PlexAPI.productName))
        components.queryItems = query
        return components.url
    }

    private static func playbackHeaders(token: String) -> [String: String] {
        [
            "X-Plex-Token": token,
            "X-Plex-Client-Identifier": PlexAPI.clientIdentifier,
            "X-Plex-Platform": PlexAPI.platform,
            "X-Plex-Product": PlexAPI.productName,
            "User-Agent": "\(PlexAPI.productName)/\(PlexAPI.platform)",
            "X-Playback-Session-Id": UUID().uuidString
        ]
    }

    // MARK: - Private

    private func clearContent() {
        libraries = []
        shelves = []
        continueWatching = nil
        contentError = nil
        lastContentRefresh = nil
        PlexWatchlistService.shared.reset()
        availableServers = []
        selectedServerName = nil
        libraryHubs = [:]
        libraryHubsSession = nil
        logoURLCache = [:]
        missingLogoKeys = []
        logoResolutionTasks.values.forEach { $0.cancel() }
        logoResolutionTasks = [:]
    }

    func configuration() throws -> (serverURL: String, token: String) {
        guard let serverURL = auth.selectedServerURL, let token = auth.selectedServerToken else {
            throw IOSPlexSessionError.notConfigured
        }
        return (serverURL, token)
    }
}

nonisolated struct IOSPlexPlaybackRequest: Identifiable, Sendable {
    var id: String { item.id }
    let item: PlexMetadata
    let url: URL
    let headers: [String: String]
    let markers: [PlexMarker]
    let serverURL: String
    let token: String
    /// The choice that produced this request; `plan` is what it plays as.
    var quality: StreamingQuality
    let plan: StreamPlan
    let sourceKbps: Int?
    /// The playing version's index in the server's Media order.
    let mediaIndex: Int
    /// The Plex transcode session to stop when this request is replaced.
    let transcodeSessionID: String?
    var measuredKbps: Int?
    var measuredAt: Date?
    let startTime: TimeInterval?
    /// Set for a downloaded file: its saved subtitles and poster.
    var localSidecars: [AetherPlayer.SidecarSubtitle]? = nil
    var localArtworkURL: URL? = nil
    /// The server a downloaded file came from, which may not be the current one.
    var downloadServerID: String? = nil

    /// A throughput reading young enough for Up Next and reloads to reuse.
    var freshMeasurement: (kbps: Int?, at: Date)? {
        guard let measuredAt, Date().timeIntervalSince(measuredAt) < 600 else { return nil }
        return (measuredKbps, measuredAt)
    }
}

nonisolated enum IOSPlexSessionError: LocalizedError {
    case notConfigured
    case noPlayableURL
    case watchlistUnavailable

    var errorDescription: String? {
        switch self {
        case .notConfigured: "No Plex server is connected."
        case .noPlayableURL: "This item has no playable file."
        case .watchlistUnavailable: "Couldn't update your Watchlist."
        }
    }
}
