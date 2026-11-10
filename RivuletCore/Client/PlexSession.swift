// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexSession.swift
//  Rivulet
//
//  Plex sign-in, profile and server choice for the phone and desktop apps, plus the Plex playback pieces
//  (iOS has no ContentRouter, so this composes the playback URL). What the browse screens
//  show lives in BrowseStore, over MediaProviderRegistry.
//

import Combine
import Foundation

@MainActor
final class PlexSession: ObservableObject {
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
    /// What the browse screens show, for every server.
    let browse = BrowseStore()
    @Published private(set) var selectedServerName: String?
    @Published private(set) var profileImageURL: URL?
    @Published private(set) var profileDisplayName: String?

    let auth = PlexAuthManager.shared
    let network = PlexNetworkManager.shared
    private var cancellables = Set<AnyCancellable>()
    /// The registry is being rebuilt by `authChanged()`, which refreshes itself.
    private var repopulating = false
    private var secondaryIDs: [String] = []

    init() {
        // The auth manager owns identity and hands content off to the host's
        // store: on iOS, this object. Mirrors RivuletApp.init on tvOS.
        PlexAuthManager.onAuthenticated = { [weak self] in
            PlexExtraServers.shared.refreshForAccount()
            await self?.authChanged()
        }
        PlexAuthManager.onSignedOut = { [weak self] in
            PlexExtraServers.shared.clear()
            self?.clearContent()
            // The registry drops the Plex servers, and Home shows whatever else is signed in.
            Task { await self?.authChanged() }
        }
        // The account's other Plex servers (#87): their list and tokens follow the profile.
        PlexExtraServers.onChanged = { [weak self] in Task { await self?.authChanged() } }
        PlexUserProfileManager.onProfileEntered = { token in
            Task { await PlexExtraServers.shared.refresh(plexToken: token) }
        }
        // Jellyfin and Emby sign in and out through the registry; follow it.
        secondaryIDs = MediaProviderRegistry.shared.secondaryProviders.map(\.id)
        MediaProviderRegistry.shared.onSecondaryProvidersChanged = { [weak self] providers in
            // The servers' Live TV follows every sign-in, sign-out and profile change (shared with tvOS).
            OtherServerKind.configureLiveTV(secondary: providers, restricted: PlexUserProfileManager.shared.isRestrictedProfile)
            guard let self else { return }
            let ids = providers.map(\.id)
            defer { secondaryIDs = ids }
            guard !repopulating, ids != secondaryIDs else { return }
            Task { await self.refresh() }
        }
        // The registry was filled before this ran, so the first pass is ours.
        OtherServerKind.configureLiveTV(restricted: PlexUserProfileManager.shared.isRestrictedProfile)
        // Progress logged while the server was unreachable goes out once it answers.
        browse.afterRefresh = { [weak self] in
            guard let self, await flushOfflineProgress() else { return }
            Task { await self.watchStateDidChange() }
        }

        auth.$state
            .sink { [weak self] in self?.apply(authState: $0) }
            .store(in: &cancellables)
        auth.$username
            .sink { [weak self] in self?.profileDisplayName = $0 }
            .store(in: &cancellables)
        auth.$userThumbURL
            .sink { [weak self] in self?.profileImageURL = $0 }
            .store(in: &cancellables)

        // Signed in with a server but no content token means a Home profile has
        // to be entered first; `verifyConnection` does that, then content loads.
        if isConfigured {
            state = .connected
            PlexExtraServers.shared.refreshForAccount()
        }
        Task { await refresh() }
    }

    /// Signed in with a server chosen. Content may still wait on a Home profile.
    var isSignedIn: Bool { auth.isAuthenticated }

    /// Signed in and holding a content token, so content can load.
    var isConfigured: Bool {
        auth.selectedServerURL != nil && auth.selectedServerToken != nil
    }

    // MARK: - Auth (delegated)

    func cancelSignIn() { auth.cancelAuthentication() }

    func selectServer(_ server: PlexDevice) async { await auth.selectServer(server) }

