// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

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
    @Published private(set) var availableServers: [IOSPlexServer] = []
    @Published private(set) var libraries: [IOSPlexLibrary] = []
    @Published private(set) var shelves: [IOSPlexShelf] = []
    @Published private(set) var isLoadingContent = false
    @Published private(set) var selectedServerName: String?
    @Published private(set) var profileImageURL: URL?
    @Published private(set) var profileDisplayName: String?

    private let api = IOSPlexAPI.shared
    private var authToken: String?
    private var serverToken: String?
    private var serverURL: URL?
    private var pollingTask: Task<Void, Never>?
    private var logoURLCache: [String: URL] = [:]
    private var missingLogoKeys = Set<String>()
    private var logoResolutionTasks: [String: Task<URL?, Never>] = [:]

    private let authTokenKey = "iosPlexAuthToken"
    private let serverTokenKey = "iosPlexServerToken"
    private let serverURLKey = "iosPlexServerURL"
    private let serverNameKey = "iosPlexServerName"

    init() {
        authToken = KeychainHelper.get(authTokenKey)
        serverToken = KeychainHelper.get(serverTokenKey)
        if let stored = UserDefaults.standard.string(forKey: serverURLKey) {
            serverURL = URL(string: stored)
        }
        selectedServerName = UserDefaults.standard.string(forKey: serverNameKey)

        if isConfigured {
            state = .connected
            Task { await refresh() }
            Task { await loadUserProfile() }
        }
    }

    var isConfigured: Bool { serverURL != nil && serverToken != nil }
    var isSignedIn: Bool { authToken != nil }

    func beginSignIn() async {
        pollingTask?.cancel()
        state = .requestingPIN
        pinCode = nil
        authenticationURL = nil
        do {
            let pin = try await api.requestPIN()
            pinCode = pin.code
            authenticationURL = api.authenticationURL(code: pin.code)
            state = .waitingForPIN
            pollingTask = Task { [weak self] in
                await self?.poll(pinID: pin.id)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func cancelSignIn() {
        pollingTask?.cancel()
        pollingTask = nil
        pinCode = nil
        authenticationURL = nil
        state = isConfigured ? .connected : .signedOut
    }

    func selectServer(_ server: IOSPlexServer) async {
        guard let authToken else { return }
        state = .findingServers
        clearLogoCache()
        let token = server.accessToken ?? authToken
        guard let url = await api.workingConnection(for: server, token: token) else {
            state = .failed(IOSPlexError.noReachableServer.localizedDescription)
            return
        }

        serverURL = url
        serverToken = token
        selectedServerName = server.name
        KeychainHelper.set(token, forKey: serverTokenKey)
        UserDefaults.standard.set(url.absoluteString, forKey: serverURLKey)
        UserDefaults.standard.set(server.name, forKey: serverNameKey)
        state = .connected
        availableServers = []
        await refresh()
    }

    func refresh() async {
        guard let serverURL, let serverToken else { return }
        isLoadingContent = true
        do {
            async let libraries = api.libraries(server: serverURL, token: serverToken)
            async let shelves = api.hubs(server: serverURL, token: serverToken)
            self.libraries = try await libraries.filter { ["movie", "show", "artist"].contains($0.type) }
            self.shelves = try await shelves
            state = .connected
        } catch {
            state = .failed(error.localizedDescription)
        }
        isLoadingContent = false
    }

    func items(in library: IOSPlexLibrary) async throws -> [IOSPlexItem] {
        let configuration = try configuration()
        return try await api.libraryItems(server: configuration.url, token: configuration.token, library: library)
    }

    func hubs(in library: IOSPlexLibrary) async throws -> [IOSPlexShelf] {
        let configuration = try configuration()
        return try await api.hubs(
            server: configuration.url,
            token: configuration.token,
            library: library
        )
    }

    func metadata(for item: IOSPlexItem) async throws -> IOSPlexItem {
        guard let key = item.ratingKey else { return item }
        let configuration = try configuration()
        return try await api.metadata(server: configuration.url, token: configuration.token, ratingKey: key)
    }

    func children(of item: IOSPlexItem) async throws -> [IOSPlexItem] {
        guard let key = item.ratingKey else { return [] }
        let configuration = try configuration()
        return try await api.children(server: configuration.url, token: configuration.token, ratingKey: key)
    }

    func search(_ query: String) async throws -> [IOSPlexItem] {
        let configuration = try configuration()
        return try await api.search(server: configuration.url, token: configuration.token, query: query)
    }

    func artworkURL(for item: IOSPlexItem, backdrop: Bool = false, width: Int = 900, height: Int = 1350) -> URL? {
        guard let serverURL, let serverToken else { return nil }
        let backdropPath: String? = if item.type == "episode" {
            item.grandparentArt ?? item.art ?? item.thumb
        } else {
            item.art ?? item.thumb
        }
        return api.artworkURL(
            server: serverURL,
            token: serverToken,
            path: backdrop ? backdropPath : item.thumb,
            width: width,
            height: height
        )
    }

    /// Resolves the same logo source as tvOS: episodes use their show's full
    /// metadata, while movies and shows use their own. Hub responses omit the
    /// Image array, so results (including misses) are cached per source key.
    func logoURL(for item: IOSPlexItem) async -> URL? {
        guard let serverURL, let serverToken else { return nil }
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

        if let cached = logoURLCache[sourceKey] { return cached }
        if missingLogoKeys.contains(sourceKey) { return nil }

        if item.type != "episode", item.type != "season",
           let direct = api.resourceURL(
               server: serverURL,
               token: serverToken,
               path: item.clearLogoPath
           ) {
            logoURLCache[sourceKey] = direct
            return direct
        }

        if let existing = logoResolutionTasks[sourceKey] {
            return await existing.value
        }

        let task = Task<URL?, Never> { [api] in
            guard let metadata = try? await api.metadata(
                server: serverURL,
                token: serverToken,
                ratingKey: sourceKey
            ) else { return nil }
            return api.resourceURL(
                server: serverURL,
                token: serverToken,
                path: metadata.clearLogoPath
            )
        }
        logoResolutionTasks[sourceKey] = task
        let resolved = await task.value
        logoResolutionTasks[sourceKey] = nil
        if let resolved {
            logoURLCache[sourceKey] = resolved
        } else {
            missingLogoKeys.insert(sourceKey)
        }
        return resolved
    }

    func playback(for item: IOSPlexItem) async throws -> IOSPlexPlaybackRequest {
        let full = try await metadata(for: item)
        let configuration = try configuration()
        guard let url = api.playbackURL(server: configuration.url, token: configuration.token, item: full) else {
            throw IOSPlexError.invalidURL
        }
        var markers = full.Marker ?? []
        if UserDefaults.standard.bool(forKey: "useIntroDB"),
           full.type == "episode",
           let showKey = full.grandparentRatingKey,
           let season = full.parentIndex,
           let episode = full.index,
           let show = try? await api.metadata(
               server: configuration.url,
               token: configuration.token,
               ratingKey: showKey
           ),
           let imdbID = show.imdbID {
            let community = await api.communityMarkers(
                imdbID: imdbID,
                season: season,
                episode: episode
            )
            let existingKinds = Set(markers.compactMap(\.type))
            markers.append(contentsOf: community.filter { marker in
                guard let type = marker.type else { return false }
                return !existingKinds.contains(type)
            })
        }
        return IOSPlexPlaybackRequest(
            item: full,
            url: url,
            headers: api.playbackHeaders(token: configuration.token),
            markers: markers.sorted { $0.start < $1.start },
            serverURL: configuration.url,
            token: configuration.token
        )
    }

    func reportProgress(for request: IOSPlexPlaybackRequest, time: TimeInterval, state: String) async {
        await api.reportProgress(
            server: request.serverURL,
            token: request.token,
            item: request.item,
            time: time,
            state: state
        )
    }

    func signOut() {
        pollingTask?.cancel()
        pollingTask = nil
        authToken = nil
        serverToken = nil
        serverURL = nil
        selectedServerName = nil
        pinCode = nil
        authenticationURL = nil
        libraries = []
        shelves = []
        availableServers = []
        profileImageURL = nil
        profileDisplayName = nil
        clearLogoCache()
        KeychainHelper.delete(authTokenKey)
        KeychainHelper.delete(serverTokenKey)
        UserDefaults.standard.removeObject(forKey: serverURLKey)
        UserDefaults.standard.removeObject(forKey: serverNameKey)
        state = .signedOut
    }

    private func clearLogoCache() {
        logoURLCache = [:]
        missingLogoKeys = []
        logoResolutionTasks.values.forEach { $0.cancel() }
        logoResolutionTasks = [:]
    }

    private func poll(pinID: Int) async {
        for _ in 0..<150 {
            guard !Task.isCancelled else { return }
            do {
                if let token = try await api.checkPIN(id: pinID) {
                    authToken = token
                    KeychainHelper.set(token, forKey: authTokenKey)
                    pinCode = nil
                    authenticationURL = nil
                    Task { [weak self] in
                        await self?.loadUserProfile()
                    }
                    await discoverServers(token: token)
                    return
                }
            } catch {
                // Plex may transiently reject a PIN check while the browser is
                // completing authentication. Keep polling until timeout.
            }
            try? await Task.sleep(for: .seconds(2))
        }
        guard !Task.isCancelled else { return }
        state = .failed("The Plex sign-in code expired. Please try again.")
    }

    private func loadUserProfile() async {
        guard let token = authToken,
              let profile = try? await api.userProfile(token: token),
              authToken == token else { return }

        profileDisplayName = profile.displayName
        if let thumb = profile.thumb, !thumb.isEmpty {
            profileImageURL = URL(
                string: thumb,
                relativeTo: URL(string: "https://plex.tv")!
            )?.absoluteURL
        } else {
            profileImageURL = nil
        }
    }

    private func discoverServers(token: String) async {
        state = .findingServers
        do {
            let servers = try await api.servers(token: token).filter { $0.presence != false }
            guard !servers.isEmpty else {
                state = .failed("Your Plex account did not return any available media servers.")
                return
            }
            if servers.count == 1, let only = servers.first {
                await selectServer(only)
            } else {
                availableServers = servers
                state = .selectingServer
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func configuration() throws -> (url: URL, token: String) {
        guard let serverURL, let serverToken else { throw IOSPlexError.noReachableServer }
        return (serverURL, serverToken)
    }
}

nonisolated struct IOSPlexPlaybackRequest: Identifiable, Sendable {
    var id: String { item.id }
    let item: IOSPlexItem
    let url: URL
    let headers: [String: String]
    let markers: [IOSPlexMarker]
    let serverURL: URL
    let token: String
}
