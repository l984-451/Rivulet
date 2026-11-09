// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexAuthManager.swift
//  Rivulet
//
//  Adapted from plex_watchOS AuthManager
//  Handles Plex PIN-based authentication flow for tvOS
//

import Foundation
import SwiftUI
import Combine
import Sentry

// MARK: - Auth State

enum PlexAuthState: Equatable {
    case idle
    case requestingPin
    case waitingForPIN(code: String, pinId: Int)
    case authenticated
    case selectingServer(servers: [PlexDevice])
    case error(message: String)

    static func == (lhs: PlexAuthState, rhs: PlexAuthState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle): return true
        case (.requestingPin, .requestingPin): return true
        case (.waitingForPIN(let c1, let p1), .waitingForPIN(let c2, let p2)):
            return c1 == c2 && p1 == p2
        case (.authenticated, .authenticated): return true
        case (.selectingServer(let s1), .selectingServer(let s2)):
            return s1.map(\.clientIdentifier) == s2.map(\.clientIdentifier)
        case (.error(let m1), .error(let m2)): return m1 == m2
        default: return false
        }
    }
}

// MARK: - Auth Manager

@MainActor
class PlexAuthManager: ObservableObject {
    static let shared = PlexAuthManager()

    /// Handoffs to the platform's content store (tvOS `PlexDataStore`, iOS
    /// `PlexSession`), set by the host at launch. `onAuthenticated` is awaited
    /// so the sidebar has its library tabs on its first build.
    static var onAuthenticated: (@MainActor () async -> Void)?
    static var onSignedOut: (@MainActor () -> Void)?

    // MARK: - Published State

    @Published var state: PlexAuthState = .idle
    @Published var authToken: String?
    @Published var username: String?
    /// The signed-in account's avatar, from the same /api/v2/user payload as
    /// `username`. Persisted so it survives relaunch without a refetch.
    @Published var userThumbURL: URL?
    @Published var selectedServer: PlexDevice?
    @Published var selectedServerURL: String?

    /// The token every content request uses. It is the account's server token
    /// only while the account itself is the profile in use; a Plex Home profile
    /// gets its own, and nil withholds content until that profile is entered.
    @Published private(set) var selectedServerToken: String?

    /// Whether we can currently reach the Plex server (separate from authentication)
    @Published var isConnected: Bool = true

    /// Error message when connection fails (displayed to user)
    @Published var connectionError: String?

    // MARK: - Private Properties

    private let networkManager = PlexNetworkManager.shared
    private var pollingTask: Task<Void, Never>?
    private var serverSelectionTask: Task<Bool, Never>?
    /// The server a synced sign-in prefers, used while that sign-in picks its first server.
    private var syncedPreferredServerID: String?
    private let userDefaults = UserDefaults.standard

    // UserDefaults keys (non-sensitive data only)
    private let usernameKey = "plexUsername"
    private let accountUserIDKey = "plexAccountUserID"
    private let userThumbKey = "plexUserThumb"
    private let serverURLKey = "selectedServerURL"
    private let serverNameKey = "selectedServerName"
    /// The selected server's machineIdentifier; a probe of the saved URL must answer with it.
    private let serverMachineIDKey = "selectedServerMachineID"

    /// Rank a local plex.direct (TLS) connection above local plain HTTP. The
    /// host sets this before first use: iOS does, a stationary Apple TV keeps
    /// the cheaper HTTP on its home LAN.
    nonisolated(unsafe) static var prefersSecureLocalConnections = false

    /// Sentinel set after a successful auth. Used to detect fresh installs —
    /// UserDefaults is wiped on app uninstall but Keychain persists, so if this
    /// flag is missing while the Keychain still has tokens, the Keychain data
    /// is stale from a previous install and must be cleared.
    private let hasPersistedSessionKey = "plexHasPersistedSession"

    // Legacy UserDefaults keys (for migration only)
    private let legacyTokenKey = "plexAuthToken"
    private let legacyServerTokenKey = "selectedServerToken"

    // Keychain keys (secure storage for tokens)
    private let keychainTokenKey = "plexAuthToken"
    private let keychainServerTokenKey = "selectedServerToken"

    // MARK: - Initialization

    private init() {
        // Migrate tokens from UserDefaults to Keychain (one-time migration)
        migrateTokensToKeychain()

        // Detect stale Keychain data from a previous install.
        // On tvOS/iOS, Keychain items with kSecAttrAccessibleAfterFirstUnlock
        // persist across app uninstalls, but UserDefaults is wiped. If we see
        // a Keychain token but no record of a prior session in UserDefaults,
        // this is a fresh install — clear the stale Keychain data so the auth
        // flow starts from a clean state.
        let hasPersistedSession = userDefaults.bool(forKey: hasPersistedSessionKey)
        let keychainHasToken = KeychainHelper.get(keychainTokenKey) != nil
            || KeychainHelper.get(keychainServerTokenKey) != nil
            || KeychainHelper.get(PlexProfileSession.keychainKey) != nil
        if !hasPersistedSession && keychainHasToken {
            DiagLog.notice(.auth, "Stale Keychain data from a previous install, cleared")
            KeychainHelper.delete(keychainTokenKey)
            KeychainHelper.delete(keychainServerTokenKey)
            PlexProfileSession.delete()
            PlexProfileSession.deleteProfilePlexTokens()
            KeychainHelper.deleteAllPins()
            state = .idle
            return
        }

        // Load tokens from Keychain (secure)
        authToken = KeychainHelper.get(keychainTokenKey)

        // Load non-sensitive data from UserDefaults
        username = userDefaults.string(forKey: usernameKey)
        userThumbURL = userDefaults.string(forKey: userThumbKey).flatMap { URL(string: $0) }
        selectedServerURL = userDefaults.string(forKey: serverURLKey)

        // A saved Home profile starts on its own stored token or on none.
        switch storedContent {
        case .account: selectedServerToken = accountServerToken
        case .profile(let token): selectedServerToken = token
        case .withheld, .unresolved: selectedServerToken = nil
        }

        if authToken != nil {
            state = .authenticated

            // A saved loopback address can never reach the server: clear it for re-selection.
            if let url = selectedServerURL,
               let host = URL(string: url)?.host,
               Self.isLoopbackAddress(host) {
                DiagLog.notice(.connection, "Saved URL is a loopback address, cleared for re-selection")
                selectedServerURL = nil
                userDefaults.removeObject(forKey: serverURLKey)
            }

            // A remote URL may be one older builds picked because they dropped a reachable
            // local address (#510), and it costs a LAN user their Home quality.
            if let url = selectedServerURL,
               !Self.isPlayableDirectURL(url) || (Self.prefersSecureLocalConnections && url.hasPrefix("http://"))
                || ServerLocation.classify(url) == .remote {
                Task { await upgradeConnectionIfBetterExists(from: url) }
            }
        }
    }