    func signOut(scope: SignOutScope? = nil) {
        // clearContent() runs via the onSignedOut handoff.
        auth.signOut(scope: scope)
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
            state = isSignedIn ? .connected : .signedOut
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
            state = isSignedIn ? .connected : .findingServers
        case .selectingServer(let servers):
            availableServers = servers
            state = .selectingServer
        case .error(let message):
            state = .failed(message)
        }
    }

    /// The shared manager's link page, built from the emitted PIN code because
    /// inside a willSet sink the manager's own `state` (which its `linkURL`
    /// reads) has not been assigned yet.
    private static func authenticationURL(code: String) -> URL? {
        PlexAuthManager.linkURL(code: code)
    }

    // MARK: - Content

    /// Pull to refresh and the stale-return refresh.
    func refresh() async {
        await browse.refresh()
        selectedServerName = auth.selectedServer?.name ?? auth.savedServerName
    }

    /// Plex sign-in, profile, server or connection changed: the registry's providers follow, then Home.
    func authChanged() async {
        repopulating = true
        MediaProviderRegistry.shared.populateFromCurrentAuth()
        repopulating = false
        await refresh()
    }

    func contentSessionChanged() { browse.contentSessionChanged() }

    /// Called after playback or a watched toggle: repaint open pages, then Home.
    func watchStateDidChange() async { await browse.watchStateDidChange() }

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
        return imageURL(path: path, width: width, height: height, serverID: item.serverID)
    }

    /// Photo-transcoder URL at the given pixel size, on `serverID`'s server (nil:
    /// the selected one). Also takes absolute URLs (cast photos live on metadata-static.plex.tv).
    func imageURL(path: String?, width: Int, height: Int, serverID: String? = nil) -> URL? {
        guard let path, !path.isEmpty, let (serverURL, token) = try? configuration(serverID: serverID) else { return nil }
        return network.buildThumbnailURL(
            serverURL: serverURL,
            authToken: token,
            thumbPath: path,
            width: width,
            height: height
        )
    }

    // MARK: - Playback

    /// `quality` overrides the Home or Away setting; `previous` lends its fresh throughput reading;
    /// `startOffset` overrides the resume point.
    func playback(
        for item: PlexMetadata,
        fromBeginning: Bool = false,
        quality: StreamingQuality? = nil,
        previous: PlexPlaybackRequest? = nil,
        version: VersionChoice = .best,
        startOffset: TimeInterval? = nil
    ) async throws -> PlexPlaybackRequest {
        // A downloaded item plays its file everywhere, online or not.
        // Up Next after a download stays on that download's server.
        if var local = ClientHost.offline.localPlayback(
            for: item, serverID: item.serverID ?? previous?.downloadProviderID.flatMap(DownloadIdentity.plexMachineID(of:))) {
            if fromBeginning { local.startTime = nil }
            if let startOffset { local.startTime = startOffset }
            return local
        }
        let full = try await metadata(for: item)
        let (serverURL, token) = try configuration(serverID: full.serverID)
        guard full.streamKey != nil else { throw PlexSessionError.noPlayableURL }

        let markers = await PlexPlaybackMarkers.markers(for: full, serverURL: serverURL, token: token, network: network)

        let resume = full.resumeSeconds
        let resumes = full.durationSeconds > 0
            ? WatchProgressPolicy.hasResumePoint(offsetSeconds: resume, runtimeSeconds: full.durationSeconds)
            : WatchProgressPolicy.hasResumePoint(offsetSeconds: resume)
        return try await stream(
            full,
            markers: markers,
            serverURL: serverURL,
            token: token,
            version: version,
            quality: quality,
            plan: nil,
            measurement: previous?.freshMeasurement,
            startTime: startOffset ?? (resumes && !fromBeginning ? resume : nil)
        )
    }

    /// The playing title again at `time`, keeping its version. `plan` skips the
    /// decision (a step-down, a fallback, or a track change that keeps its step).
    func playback(
        reloading request: PlexPlaybackRequest,
        quality: StreamingQuality,
        plan: StreamPlan? = nil,
        at time: TimeInterval
    ) async throws -> PlexPlaybackRequest {
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
    ) async throws -> PlexPlaybackRequest {
        let isRelay = PlexRelay.isRelayURL(serverURL)
        let quality = quality ?? StreamingQuality.setting(home: StreamingQuality.isHome(serverURL: serverURL))
        let media = full.Media ?? []
        var measurement = measurement
        if forced == nil, measurement == nil, QualityDecision.needsProbe(setting: quality, isRelay: isRelay),
           let key = VersionRanking.select(version, in: media).media.first?.Part?.first?.key,
           let probeURL = Self.directPlayURL(serverURL: serverURL, token: token, partKey: key) {
            // Detached: the probe's read loop must not run on the main actor.
            let kbps = await ThroughputProbe.measure(
                url: probeURL, bytes: { try await PlexNetworkManager.shared.openEndedBytes(for: $0) })
            measurement = (kbps, Date())
        }
        let cap = forced.map { $0.step?.kbps } ?? QualityDecision.capKbps(
            setting: quality, measuredKbps: measurement?.kbps, isRelay: isRelay)
        let selection = VersionRanking.select(version, in: media, capKbps: cap)
        var item = full
        if !selection.media.isEmpty { item.Media = selection.media }
        let chosen = selection.media.first
        // A transcode would play only the first file of a stacked title (#399).
        let stacked = (chosen?.Part?.count ?? 0) > 1
        let plan = stacked ? .original : forced ?? QualityDecision.decide(
            setting: quality, sourceKbps: chosen?.sourceKbps, measuredKbps: measurement?.kbps, isRelay: isRelay
        )

        let url: URL
        let headers: [String: String]
        var sessionID: String?
        switch plan {
        case .original:
            guard let key = chosen?.Part?.first?.key,
                  let direct = Self.directPlayURL(serverURL: serverURL, token: token, partKey: key) else {
                throw PlexSessionError.noPlayableURL
            }
            url = direct
            headers = PlexProvider.directPlayHeaders(token: token)
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
                throw PlexSessionError.noPlayableURL
            }
            url = built.url
            headers = built.headers
            sessionID = URLComponents(url: built.url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "session" }?.value
        }

        return PlexPlaybackRequest(
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
            startTime: startTime,
            directPlaySessionID: sessionID == nil ? UUID().uuidString : nil
        )
    }

    /// Returns the server's reason when it has ended this play session (#403).
    @discardableResult
    func reportProgress(for request: PlexPlaybackRequest, time: TimeInterval, state: String) async -> String? {
        guard let key = request.item.ratingKey else { return nil }
        let at = Date()
        let offsetMs = Int(time * 1000)
        if request.isLocal {
            ClientHost.offline.noteProgress(for: request, offsetMs: offsetMs, watched: false, persist: state != "playing")
        }
        guard !request.serverURL.isEmpty else { return nil }
        do {
            let terminated = try await network.reportProgress(
                serverURL: request.serverURL,
                authToken: request.token,
                ratingKey: key,
                timeMs: offsetMs,
                state: state,
                duration: request.item.duration,
                sessionIdentifier: request.directPlaySessionID
            )
            if let owner = plexProviderID(of: request) { ClientHost.offline.progressReached(owner, itemID: key, at: at) }
            return terminated
        } catch {
            if let owner = plexProviderID(of: request) {
                ClientHost.offline.recordProgress(providerID: owner, itemID: key, offsetMs: offsetMs,
                                          durationMs: request.item.duration, watched: false, at: at)
            }
            return nil
        }
    }

    /// The download key of the Plex server a request reports to: a download's own server (its metadata
    /// carries none), else the item's, else the current one. Nil when no server is known.
    func plexProviderID(of request: PlexPlaybackRequest) -> String? {
        DownloadIdentity.reportingKey(isLocal: request.isLocal, downloadProviderID: request.downloadProviderID,
                                      itemServerID: request.item.serverID, currentMachineID: ClientHost.offline.currentServerID)
    }

    static func directPlayURL(serverURL: String, token: String, partKey: String) -> URL? {
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

    // MARK: - Private

    func clearContent() {
        browse.clearContent()
        availableServers = []
        selectedServerName = nil
    }

    func configuration() throws -> (serverURL: String, token: String) {
        guard let serverURL = auth.selectedServerURL, let token = auth.selectedServerToken else {
            throw PlexSessionError.notConfigured
        }
        return (serverURL, token)
    }

    /// The server an item, row or library lives on: another server's own address
    /// and token (#87), or the selected server's for nil.
    func configuration(serverID: String?) throws -> (serverURL: String, token: String) {
        guard let serverID else { return try configuration() }
        let extras = PlexExtraServers.shared
        guard let server = extras.current.first(where: { $0.machineID == serverID }),
              let token = extras.token(for: server) else { throw PlexSessionError.notConfigured }
        return (server.url, token)
    }
}

