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

    // MARK: - Published State

    @Published var state: PlexAuthState = .idle
    @Published var authToken: String?
    @Published var username: String?
    @Published var selectedServer: PlexDevice?
    @Published var selectedServerURL: String?

    /// The access token to use for the selected server
    /// For shared/friend's servers, this is the server-specific accessToken
    /// For owned servers, this falls back to the user's authToken
    @Published var selectedServerToken: String?

    /// Whether we can currently reach the Plex server (separate from authentication)
    @Published var isConnected: Bool = true

    /// Error message when connection fails (displayed to user)
    @Published var connectionError: String?

    // MARK: - Private Properties

    private let networkManager = PlexNetworkManager.shared
    private var pollingTask: Task<Void, Never>?
    private var serverSelectionTask: Task<Bool, Never>?
    private let userDefaults = UserDefaults.standard

    // UserDefaults keys (non-sensitive data only)
    private let usernameKey = "plexUsername"
    private let serverURLKey = "selectedServerURL"
    private let serverNameKey = "selectedServerName"
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
        if !hasPersistedSession && keychainHasToken {
            print("🔐 PlexAuthManager: Detected stale Keychain data from previous install — clearing")
            KeychainHelper.delete(keychainTokenKey)
            KeychainHelper.delete(keychainServerTokenKey)
            state = .idle
            return
        }

        // Load tokens from Keychain (secure)
        authToken = KeychainHelper.get(keychainTokenKey)

        // Load non-sensitive data from UserDefaults
        username = userDefaults.string(forKey: usernameKey)
        selectedServerURL = userDefaults.string(forKey: serverURLKey)

        // Load server-specific token from Keychain, fall back to user's auth token for owned servers
        let savedServerToken = KeychainHelper.get(keychainServerTokenKey)
        selectedServerToken = savedServerToken ?? authToken

        if authToken != nil {
            state = .authenticated

            // Check if saved URL is a bad Docker/internal address that slipped through
            if let url = selectedServerURL,
               let host = URL(string: url)?.host,
               isDockerOrInternalAddress(host) {
                print("🔐 PlexAuthManager: ⚠️ Saved URL uses Docker/internal address, will re-select on next server fetch")
                // Clear the bad URL - will trigger re-selection
                selectedServerURL = nil
                userDefaults.removeObject(forKey: serverURLKey)
            }
        }
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
            state = .error(message: "Failed to get PIN: \(error.localizedDescription)")
            scheduleErrorDismissal()

            // Capture PIN request failure to Sentry
            SentrySDK.capture(error: error) { scope in
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

        selectedServer = server

        // Create a tracked task for the connection test
        let task = Task { @MainActor () -> Bool in
            if let workingURL = await findBestConnection(for: server) {
                selectedServerURL = workingURL
                userDefaults.set(selectedServerURL, forKey: serverURLKey)
                userDefaults.set(server.name, forKey: serverNameKey)

                // Save the correct token for this server (securely in Keychain)
                // For shared servers, use server-specific accessToken; for owned, use user's authToken
                let tokenForServer = server.accessToken ?? authToken
                selectedServerToken = tokenForServer
                if let token = tokenForServer {
                    KeychainHelper.set(token, forKey: keychainServerTokenKey)
                }

                let isShared = server.owned == false

                isConnected = true
                connectionError = nil
                state = .authenticated

                // Prefetch libraries as part of sign-in so the sidebar renders with
                // library tabs on first build. Without this, the sidebar's
                // conditional TabSection can latch to "empty" and not recover when
                // libraries load asynchronously later.
                await PlexDataStore.shared.loadLibrariesIfNeeded()

                return true
            } else {
                isConnected = false
                connectionError = "Could not connect to server. Check your network."
                state = .error(message: "Could not connect to server. Check your network.")
                // Don't auto-dismiss - let user see the error and retry
                return false
            }
        }

        serverSelectionTask = task
        return await task.value
    }

    /// A single connection candidate to probe when resolving a server.
    private enum ConnectionCandidate: Sendable {
        /// Probe this URL directly.
        case plain(String)
        /// Probe a raw-HTTPS URL; if it fails with a TLS error that
        /// reveals the server's plex.direct hash, fall back to the
        /// matching plex.direct URL.
        case httpsWithCert(uri: String, address: String, port: Int)
    }

    /// Find the best working connection for a server.
    ///
    /// Connections are grouped into priority tiers — local non-relay >
    /// remote non-relay > relay — and every candidate URL within a tier
    /// is probed *concurrently*. The first tier with a working URL wins.
    /// Racing (rather than the old serial probe) means an unreachable
    /// address costs its tier a single timeout instead of one timeout
    /// per address compounded serially: a remote client that can't reach
    /// the server's LAN addresses used to burn ~5 s × every advertised
    /// LAN address before reaching a routable one — a multi-second
    /// stall on every server (re)connection, and a window in which a
    /// metadata request can land on a stale connection and 404. This is
    /// the connection-racing pattern Plex's own clients use.
    private func findBestConnection(for server: PlexDevice) async -> String? {
        let validConnections = (server.connections ?? [])
            .filter { !isDockerOrInternalAddress($0.address) }

        // For shared servers (not owned by the user) this is the
        // server-specific accessToken; owned servers fall back to the
        // user token at the call site.
        let tokenToUse = server.accessToken
        let httpsRequired = server.httpsRequired == true
        let machineId = server.machineIdentifier

        // If the server requires HTTPS, the valid-cert plex.direct form
        // of each local connection is preferred over everything else so
        // playback gets a trusted TLS endpoint. Race those first.
        if httpsRequired, let machineId {
            let directs = validConnections
                .filter { $0.local && !$0.relay }
                .map { ConnectionCandidate.plain(buildPlexDirectURL(
                    address: $0.address, port: $0.port, machineIdentifier: machineId)) }
            if let url = await raceCandidates(directs, serverToken: tokenToUse) {
                return url
            } else if !directs.isEmpty {
                print("🔐 PlexAuthManager: ❌ plex.direct failed, will try other connections")
            }
        }

        // Priority tiers: local non-relay > remote non-relay > relay.
        let tiers: [[PlexConnection]] = [
            validConnections.filter { $0.local && !$0.relay },
            validConnections.filter { !$0.local && !$0.relay },
            validConnections.filter { $0.relay },
        ]
        for tier in tiers where !tier.isEmpty {
            var candidates: [ConnectionCandidate] = []
            for connection in tier {
                candidates.append(.plain(connection.uri))
                // An http connection that's dead may still be reachable
                // over TLS (server has "Require Secure Connections" on):
                // also try the local plex.direct form (valid cert) and a
                // raw-HTTPS upgrade.
                if connection.protocolType == "http" {
                    if connection.local, let machineId {
                        candidates.append(.plain(buildPlexDirectURL(
                            address: connection.address, port: connection.port,
                            machineIdentifier: machineId)))
                    }
                    let httpsURI = connection.uri.replacingOccurrences(
                        of: "http://", with: "https://")
                    candidates.append(.httpsWithCert(
                        uri: httpsURI, address: connection.address, port: connection.port))
                }
            }
            if let url = await raceCandidates(candidates, serverToken: tokenToUse) {
                return url
            }
        }

        return nil
    }

    /// Probe every candidate concurrently; return the first that
    /// resolves to a working URL, cancelling the rest. nil if none do.
    private func raceCandidates(
        _ candidates: [ConnectionCandidate],
        serverToken: String?
    ) async -> String? {
        guard !candidates.isEmpty else { return nil }
        return await withTaskGroup(of: String?.self) { group in
            for candidate in candidates {
                group.addTask { await self.resolveCandidate(candidate, serverToken: serverToken) }
            }
            for await result in group {
                if let url = result {
                    group.cancelAll()
                    return url
                }
            }
            return nil
        }
    }

    /// Resolve a single candidate to a working URL, or nil.
    private func resolveCandidate(
        _ candidate: ConnectionCandidate,
        serverToken: String?
    ) async -> String? {
        switch candidate {
        case .plain(let url):
            return await testConnection(url, serverToken: serverToken) ? url : nil
        case .httpsWithCert(let uri, let address, let port):
            let (success, certHash) = await testConnectionWithCertExtraction(
                uri, serverToken: serverToken)
            if success {
                return uri
            }
            // The raw-HTTPS attempt failed; if its TLS error revealed
            // the server's plex.direct hash, try that valid-cert URL.
            if let hash = certHash {
                let plexDirectURI = buildPlexDirectURL(
                    address: address, port: port, machineIdentifier: hash)
                if await testConnection(plexDirectURI, serverToken: serverToken) {
                    return plexDirectURI
                }
            }
            return nil
        }
    }

    /// Build a plex.direct URL for secure remote access
    /// Plex issues SSL certificates for *.plex.direct domains
    /// Format: https://<ip-with-dashes>.<machineIdentifier>.plex.direct:<port>
    private func buildPlexDirectURL(address: String, port: Int, machineIdentifier: String) -> String {
        let ipWithDashes = address.replacingOccurrences(of: ".", with: "-")
        return "https://\(ipWithDashes).\(machineIdentifier).plex.direct:\(port)"
    }

    /// Check if address is a Docker/internal bridge network
    private func isDockerOrInternalAddress(_ address: String) -> Bool {
        // Docker default bridge networks (172.17-31.x.x range)
        // Note: We intentionally do NOT filter 10.x.x.x as these are common home network ranges
        let dockerPrefixes = [
            "172.17.", "172.18.", "172.19.", "172.20.", "172.21.",
            "172.22.", "172.23.", "172.24.", "172.25.", "172.26.",
            "172.27.", "172.28.", "172.29.", "172.30.", "172.31.",
        ]

        // Localhost variants (not useful for Apple TV)
        let localhostAddresses = ["127.0.0.1", "localhost", "::1"]

        for prefix in dockerPrefixes {
            if address.hasPrefix(prefix) {
                return true
            }
        }

        if localhostAddresses.contains(address) {
            return true
        }

        return false
    }

    /// Test if a connection URL is reachable
    /// - Parameters:
    ///   - urlString: The connection URL to test
    ///   - serverToken: Server-specific access token (for shared servers), falls back to user's authToken
    private func testConnection(_ urlString: String, serverToken: String? = nil) async -> Bool {
        guard let token = serverToken ?? authToken,
              let url = URL(string: "\(urlString)/identity") else {
            return false
        }

        do {
            // Quick connectivity test with short timeout
            var request = URLRequest(url: url)
            // 3 s — /identity is a tiny response; a reachable server
            // answers well within this. A tight cap bounds how long an
            // unreachable address can stall a connection race.
            request.timeoutInterval = 3.0
            request.addValue("application/json", forHTTPHeaderField: "Accept")
            request.addValue(token, forHTTPHeaderField: "X-Plex-Token")

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 3.0
            config.timeoutIntervalForResource = 3.0

            // Use a delegate that trusts self-signed certs for Plex
            let session = URLSession(configuration: config, delegate: PlexCertificateDelegate(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }

            let (_, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                return (200...299).contains(httpResponse.statusCode)
            }
            return false
        } catch {
            print("🔐 PlexAuthManager: Connection test error: \(error.localizedDescription)")
            return false
        }
    }

    /// Test connection and extract plex.direct hash from certificate if it fails
    /// Returns (success, extractedHash) where extractedHash is the plex.direct hash from the cert
    private func testConnectionWithCertExtraction(_ urlString: String, serverToken: String? = nil) async -> (Bool, String?) {
        guard let token = serverToken ?? authToken,
              let url = URL(string: "\(urlString)/identity") else {
            return (false, nil)
        }

        do {
            var request = URLRequest(url: url)
            // 3 s — /identity is a tiny response; a reachable server
            // answers well within this. A tight cap bounds how long an
            // unreachable address can stall a connection race.
            request.timeoutInterval = 3.0
            request.addValue("application/json", forHTTPHeaderField: "Accept")
            request.addValue(token, forHTTPHeaderField: "X-Plex-Token")

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 3.0
            config.timeoutIntervalForResource = 3.0

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

    /// Sign out and clear credentials
    func signOut() {
        pollingTask?.cancel()
        pollingTask = nil

        authToken = nil
        username = nil
        selectedServer = nil
        selectedServerURL = nil
        selectedServerToken = nil
        isConnected = true  // Reset to default
        connectionError = nil

        // Clear tokens from Keychain (secure storage)
        KeychainHelper.delete(keychainTokenKey)
        KeychainHelper.delete(keychainServerTokenKey)

        // Clear non-sensitive data from UserDefaults
        userDefaults.removeObject(forKey: usernameKey)
        userDefaults.removeObject(forKey: serverURLKey)
        userDefaults.removeObject(forKey: serverNameKey)
        userDefaults.removeObject(forKey: hasPersistedSessionKey)

        // Clear any legacy tokens that might still exist
        userDefaults.removeObject(forKey: legacyTokenKey)
        userDefaults.removeObject(forKey: legacyServerTokenKey)

        // Clear user profile selection
        PlexUserProfileManager.shared.reset()

        state = .idle
    }

    /// Reset error state
    func reset() {
        pollingTask?.cancel()
        pollingTask = nil
        state = .idle
    }

    /// Update the server token for user profile switching
    /// This is called when switching Plex Home users to use their specific token
    func updateServerToken(_ token: String) {
        selectedServerToken = token
        // Note: We don't persist this to UserDefaults since it's session-specific
        // On next app launch, we'll fetch users again and switch if needed
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
                print("🔐 PlexAuthManager: Failed to fetch servers: \(error)")
                isConnected = false
                connectionError = "Unable to reach Plex. Check your network connection."

                // Capture server fetch failure to Sentry
                SentrySDK.capture(error: error) { scope in
                    scope.setTag(value: "plex_auth", key: "component")
                    scope.setTag(value: "server_discovery", key: "auth_step")
                }
            }
            return
        }

        // Test current connection using the saved server token
        guard let currentURL = selectedServerURL else { return }

        if await testConnection(currentURL, serverToken: selectedServerToken) {
            isConnected = true
            connectionError = nil

            // Fetch home users for profile switching (if not already loaded)
            if !PlexUserProfileManager.shared.hasLoadedProfiles {
                await PlexUserProfileManager.shared.fetchHomeUsers()
            }
        } else {
            print("🔐 PlexAuthManager: ❌ Current connection failed")
            isConnected = false
            connectionError = "Cannot connect to Plex server"

            // Try to find a better connection without clearing credentials
            // This allows cached content to still be shown
            do {
                let servers = try await networkManager.getServers(authToken: token)
                if let currentServer = servers.first(where: { server in
                    server.connections?.contains { $0.uri == currentURL } == true
                }) ?? servers.first {
                    // Try to find a working connection on this server
                    if let workingURL = await findBestConnection(for: currentServer) {
                        selectedServerURL = workingURL
                        userDefaults.set(selectedServerURL, forKey: serverURLKey)
                        userDefaults.set(currentServer.name, forKey: serverNameKey)

                        // Update server token for new server (securely in Keychain)
                        let tokenForServer = currentServer.accessToken ?? authToken
                        selectedServerToken = tokenForServer
                        if let newToken = tokenForServer {
                            KeychainHelper.set(newToken, forKey: keychainServerTokenKey)
                        }

                        isConnected = true
                        connectionError = nil
                        state = .authenticated
                    }
                }
            } catch {
                print("🔐 PlexAuthManager: Failed to fetch servers for re-selection: \(error)")
                // Keep existing credentials - just mark as not connected
                // User can still see cached content

                // Capture connection verification failure to Sentry
                SentrySDK.capture(error: error) { scope in
                    scope.setTag(value: "plex_auth", key: "component")
                    scope.setTag(value: "connection_verify", key: "auth_step")
                    scope.setExtra(value: currentURL, key: "failed_url")
                }
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
                        state = .error(message: "Authentication check failed: \(error.localizedDescription)")
                        scheduleErrorDismissal()
                    }
                    return
                }
            }

            if !Task.isCancelled {
                state = .error(message: "PIN expired. Please try again.")
                scheduleErrorDismissal()
            }
        }
    }

    private func handleSuccessfulAuth(token: String) async {
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
        do {
            let servers = try await networkManager.getServers(authToken: token)

            if servers.isEmpty {
                state = .error(message: "No Plex servers found on your account")
                scheduleErrorDismissal()
            } else if servers.count == 1 {
                // Auto-select if only one server - await to ensure connection is established
                await selectServer(servers[0])
            } else {
                // Show server selection
                state = .selectingServer(servers: servers)
            }
        } catch {
            state = .error(message: "Failed to fetch servers: \(error.localizedDescription)")
            scheduleErrorDismissal()
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

            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let name = json["username"] as? String ?? json["friendlyName"] as? String {
                username = name
                userDefaults.set(name, forKey: usernameKey)
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

// MARK: - Auth URL Helper

extension PlexAuthManager {
    /// Get the URL for users to authenticate via browser
    var authURL: URL? {
        guard case .waitingForPIN(let code, _) = state else { return nil }

        var components = URLComponents(string: "https://app.plex.tv/auth")!
        components.fragment = "?clientID=\(PlexAPI.clientIdentifier)&code=\(code)&context[device][product]=Rivulet"
        return components.url
    }
}

// MARK: - Certificate Delegate for Connection Testing

/// URLSession delegate that trusts self-signed certificates for Plex servers
class PlexCertificateDelegate: NSObject, URLSessionDelegate {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port

        // Trust self-signed certificates for:
        // - IP addresses (local Plex servers)
        // - plex.direct domains
        // - Port 32400 (default Plex port)
        let isIPAddress = host.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#, options: .regularExpression) != nil
        let isPlexDirect = host.hasSuffix(".plex.direct")
        let isPlexPort = port == 32400

        if isIPAddress || isPlexDirect || isPlexPort {
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