    /// Launch reuses a saved URL for as long as it answers, so a URL won in a
    /// bad moment sticks: raw HTTPS browses but cannot play (#314), and relay
    /// caps playback at 480p. The app starts on the saved URL; this re-probes
    /// in the background and switches only to a direct URL playback can use,
    /// never sideways (relay to raw HTTPS would trade 480p for no playback).
    private func upgradeConnectionIfBetterExists(from url: String) async {
        guard let token = authToken,
              let servers = try? await networkManager.getServers(authToken: token) else { return }
        let server = servers.first(where: { Self.urlBelongs(url, to: $0) })
            ?? savedServerName.flatMap { name in servers.first(where: { $0.name == name }) }
        guard let server,
              let best = await findBestConnection(for: server, reuseLastGood: false),
              Self.isPlayableDirectURL(best),
              best != url,
              selectedServerURL == url else { return }
        DiagLog.notice(.connection, "Upgrading connection \(DiagLog.describe(url: url)) -> \(DiagLog.describe(url: best))")
        selectedServerURL = best
        userDefaults.set(best, forKey: serverURLKey)
        userDefaults.set(server.machineIdentifier, forKey: serverMachineIDKey)
    }

    /// Migrate tokens from UserDefaults to Keychain (one-time, for existing users)
    private func migrateTokensToKeychain() {
        // Check if auth token exists in UserDefaults but not in Keychain
        if let legacyToken = userDefaults.string(forKey: legacyTokenKey),
           KeychainHelper.get(keychainTokenKey) == nil {
            KeychainHelper.set(legacyToken, forKey: keychainTokenKey)
            userDefaults.removeObject(forKey: legacyTokenKey)
        }

        // Check if server token exists in UserDefaults but not in Keychain
        if let legacyServerToken = userDefaults.string(forKey: legacyServerTokenKey),
           KeychainHelper.get(keychainServerTokenKey) == nil {
            KeychainHelper.set(legacyServerToken, forKey: keychainServerTokenKey)
            userDefaults.removeObject(forKey: legacyServerTokenKey)
        }
    }

    // MARK: - Public Methods

    /// Start the PIN authentication flow
    func startPINAuthentication() async {
        state = .requestingPin

        do {
            let (pinCode, pinId) = try await networkManager.requestPin()
            state = .waitingForPIN(code: pinCode, pinId: pinId)
            startPollingForAuth(pinId: pinId)
        } catch {
            state = .error(message: String(localized: "Failed to get PIN: \(error.localizedDescription)"))
            scheduleErrorDismissal()

            // Capture PIN request failure to Sentry
            SentryBridge.capture(error: error) { scope in
                scope.setTag(value: "plex_auth", key: "component")
                scope.setTag(value: "pin_request", key: "auth_step")
            }
        }
    }

    /// Cancel ongoing authentication
    func cancelAuthentication() {
        pollingTask?.cancel()
        pollingTask = nil
        state = .idle
    }

    /// Select a server from the list
    /// Returns true if connection was successful, false otherwise
    @discardableResult
    func selectServer(_ server: PlexDevice) async -> Bool {
        // Cancel any in-progress server selection
        serverSelectionTask?.cancel()

        // Create a tracked task for the connection test
        let task = Task { @MainActor () -> Bool in
            if let workingURL = await findBestConnection(for: server) {
                // A profile's stored token was issued for the server it was entered on.
                let serverChanged = selectedServerURL.map { !Self.urlBelongs($0, to: server) } ?? false

                // Flip identity, URL and token together only after the connection
                // verifies, or the UI names one server while data comes from another.
                selectedServer = server
                selectedServerURL = workingURL
                userDefaults.set(selectedServerURL, forKey: serverURLKey)
                userDefaults.set(server.name, forKey: serverNameKey)
                userDefaults.set(server.machineIdentifier, forKey: serverMachineIDKey)

                // For shared servers, use server-specific accessToken; for owned, use user's authToken
                await adoptAccountServerToken(server.accessToken ?? authToken, serverChanged: serverChanged)
                DiagLog.notice(.connection, "Server selected: owned=\(server.owned ?? false) version=\(server.productVersion) connections=\(server.connections?.count ?? 0) changed=\(serverChanged)")

                isConnected = true
                connectionError = nil
                state = .authenticated

                // Prefetch libraries as part of sign-in so the sidebar renders with
                // library tabs on first build. Without this, the sidebar's
                // conditional TabSection can latch to "empty" and not recover when
                // libraries load asynchronously later.
                await Self.onAuthenticated?()
                CloudSync.shared.accountsChanged()

                return true
            } else if selectedServerURL != nil {
                DiagLog.error(.connection, "Server switch failed, keeping the current server")
                // The switch failed. The current server stays selected.
                // The app did not test it again, so do not mark it as unreachable.
                return false
            } else {
                DiagLog.error(.connection, "Server selection failed, no server connected")
                isConnected = false
                connectionError = String(localized: "Could not connect to server. Check your network.")
                state = .error(message: String(localized: "Could not connect to server. Check your network."))
                // Don't auto-dismiss - let user see the error and retry
                return false
            }
        }

        serverSelectionTask = task
        return await task.value
    }