nonisolated struct PlexPlaybackRequest: Identifiable, Sendable {
    var id: String { item.id }
    var item: PlexMetadata
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
    var startTime: TimeInterval?
    /// The Plex play session a direct-play file's timeline carries, so the dashboard shows it (#423).
    var directPlaySessionID: String? = nil
    /// Set for a downloaded file: its saved subtitles and poster.
    var localSidecars: [SubtitleSidecar]? = nil
    var localArtworkURL: URL? = nil
    /// The server a downloaded file came from (`DownloadRecord.providerID`), which may not be the current one.
    var downloadProviderID: String? = nil
    /// Set for a Jellyfin or Emby item: `item` is then a display shim and this is the real stream.
    var providerPlayback: ProviderPlayback? = nil

    /// A throughput reading young enough for Up Next and reloads to reuse.
    var freshMeasurement: (kbps: Int?, at: Date)? {
        guard let measuredAt, Date().timeIntervalSince(measuredAt) < 600 else { return nil }
        return (measuredKbps, measuredAt)
    }
}

nonisolated enum PlexSessionError: LocalizedError {
    case notConfigured
    case noPlayableURL

    var errorDescription: String? {
        switch self {
        case .notConfigured: String(localized: "No Plex server is connected.")
        case .noPlayableURL: String(localized: "This item has no playable file.")
        }
    }
}