    /// Finds the best working connection for a server. The last-known-good URL is
    /// tried first; otherwise every candidate chain probes in parallel and the
    /// first success in priority order wins:
    /// - httpsRequired + local: plex.direct > HTTP > HTTPS
    /// - local: HTTP > plex.direct
    /// - remote: plex.direct URLs from the API
    /// - relay: last resort
    func findBestConnection(for server: PlexDevice, reuseLastGood: Bool = true) async -> String? {
        // Probes carry no token; a candidate counts only when it answers as this server.
        let expectedID = server.machineIdentifier

        // FAST PATH — last-known-good URL, but only when it plausibly belongs
        // to THIS server (matching a connection's host:port or embedding the
        // machineIdentifier, as plex.direct URLs do). Guards the switch-server
        // flow against reusing another server's URL.
        if reuseLastGood, let lastGood = selectedServerURL, Self.urlBelongs(lastGood, to: server) {
            if await testConnection(lastGood, expecting: expectedID) != nil {
                DiagLog.notice(.connection, "Last-known-good works: \(DiagLog.describe(url: lastGood))")
                return lastGood
            }
            DiagLog.notice(.connection, "Last-known-good failed: \(DiagLog.describe(url: lastGood)), racing candidates")
        }

        let validConnections = (server.connections ?? [])
            .filter { !Self.isLoopbackAddress($0.address) }

        // Sort by preference: local non-relay > remote > relay
        let sortedConnections = validConnections.sorted { conn1, conn2 in
            Self.connectionScore(conn1) > Self.connectionScore(conn2)
        }

        // Build the prioritized probe chains. Index order IS the priority order,
        // and it goes by what playback can use: every direct URL the players
        // accept (any connection, score order) outranks every raw-HTTPS URL,
        // which only the API can use (#314), and relay stays last. A remote
        // plex.direct URL therefore beats a local raw IP over HTTPS.
        var chains: [() async -> String?] = []

        let directConnections = sortedConnections.filter { !$0.relay }
        for connection in directConnections {
            chains.append { [weak self] in
                await self?.probePlayable(connection, expecting: expectedID)
            }
        }
        for connection in directConnections {
            chains.append { [weak self] in
                await self?.probeRawHTTPS(connection, expecting: expectedID)
            }
        }

        // Strictly last: relay. As the lowest-priority chain it can only win
        // once every chain above it has completed and failed.
        if let relayConnection = server.connections?.first(where: { $0.relay }) {
            chains.append { [weak self] in
                guard let self else { return nil }
                if await self.testConnection(relayConnection.uri, expecting: expectedID) != nil {
                    return relayConnection.uri
                }
                return nil
            }
        }

        guard !chains.isEmpty else { return nil }
        if let winner = await raceByPriority(chains) {
            let relay = PlexRelay.isRelayURL(winner) ? " relay" : ""
            DiagLog.notice(.connection, "Connection chosen: \(DiagLog.describe(url: winner))\(relay) of \(sortedConnections.count) candidates")
            return winner
        }

        // Every candidate failed: the server is off or unreachable, so a log.
        // The per-probe breadcrumbs above are mirrored as logs too.
        // Address CLASS only (never the address itself).
        let candidateSummary = sortedConnections.map { conn -> String in
            let kind = conn.relay ? "relay" : (conn.local ? "local" : "remote")
            let net = conn.uri.contains(".plex.direct") ? "plex.direct" : "raw"
            return "\(conn.protocolType)/\(kind)/\(net):\(conn.port)"
        }.joined(separator: ",")
        DiagLog.error(.connection, "All connection candidates failed: \(candidateSummary)")
        SentryBridge.log(.warn, "All server connection candidates failed", attributes: [
            "component": "plex_auth",
            "operation": "server_connect_failed",
            "server_name": server.name,
            "candidates": candidateSummary,
        ])
        return nil
    }

    /// Run all probe chains concurrently and return the first success in
    /// PRIORITY (index) order: a success at index i wins only once every
    /// chain at a lower index has completed without success. Remaining
    /// chains are cancelled once a winner is chosen.
    private func raceByPriority(_ chains: [() async -> String?]) async -> String? {
        await withTaskGroup(of: (Int, String?).self) { group in
            for (index, probe) in chains.enumerated() {
                group.addTask { (index, await probe()) }
            }
            // results[i] missing = still pending; .some(nil) = completed+failed.
            var results: [Int: String?] = [:]
            for await (index, url) in group {
                results[index] = url
                // Walk priorities from the top: stop at the first still-pending
                // chain; the first completed SUCCESS above that wins.
                for j in 0..<chains.count {
                    guard let completed = results[j] else { break }   // j pending — can't decide past it
                    if let winner = completed {
                        group.cancelAll()
                        return winner
                    }
                }
            }
            return nil   // every chain completed without a success
        }
    }

    /// Tier-one cascade for one connection: URLs both the API and the players
    /// accept. The advertised URI first. For an https plex.direct connection
    /// whose name fails (router DNS-rebinding protection refuses plex.direct
    /// names that resolve to private IPs, GitHub #224), plain HTTP to the raw
    /// address when local, which works whenever Secure connections is
    /// Preferred. For an http connection, a plex.direct URL built from the
    /// hash in the server's certificate.
    private func probePlayable(_ connection: PlexConnection, expecting expectedID: String?) async -> String? {
        if await testConnection(connection.uri, expecting: expectedID) != nil {
            return connection.uri
        }

        let host = connection.IPv6 ? "[\(connection.address)]" : connection.address
        guard connection.protocolType == "http" else {
            guard connection.local else { return nil }
            let rawHTTP = "http://\(host):\(connection.port)"
            return await testConnection(rawHTTP, expecting: expectedID) != nil ? rawHTTP : nil
        }

        let (_, certHash) = await testConnectionWithCertExtraction("https://\(host):\(connection.port)")
        // The presented certificate is unauthenticated: use its hash only when
        // plex.tv issued it to one of the account's servers.
        guard let hash = certHash,
              PlexCertificateDelegate.isKnownCertificateHash(hash, forAddress: connection.address) else { return nil }
        let plexDirectURI = buildPlexDirectURL(
            address: connection.address,
            port: connection.port,
            subdomainHash: hash
        )
        if await testConnection(plexDirectURI, expecting: expectedID) != nil {
            return plexDirectURI
        }
        return nil
    }

    /// Tier-two probe: HTTPS to the raw address. It passes when the server
    /// presents its plex.tv-issued certificate (see `trustsServer`); the HLS
    /// preflight and AVPlayer still refuse the mismatched name, so this URL
    /// browses but the hls route cannot play it (GitHub #314). It exists for
    /// servers that require secure connections behind a router that blocks
    /// plex.direct, where browsing beats no connection at all.
    private func probeRawHTTPS(_ connection: PlexConnection, expecting expectedID: String?) async -> String? {
        let host = connection.IPv6 ? "[\(connection.address)]" : connection.address
        let rawHTTPS = "https://\(host):\(connection.port)"
        return await testConnection(rawHTTPS, expecting: expectedID) != nil ? rawHTTPS : nil
    }

    /// Whether a persisted URL plausibly belongs to `server`: its host:port
    /// matches one of the server's advertised connections (http or https), or
    /// the URL embeds the server's machineIdentifier (plex.direct form).
    nonisolated static func urlBelongs(_ urlString: String, to server: PlexDevice) -> Bool {
        if let machineId = server.machineIdentifier, urlString.contains(machineId) {
            return true
        }
        guard let url = URL(string: urlString), let host = url.host else { return false }
        let port = url.port
        for connection in server.connections ?? [] {
            if connection.address == host && connection.port == port { return true }
            if let connURL = URL(string: connection.uri),
               connURL.host == host, connURL.port == port {
                return true
            }
        }
        return false
    }

    /// Score a connection for sorting (higher = better)
    /// Note: When server.httpsRequired=true, findBestConnection() tries plex.direct first
    /// Priority for initial sorting: Local non-relay > Remote > Relay
    /// - Local prefers HTTP (fastest when secure connections not required)
    /// - For httpsRequired servers, plex.direct is tried first (valid TLS for playback)
    nonisolated static func connectionScore(_ connection: PlexConnection) -> Int {
        var score = 0

        // Prefer non-relay (direct connections)
        if !connection.relay { score += 1000 }

        // Prefer local connections
        if connection.local {
            score += 500
            // For local: prefer HTTP (avoids certificate issues), unless the host prefers TLS
            if (connection.protocolType == "http") != Self.prefersSecureLocalConnections { score += 50 }
            if looksLikeDockerBridge(connection.address) { score -= 100 }
        } else {
            // For remote: prefer HTTPS (required by ATS)
            if connection.protocolType == "https" { score += 100 }
            // plex.direct domains are reliable for remote access
            if connection.address.contains(".plex.direct") { score += 50 }
        }

        return score
    }

    /// Build a plex.direct URL for a valid-TLS endpoint.
    /// Format: https://<ip-with-dashes>.<subdomainHash>.plex.direct:<port>
    /// `subdomainHash` MUST be the server's plex.direct certificate hash (the
    /// label in the wildcard cert CN), NOT the machineIdentifier — those differ
    /// (e.g. cert hash is 32 hex chars, machineIdentifier is a 40-char SHA-1).
    /// Callers obtain it by extracting it from the server's TLS certificate.
    private func buildPlexDirectURL(address: String, port: Int, subdomainHash: String) -> String {
        let ipWithDashes = address.replacingOccurrences(of: ".", with: "-")
        return "https://\(ipWithDashes).\(subdomainHash).plex.direct:\(port)"
    }

    /// Loopback names the server's own machine, never a path from this device.
    nonisolated static func isLoopbackAddress(_ address: String) -> Bool {
        ["127.0.0.1", "localhost", "::1"].contains(address)
    }

    /// Docker's default bridge range. It is also a normal LAN range (#510), so such an address is
    /// probed like any other, only after the server's other local addresses.
    nonisolated static func looksLikeDockerBridge(_ address: String) -> Bool {
        (17...31).contains { address.hasPrefix("172.\($0).") }
    }

    /// Whether playback can use this URL directly: not relay, and not HTTPS
    /// to a bare IP literal (a cert the players reject). plex.direct names
    /// and plain HTTP qualify.
    static func isPlayableDirectURL(_ urlString: String) -> Bool {
        guard let components = URLComponents(string: urlString),
              let host = components.host else { return false }
        if PlexRelay.isRelayURL(urlString) { return false }
        guard components.scheme == "https" else { return true }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let isIPv4 = bare.split(separator: ".", omittingEmptySubsequences: false)
            .map { UInt8($0) != nil }.allSatisfy { $0 }
            && bare.split(separator: ".").count == 4
        let isIPLiteral = isIPv4 || bare.contains(":")
        return !isIPLiteral
    }

    /// Probes `urlString/identity` WITHOUT a token and returns the server's
    /// machineIdentifier, or nil when unreachable or (given `expectedID`) a
    /// different server. PMS answers /identity unauthenticated, so the token
    /// never reaches a host that has not proved which server it is.
    private func testConnection(_ urlString: String, expecting expectedID: String?) async -> String? {
        guard let url = URL(string: "\(urlString)/identity") else { return nil }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5.0
            request.addValue("application/json", forHTTPHeaderField: "Accept")

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 5.0
            config.timeoutIntervalForResource = 5.0

            let session = URLSession(configuration: config, delegate: PlexCertificateDelegate(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }

            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else { return nil }
            guard (200...299).contains(httpResponse.statusCode) else {
                Self.addConnectionTestBreadcrumb(urlString: urlString, outcome: "http_\(httpResponse.statusCode)")
                return nil
            }
            guard let identity = Self.machineIdentifier(fromIdentity: data) else {
                Self.addConnectionTestBreadcrumb(urlString: urlString, outcome: "not_plex")
                return nil
            }
            if let expectedID, identity != expectedID {
                Self.addConnectionTestBreadcrumb(urlString: urlString, outcome: "wrong_server")
                return nil
            }
            return identity
        } catch {
            print("🔐 PlexAuthManager: Connection test error: \(error.localizedDescription)")
            let nsError = error as NSError
            Self.addConnectionTestBreadcrumb(
                urlString: urlString, outcome: "\(nsError.domain)#\(nsError.code)")
            return nil
        }
    }

    /// False only on an explicit 401/403 from a server already proven to be the right one.
    private func serverAcceptsToken(_ token: String?, at urlString: String) async -> Bool {
        guard let token, let url = URL(string: "\(urlString)/") else { return true }
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (_, response) = try? await PlexCertificateDelegate.session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return true }
        return status != 401 && status != 403
    }

    /// `MediaContainer.machineIdentifier` from an /identity body (JSON, or XML from older servers).
    nonisolated static func machineIdentifier(fromIdentity data: Data) -> String? {
        struct Identity: Decodable {
            struct Container: Decodable { let machineIdentifier: String? }
            let MediaContainer: Container
        }
        if let id = (try? JSONDecoder().decode(Identity.self, from: data))?.MediaContainer.machineIdentifier {
            return id.isEmpty ? nil : id
        }
        guard let text = String(data: data, encoding: .utf8),
              let range = text.range(of: #"machineIdentifier="([^"]+)""#, options: .regularExpression) else { return nil }
        return String(text[range].dropFirst("machineIdentifier=\"".count).dropLast())
    }

    /// One breadcrumb per failed connection probe (mirrored as a log), so the
    /// per-candidate failure trail is visible (GitHub #224).
    private static func addConnectionTestBreadcrumb(urlString: String, outcome: String) {
        let breadcrumb = Breadcrumb(level: .warning, category: "plex_auth")
        breadcrumb.message = "Connection probe failed"
        breadcrumb.data = [
            "host": URL(string: urlString)?.host ?? "invalid-url",
            "port": URL(string: urlString)?.port ?? 0,
            "scheme": URL(string: urlString)?.scheme ?? "?",
            "outcome": outcome
        ]
        SentryBridge.addBreadcrumb(breadcrumb)
    }

    /// Test connection and extract plex.direct hash from certificate if it fails
    /// Returns (success, extractedHash) where extractedHash is the plex.direct hash from the cert
    private func testConnectionWithCertExtraction(_ urlString: String) async -> (Bool, String?) {
        guard let url = URL(string: "\(urlString)/identity") else { return (false, nil) }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5.0
            request.addValue("application/json", forHTTPHeaderField: "Accept")

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 5.0
            config.timeoutIntervalForResource = 5.0

            let session = URLSession(configuration: config, delegate: PlexCertificateDelegate(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }

            let (_, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse,
               (200...299).contains(httpResponse.statusCode) {
                return (true, nil)
            }
            return (false, nil)
        } catch {
            print("🔐 PlexAuthManager: Connection test error: \(error.localizedDescription)")

            // Try to extract plex.direct hash from certificate error
            let nsError = error as NSError
            Self.addConnectionTestBreadcrumb(
                urlString: urlString, outcome: "\(nsError.domain)#\(nsError.code)")
            if nsError.code == -1200 || nsError.code == -9802 { // SSL errors
                if let certHash = extractPlexDirectHash(from: nsError) {
                    return (false, certHash)
                }
            }
            return (false, nil)
        }
    }

    /// Extract the plex.direct hash from an SSL certificate error
    /// The certificate subject contains: *.HASH.plex.direct
    private func extractPlexDirectHash(from error: NSError) -> String? {
        // Look in the error's userInfo for certificate chain info
        let errorString = error.description

        // Pattern: *.HASH.plex.direct where HASH is 32 hex chars
        let pattern = #"\*\.([a-f0-9]{32})\.plex\.direct"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return nil
        }

        let range = NSRange(errorString.startIndex..., in: errorString)
        if let match = regex.firstMatch(in: errorString, range: range),
           let hashRange = Range(match.range(at: 1), in: errorString) {
            return String(errorString[hashRange])
        }

        return nil
    }

    /// Sign out and clear credentials. With iCloud Sync the token is shared, so revoking it signs
    /// every device out: only `.everywhere` does. A caller that does not ask gets this device only.
    func signOut(scope: SignOutScope? = nil) {
        let scope = scope ?? .thisDevice
        let shared = CloudSync.shared.wasShared(accountID: Self.syncID)
        let identity = syncAccountUserID.map(String.init)
        DiagLog.notice(.auth, "Signed out of Plex")
        pollingTask?.cancel()
        pollingTask = nil

        // A token left valid at plex.tv would outlive the sign-out.
        if let token = authToken, scope.revokesToken(everShared: shared) {
            Task { await networkManager.revokeToken(token) }
        }
        authToken = nil
        username = nil
        userThumbURL = nil
        selectedServer = nil
        selectedServerURL = nil
        selectedServerToken = nil
        isConnected = true  // Reset to default
        connectionError = nil

        // Clear tokens from Keychain (secure storage)
        KeychainHelper.delete(keychainTokenKey)
        KeychainHelper.delete(keychainServerTokenKey)
        PlexProfileSession.delete()
        PlexProfileSession.deleteProfilePlexTokens()
        PlexCertificateDelegate.forgetCertificateHashes()

        // Clear non-sensitive data from UserDefaults
        userDefaults.removeObject(forKey: PlexProfileSession.contentUserIDKey)
        userDefaults.removeObject(forKey: accountUserIDKey)
        userDefaults.removeObject(forKey: usernameKey)
        userDefaults.removeObject(forKey: userThumbKey)
        userDefaults.removeObject(forKey: serverURLKey)
        userDefaults.removeObject(forKey: serverNameKey)
        userDefaults.removeObject(forKey: serverMachineIDKey)
        userDefaults.removeObject(forKey: hasPersistedSessionKey)

        // Clear any legacy tokens that might still exist
        userDefaults.removeObject(forKey: legacyTokenKey)
        userDefaults.removeObject(forKey: legacyServerTokenKey)

        // Clear user profile selection
        PlexUserProfileManager.shared.reset()
        // Takes the server's DVR out of Live TV.
        LiveTVDataStore.shared.plexContentTokenChanged()

        // Clear the previous session's cached content, or a new sign-in shows the
        // old server's hubs under the new server's name.
        Self.onSignedOut?()

        state = .idle
        if scope != .syncedRemoval { CloudSync.shared.signedOut(accountID: Self.syncID, identity: identity, scope: scope) }
    }

    /// The vault entry id for the one Plex account.
    static let syncID = "plex"

    /// The plex.tv account id, which says whose account a synced token is.
    var syncAccountUserID: Int? { userDefaults.object(forKey: accountUserIDKey) as? Int }

    /// Signs in with a token another device holds. Goes through the normal sign-in path, which sets the
    /// fresh-install sentinel; writing the token straight to the Keychain would be wiped on the next launch.
    /// False without touching anything when the token is not accepted or a sign-in already exists.
    func adoptSyncedSession(token: String, preferredServerMachineID: String?) async -> AdoptOutcome {
        guard authToken == nil else { return .refused }
        switch await tokenCheck(token) {
        case .adopted: break
        case let other: return other
        }
        syncedPreferredServerID = preferredServerMachineID
        await handleSuccessfulAuth(token: token)
        syncedPreferredServerID = nil
        return authToken != nil ? .adopted : .unavailable
    }

    /// `.adopted` here means "the token works".
    private func tokenCheck(_ token: String) async -> AdoptOutcome {
        let url = URL(string: "https://plex.tv/api/v2/user")!
        let headers = ["X-Plex-Token": token, "X-Plex-Client-Identifier": PlexAPI.clientIdentifier, "Accept": "application/json"]
        do {
            _ = try await networkManager.requestData(url, headers: headers)
            return .adopted
        } catch PlexAPIError.httpError(let status, _) where status == 401 || status == 403 {
            return .refused
        } catch {
            return .unavailable
        }
    }

    /// Reset error state
    func reset() {
        pollingTask?.cancel()
        pollingTask = nil
        state = .idle
    }

    // MARK: - Content Token

    /// The account's own token for the selected server.
    private var accountServerToken: String? {
        KeychainHelper.get(keychainServerTokenKey) ?? authToken
    }

    /// Who the stored state lets load content: the account, the saved profile, or nobody yet.
    private var storedContent: PlexProfileSession.Content {
        PlexProfileSession.content(
            accountToken: authToken,
            savedUserID: userDefaults.object(forKey: PlexProfileSession.savedUserIDKey) as? Int,
            session: PlexProfileSession.load(),
            everResolved: userDefaults.object(forKey: PlexProfileSession.contentUserIDKey) != nil)
    }

    /// Signed in with a server, but content waits for a Home profile to be entered.
    var isContentWithheld: Bool {
        isAuthenticated && selectedServerToken == nil
    }

    /// Whose content loads: 0 for the account, else the Home profile's user id.
    var contentOwnerID: Int { userDefaults.integer(forKey: PlexProfileSession.contentUserIDKey) }

    /// The selected server's machineIdentifier, remembered across launches.
    var selectedServerMachineID: String? {
        selectedServer?.machineIdentifier ?? userDefaults.string(forKey: serverMachineIDKey)
    }

    /// The selected server among `servers`: by machineIdentifier, else the one the
    /// saved URL belongs to. Installs from before its id or name was saved learn them here.
    func selectedServer(in servers: [PlexDevice]) -> PlexDevice? {
        let server = selectedServerMachineID.map { id in servers.first { $0.machineIdentifier == id } }
            ?? selectedServerURL.flatMap { url in servers.first { Self.urlBelongs(url, to: $0) } }
        guard let server else { return nil }
        if selectedServerMachineID == nil { userDefaults.set(server.machineIdentifier, forKey: serverMachineIDKey) }
        if savedServerName == nil { userDefaults.set(server.name, forKey: serverNameKey) }
        return server
    }

    /// The profile in use was entered with a PIN, so the next launch starts locked.
    /// Signed out of Plex is not a lock: `storedContent` reads `.withheld` with no account token.
    var relocksOnLaunch: Bool { authToken != nil && storedContent == .withheld }

    /// The plex.tv token for account-level content (Watchlist, favourite channels):
    /// the account's own, or the profile in use's own switched token.
    var accountContentToken: String? {
        let id = contentOwnerID
        return PlexProfileSession.accountContentToken(
            accountToken: authToken, contentUserID: id, contentUnlocked: selectedServerToken != nil,
            profileToken: id == 0 ? nil : PlexProfileSession.profilePlexToken(userID: id))
    }

    /// Whether a Home user is the signed-in account itself, not another profile in its Home.
    func isAccount(_ user: PlexHomeUser) -> Bool {
        PlexProfileSession.isAccount(userID: user.id, admin: user.admin,
                                     accountUserID: userDefaults.object(forKey: accountUserIDKey) as? Int)
    }

    /// An install from before the account's id was kept learns it on the next profile fetch.
    func loadAccountUserIDIfNeeded() async {
        if userDefaults.object(forKey: accountUserIDKey) == nil { await fetchUserInfo() }
    }

    /// Whether content is loading with this profile's own token, not the account's.
    func isUsingToken(of user: PlexHomeUser) -> Bool {
        selectedServerToken != nil && !isAccount(user)
            && userDefaults.integer(forKey: PlexProfileSession.contentUserIDKey) == user.id
    }

    /// Installs a Home profile's server token. Returns true when content now
    /// belongs to a different user than the one it was loaded and cached for.
    func enterProfile(_ user: PlexHomeUser, serverToken: String, plexToken: String, usedPin: Bool) -> Bool {
        guard let authToken else { return false }
        let isAccount = isAccount(user)
        if !isAccount { PlexProfileSession.saveProfilePlexToken(plexToken, userID: user.id) }
        let access = PlexProfileSession.access(isAccount: isAccount, usedPin: usedPin, serverToken: serverToken)
        PlexProfileSession(userID: user.id, accountToken: authToken, access: access).save()
        if selectedServerToken != serverToken { selectedServerToken = serverToken }
        return setContentOwner(isAccount ? 0 : user.id)
    }

    /// The account's own profile could not be entered through plex.tv: content
    /// keeps the account's server token. Before a server is chosen it only records that.
    func useAccountServerToken(for account: PlexHomeUser) -> Bool {
        guard let authToken else { return false }
        PlexProfileSession(userID: account.id, accountToken: authToken, access: .account).save()
        if selectedServerToken == nil, selectedServerURL != nil { selectedServerToken = accountServerToken }
        return setContentOwner(0)
    }

    /// plex.tv could not be asked about a saved profile this build has never
    /// resolved: run on the account's token, as that install did before. Returns
    /// true when it installed the token.
    func useAccountTokenWhileUnresolved() -> Bool {
        guard isContentWithheld, storedContent == .unresolved else { return false }
        selectedServerToken = accountServerToken
        return selectedServerToken != nil
    }

    /// Locks content until the saved profile is entered through plex.tv. The
    /// account's token is never the fallback.
    func withholdContent() {
        DiagLog.notice(.profile, "Content withheld until a profile is entered")
        selectedServerToken = nil
        guard let authToken,
              let userID = userDefaults.object(forKey: PlexProfileSession.savedUserIDKey) as? Int else { return }
        PlexProfileSession(userID: userID, accountToken: authToken, access: .withheld).save()
        // Resolved from here on: with no session (a failed Keychain write) it stays
        // withheld, and the never-resolved fallback to the account is closed.
        if userDefaults.object(forKey: PlexProfileSession.contentUserIDKey) == nil {
            userDefaults.set(0, forKey: PlexProfileSession.contentUserIDKey)
        }
    }

    private func setContentOwner(_ userID: Int) -> Bool {
        let previous = userDefaults.integer(forKey: PlexProfileSession.contentUserIDKey)
        userDefaults.set(userID, forKey: PlexProfileSession.contentUserIDKey)
        return previous != userID
    }

    /// Stores the account's token for the selected server, and makes it the
    /// content token only while the account is the profile in use.
    private func adoptAccountServerToken(_ token: String?, serverChanged: Bool) async {
        if let token {
            KeychainHelper.set(token, forKey: keychainServerTokenKey)
        }
        if storedContent == .account {
            selectedServerToken = token
            // A no-op unless server or token changed; a first sign-in changes both.
            LiveTVDataStore.shared.plexContentTokenChanged()
        } else if serverChanged {
            // The profile's token is for the old server: enter it again on this one.
            withholdContent()
            await PlexUserProfileManager.shared.reapplySelectedProfile()
        }
    }

    /// Check if currently authenticated (has valid credentials)
    var isAuthenticated: Bool {
        authToken != nil && selectedServerURL != nil
    }

    /// Check if user has saved Plex credentials (for showing cached content even when offline)
    var hasCredentials: Bool {
        authToken != nil && userDefaults.string(forKey: serverURLKey) != nil
    }

    /// Get saved server name
    var savedServerName: String? {
        userDefaults.string(forKey: serverNameKey)
    }

    /// Returns true if the app uses `server` now.
    /// After a relaunch, `selectedServer` is nil, so this also compares the saved URL and name.
    func isCurrentServer(_ server: PlexDevice) -> Bool {
        if let current = selectedServer { return current.clientIdentifier == server.clientIdentifier }
        if let url = selectedServerURL, Self.urlBelongs(url, to: server) { return true }
        return server.name == savedServerName
    }

    /// Whether `url` points at the server in use, so its token may go there.
    func isCurrentServerURL(_ url: String) -> Bool {
        if url == selectedServerURL { return true }
        if let server = selectedServer { return Self.urlBelongs(url, to: server) }
        guard let current = selectedServerURL.flatMap(URL.init(string:)), let other = URL(string: url) else { return false }
        return current.host == other.host && current.port == other.port
    }

    /// Verify current connection and re-select if needed
    /// Call this on app launch to ensure we have a working server connection
    func verifyAndFixConnection() async {
        guard let token = authToken else { return }

        // If we have no server URL, fetch servers and select one
        if selectedServerURL == nil {
            do {
                let servers = try await networkManager.getServers(authToken: token)
                if servers.count == 1 {
                    // Await server selection to ensure URL is set before returning
                    await selectServer(servers[0])
                } else if servers.count > 1 {
                    state = .selectingServer(servers: servers)
                }
            } catch {
                DiagLog.error(.connection, "Server discovery failed: \(DiagLog.describe(error))")
                isConnected = false
                connectionError = String(localized: "Unable to reach Plex. Check your network connection.")

                SentryBridge.log(.warn, "Plex server discovery failed", attributes: [
                    "component": "plex_auth",
                    "auth_step": "server_discovery",
                    "error": String(describing: error),
                ])
            }
            return
        }

        // Test current connection using the saved server token
        guard let currentURL = selectedServerURL else { return }

        let savedID = userDefaults.string(forKey: serverMachineIDKey)
        // The probe carries no token, so ask once with it: a token the server
        // stopped accepting is refreshed by the rediscovery below.
        if let identity = await testConnection(currentURL, expecting: savedID),
           await serverAcceptsToken(selectedServerToken, at: currentURL) {
            // Builds before the identity check saved no id; the URL they trusted names it.
            if savedID == nil { userDefaults.set(identity, forKey: serverMachineIDKey) }
            DiagLog.notice(.connection, "Current connection verified: \(DiagLog.describe(url: currentURL))")
            isConnected = true
            connectionError = nil
            // A remote URL won away from home still answers there through the router's slow hairpin.
            if ServerLocation.classify(currentURL) == .remote {
                await upgradeConnectionIfBetterExists(from: currentURL)
            }

            // Fetch home users for profile switching (if not already loaded)
            if !PlexUserProfileManager.shared.hasLoadedProfiles {
                await PlexUserProfileManager.shared.fetchHomeUsers()
            }
        } else {
            DiagLog.error(.connection, "Current connection failed: \(DiagLog.describe(url: currentURL)), re-selecting")
            isConnected = false
            connectionError = String(localized: "Cannot connect to Plex server")

            // Look for a better connection without clearing credentials, so cached
            // content still shows. Match the saved server by URL, then by name
            // (Plex rotates URIs); if neither matches, keep the current selection.
            do {
                let servers = try await networkManager.getServers(authToken: token)
                let savedName = savedServerName
                let matchedServer = servers.first(where: { server in
                    server.connections?.contains { $0.uri == currentURL } == true
                }) ?? (savedName.flatMap { name in
                    servers.first(where: { $0.name == name })
                })
                if let currentServer = matchedServer {
                    // Try to find a working connection on this server
                    if let workingURL = await findBestConnection(for: currentServer) {
                        selectedServerURL = workingURL
                        userDefaults.set(selectedServerURL, forKey: serverURLKey)
                        userDefaults.set(currentServer.name, forKey: serverNameKey)
                        userDefaults.set(currentServer.machineIdentifier, forKey: serverMachineIDKey)

                        // Same server at a new address: a profile's own token still holds.
                        await adoptAccountServerToken(currentServer.accessToken ?? authToken, serverChanged: false)

                        DiagLog.notice(.connection, "Re-selected connection: \(DiagLog.describe(url: workingURL))")
                        isConnected = true
                        connectionError = nil
                        state = .authenticated
                    }
                } else {
                    DiagLog.error(.connection, "Saved server not in the account's server list (\(servers.count) servers)")
                }
            } catch {
                DiagLog.error(.connection, "Server discovery for re-selection failed: \(DiagLog.describe(error))")
                // Keep existing credentials - just mark as not connected
                // User can still see cached content

                SentryBridge.log(.warn, "Plex connection verify failed", attributes: [
                    "component": "plex_auth",
                    "auth_step": "connection_verify",
                    "host": URL(string: currentURL)?.host ?? "unknown",
                    "error": String(describing: error),
                ])
            }
        }
    }

    // MARK: - Private Methods

    private func startPollingForAuth(pinId: Int) {
        pollingTask?.cancel()

        pollingTask = Task {
            var attempts = 0
            let maxAttempts = 60 // 5 minutes (5 second intervals)

            while !Task.isCancelled && attempts < maxAttempts {
                do {
                    try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds

                    if let token = try await networkManager.checkPinAuthentication(pinId: pinId) {
                        // Successfully authenticated!
                        await handleSuccessfulAuth(token: token)
                        return
                    }

                    attempts += 1
                } catch {
                    if !Task.isCancelled {
                        state = .error(message: String(localized: "Authentication check failed: \(error.localizedDescription)"))
                        scheduleErrorDismissal()
                    }
                    return
                }
            }

            if !Task.isCancelled {
                state = .error(message: String(localized: "PIN expired. Please try again."))
                scheduleErrorDismissal()
            }
        }
    }

    private func handleSuccessfulAuth(token: String) async {
        DiagLog.notice(.auth, "Plex sign-in succeeded")
        authToken = token
        KeychainHelper.set(token, forKey: keychainTokenKey)
        // Mark this install as having a persisted session so a later reinstall
        // can detect stale Keychain data on first launch.
        userDefaults.set(true, forKey: hasPersistedSessionKey)

        // Fetch user info
        await fetchUserInfo()

        // Fetch home users (for profile switching)
        await PlexUserProfileManager.shared.fetchHomeUsers()

        // Fetch available servers
        await resumeServerSelection()
        CloudSync.shared.accountsChanged()
    }

    /// Fetches the account's servers and enters selection (or auto-selects a
    /// single server). Runs after PIN auth and to recover an account linked with
    /// no server, so a failed first connection can be retried (#224).
    func resumeServerSelection() async {
        guard let token = authToken else { return }
        do {
            let servers = try await networkManager.getServers(authToken: token)

            if servers.isEmpty {
                state = .error(message: String(localized: "No Plex servers found on your account"))
                scheduleErrorDismissal()
            } else if let wanted = syncedPreferredServerID, let preferred = servers.first(where: { $0.machineIdentifier == wanted }) {
                await selectServer(preferred)
            } else if servers.count == 1 {
                // Auto-select if only one server - await to ensure connection is established
                await selectServer(servers[0])
            } else {
                // Show server selection
                state = .selectingServer(servers: servers)
            }
        } catch {
            state = .error(message: String(localized: "Failed to fetch servers: \(error.localizedDescription)"))
            scheduleErrorDismissal()
        }
    }

    /// Retry after a connection error without repeating the PIN link when the
    /// account is already authenticated — re-runs server selection instead.
    func retryAfterError() async {
        if authToken != nil {
            await resumeServerSelection()
        } else {
            await startPINAuthentication()
        }
    }

    private func fetchUserInfo() async {
        guard let token = authToken else { return }

        do {
            let url = URL(string: "https://plex.tv/api/v2/user")!
            let data = try await networkManager.requestData(
                url,
                headers: [
                    "X-Plex-Token": token,
                    "X-Plex-Client-Identifier": PlexAPI.clientIdentifier,
                    "Accept": "application/json"
                ]
            )

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Which Home user is this account: the admin flag does not say.
                if let id = json["id"] as? Int {
                    userDefaults.set(id, forKey: accountUserIDKey)
                }
                if let name = json["username"] as? String ?? json["friendlyName"] as? String {
                    username = name
                    userDefaults.set(name, forKey: usernameKey)
                }
                // The account avatar comes back in the same payload; keep it
                // so hosts can show the signed-in account (iOS top chrome).
                if let thumb = json["thumb"] as? String, let url = URL(string: thumb) {
                    userThumbURL = url
                    userDefaults.set(thumb, forKey: userThumbKey)
                }
            }
        } catch {
            // Non-critical error, just log it
            print("Failed to fetch user info: \(error)")
        }
    }

    private func scheduleErrorDismissal() {
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            if case .error = state {
                state = .idle
            }
        }
    }
}

// MARK: - Link page URL

extension PlexAuthManager {
    /// The plex.tv/link page with the PIN filled in, so the user only signs in
    /// and confirms. It is the URL Plex's own `qr` image for a PIN encodes, and
    /// the page the developer docs name for a short PIN (`strong` unset, as
    /// `requestPin` sends); `app.plex.tv/auth#?code=` is the strong-PIN form.
    nonisolated static func linkURL(code: String) -> URL {
        var components = URLComponents(string: "https://www.plex.tv/link/")!
        components.queryItems = [URLQueryItem(name: "pin", value: code)]
        return components.url!
    }

    /// `linkURL(code:)` for the PIN being waited on.
    var linkURL: URL? {
        guard case .waitingForPIN(let code, _) = state else { return nil }
        return Self.linkURL(code: code)
    }
}

// MARK: - Certificate Delegate for Connection Testing

/// URLSession delegate applying the Plex server certificate rule.
nonisolated final class PlexCertificateDelegate: NSObject, URLSessionDelegate {
    /// For Plex server requests made outside `PlexNetworkManager`.
    static let session = URLSession(
        configuration: .default, delegate: PlexCertificateDelegate(), delegateQueue: nil)

    private static let hashesKey = "plexDirectCertificateHashesByAddress"
    private static let hashLock = NSLock()
    /// Server address -> the plex.direct certificate hash plex.tv lists for it.
    nonisolated(unsafe) private static var hashesByAddress: [String: Set<String>] =
        ((UserDefaults.standard.dictionary(forKey: hashesKey) as? [String: [String]]) ?? [:]).mapValues(Set.init)

    /// Records, for the account's OWN servers, which certificate hash each
    /// advertised address presents. Learned only from plex.tv's resource list
    /// (system-trusted TLS); a shared server's owner holds their own key, so
    /// their hashes are never trusted for an address.
    static func registerCertificateHashes(from servers: [PlexDevice]) {
        var found: [String: Set<String>] = [:]
        for server in servers where server.owned == true {
            let connections = server.connections ?? []
            // The server presents the same certificate at every address it lists,
            // including custom ones (a Docker host's LAN IP) whose URI is not plex.direct.
            let hashes = Set(connections.compactMap { plexDirectHash(in: $0.uri) })
            guard !hashes.isEmpty else { continue }
            for connection in connections {
                found[normalizedAddress(connection.address), default: []].formUnion(hashes)
            }
        }
        hashLock.lock()
        let merged = hashesByAddress.merging(found) { $0.union($1) }
        let changed = merged != hashesByAddress
        hashesByAddress = merged
        hashLock.unlock()
        if changed { UserDefaults.standard.set(merged.mapValues { Array($0) }, forKey: hashesKey) }
    }

    static func forgetCertificateHashes() {
        hashLock.lock(); hashesByAddress = [:]; hashLock.unlock()
        UserDefaults.standard.removeObject(forKey: hashesKey)
    }

    /// Whether plex.tv listed `hash` for one of the account's own servers at `address`.
    static func isKnownCertificateHash(_ hash: String, forAddress address: String) -> Bool {
        hashLock.lock(); defer { hashLock.unlock() }
        return hashesByAddress[normalizedAddress(address)]?.contains(hash.lowercased()) == true
    }

    private static func normalizedAddress(_ address: String) -> String {
        address.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
    }

    /// The `<hash>` of a `https://<ip>.<hash>.plex.direct:<port>` URI.
    static func plexDirectHash(in uri: String) -> String? {
        guard let host = URL(string: uri)?.host?.lowercased(), host.hasSuffix(".plex.direct") else { return nil }
        let labels = host.split(separator: ".")
        guard labels.count >= 3 else { return nil }
        let hash = labels[labels.count - 3]
        return hash.count == 32 && hash.allSatisfy(\.isHexDigit) ? String(hash) : nil
    }

    /// The certificate rule shared by the API sessions and the players: the
    /// system's own answer, or else, for a raw IP address only, the valid
    /// plex.tv-issued certificate of the account's own server at that address
    /// (#314, #337). A DNS name never gets the fallback.
    static func trustsServer(_ space: URLProtectionSpace) -> Bool {
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust else { return false }
        if SecTrustEvaluateWithError(trust, nil) { return true }
        let address = normalizedAddress(space.host)
        guard isIPLiteral(address) else { return false }
        hashLock.lock()
        let hashes = hashesByAddress[address] ?? []
        hashLock.unlock()
        for hash in hashes {
            // The certificate is *.<hash>.plex.direct; any single label matches it.
            SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "server.\(hash).plex.direct" as CFString))
            if SecTrustEvaluateWithError(trust, nil) { return true }
        }
        return false
    }

    static func isIPLiteral(_ host: String) -> Bool {
        var v4 = in_addr(), v6 = in6_addr()
        return inet_pton(AF_INET, host, &v4) == 1 || inet_pton(AF_INET6, host, &v6) == 1
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        Self.answer(challenge, completionHandler: completionHandler)
    }

    /// One disposition for every Plex session delegate.
    static func answer(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = space.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        if trustsServer(space) {
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        } else {
            // Fails with the system's certificate error, which callers read.
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
