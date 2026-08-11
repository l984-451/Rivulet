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

    /// Handoffs to whatever holds cached library / hub / metadata content.
    ///
    /// This manager owns identity, not content, and the content store is per
    /// platform: tvOS has `PlexDataStore`, iOS has `IOSPlexSession`. Calling
    /// `PlexDataStore.shared` directly from here is what kept the whole auth
    /// stack pinned to the tvOS target. The host sets these at launch.
    ///
    /// `onAuthenticated` is awaited on purpose. It prefetches libraries as part
    /// of sign-in so the sidebar renders with library tabs on its first build;
    /// fire-and-forget would reintroduce the empty-latch it was added to fix.
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
    private let userThumbKey = "plexUserThumb"
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
        userThumbURL = userDefaults.string(forKey: userThumbKey).flatMap { URL(string: $0) }
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
                // Flip identity + URL + token atomically once the connection
                // is verified. Setting `selectedServer = server` eagerly
                // (before the async test) caused a confusing UI / data-
                // fetch mismatch on multi-server accounts: views bound to
                // `selectedServer.name` showed the newly-picked server's
                // name while in-flight fetches still used the previous
                // `selectedServerURL`. On a failed connection test the
                // same path left users staring at a "you are on server X"
                // label while data continued to come from whichever server
                // they'd been on before. User-visible symptom: the UI
                // labels you as on one Plex server while the libraries
                // and items you see come from a different one.
                selectedServer = server
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
                await Self.onAuthenticated?()

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

    /// Find the best working connection for a server.
    ///
    /// Launch-latency design (2026-06-10): the old implementation probed
    /// candidates SERIALLY with a 5s timeout each — a few dead candidates
    /// (stale local IP, unresolvable plex.direct, blocked HTTPS) meant 15-30s
    /// of black screen before any content could fetch. Now:
    ///  1. FAST PATH: the persisted last-known-good URL is tested first and
    ///     used immediately when it still works (typical warm launch: <1s).
    ///  2. Otherwise all candidate CHAINS probe in PARALLEL and the winner is
    ///     the first success in PRIORITY order (a slow-but-better chain still
    ///     beats a fast-but-worse one; relay only wins when everything above
    ///     it has completed and failed). Worst case ≈ the slowest single
    ///     chain instead of the sum of all of them.
    ///
    /// Chain priority (unchanged semantics from the serial ladder):
    /// - If httpsRequired=true + local: plex.direct (valid TLS cert) > HTTP > HTTPS
    /// - If httpsRequired=false + local: HTTP (fastest) > plex.direct
    /// - Remote: plex.direct URLs from the API
    /// - Relay: strictly last resort
    private func findBestConnection(for server: PlexDevice) async -> String? {
        // For shared servers (not owned by user), use server-specific accessToken
        let tokenToUse = server.accessToken

        // FAST PATH — last-known-good URL, but only when it plausibly belongs
        // to THIS server (matching a connection's host:port or embedding the
        // machineIdentifier, as plex.direct URLs do). Guards the switch-server
        // flow against reusing another server's URL.
        if let lastGood = selectedServerURL, urlBelongs(lastGood, to: server) {
            print("🔐 PlexAuthManager: Trying last-known-good URL first: \(lastGood)")
            if await testConnection(lastGood, serverToken: tokenToUse) {
                print("🔐 PlexAuthManager: ✅ Last-known-good works — skipping the probe ladder")
                return lastGood
            }
            print("🔐 PlexAuthManager: ❌ Last-known-good failed; racing all candidates")
        }

        let validConnections = (server.connections ?? [])
            .filter { !isDockerOrInternalAddress($0.address) }

        // Sort by preference: local non-relay > remote > relay
        let sortedConnections = validConnections.sorted { conn1, conn2 in
            connectionScore(conn1) > connectionScore(conn2)
        }

        // Build the prioritized probe chains. Index order IS the priority order.
        // Each chain tries the connection's advertised URI (now an https
        // plex.direct URL with a valid cert) and, for http-only connections,
        // upgrades to HTTPS via certificate extraction.
        var chains: [() async -> String?] = []

        // One chain per candidate connection, in score order.
        for connection in sortedConnections {
            chains.append { [weak self] in
                await self?.probeConnectionChain(connection, tokenToUse: tokenToUse)
            }
        }

        // Strictly last: relay. As the lowest-priority chain it can only win
        // once every chain above it has completed and failed.
        if let relayConnection = server.connections?.first(where: { $0.relay }) {
            chains.append { [weak self] in
                guard let self else { return nil }
                print("🔐 PlexAuthManager: Trying relay as fallback: \(relayConnection.uri)")
                if await self.testConnection(relayConnection.uri, serverToken: tokenToUse) {
                    return relayConnection.uri
                }
                return nil
            }
        }

        guard !chains.isEmpty else { return nil }
        if let winner = await raceByPriority(chains) {
            return winner
        }

        // Every candidate failed. Capture with a privacy-trimmed candidate
        // summary — the per-probe breadcrumbs above carry the failure detail.
        // Address CLASS only (never the address itself).
        let candidateSummary = sortedConnections.map { conn -> String in
            let kind = conn.relay ? "relay" : (conn.local ? "local" : "remote")
            let net = conn.uri.contains(".plex.direct") ? "plex.direct" : "raw"
            return "\(conn.protocolType)/\(kind)/\(net):\(conn.port)"
        }.joined(separator: ",")
        let serverName = server.name
        SentryBridge.capture(error: NSError(
            domain: "PlexAuthConnection",
            code: -1,
            userInfo: [NSLocalizedDescriptionKey: "All server connection candidates failed"]
        )) { scope in
            scope.setTag(value: "plex_auth", key: "component")
            scope.setTag(value: "server_connect_failed", key: "operation")
            scope.setExtra(value: serverName, key: "server_name")
            scope.setExtra(value: candidateSummary, key: "candidates")
        }
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

    /// Per-connection cascade: try the advertised URI directly, then (for an
    /// http connection) raw HTTPS with certificate extraction, then a
    /// plex.direct URL built from the extracted cert hash.
    private func probeConnectionChain(
        _ connection: PlexConnection,
        tokenToUse: String?
    ) async -> String? {
        if await testConnection(connection.uri, serverToken: tokenToUse) {
            return connection.uri
        }
        print("🔐 PlexAuthManager: ❌ Connection failed: \(connection.uri)")

        // HTTPS candidates advertise a plex.direct URI. Routers with DNS
        // rebinding protection refuse plex.direct names that resolve to
        // private IPs, so the advertised URI can fail while the server itself
        // is perfectly reachable (GitHub #224 — official clients fall back to
        // the raw address, so "Plex app works, Rivulet doesn't"). Fall back to
        // the raw address over HTTPS (PlexCertificateDelegate trusts the Plex
        // cert), then plain HTTP for local connections.
        guard connection.protocolType == "http" else {
            let host = connection.IPv6 ? "[\(connection.address)]" : connection.address
            let rawHTTPS = "https://\(host):\(connection.port)"
            print("🔐 PlexAuthManager: Trying raw-address fallback: \(rawHTTPS)")
            if await testConnection(rawHTTPS, serverToken: tokenToUse) {
                return rawHTTPS
            }
            if connection.local {
                let rawHTTP = "http://\(host):\(connection.port)"
                print("🔐 PlexAuthManager: Trying raw-address fallback: \(rawHTTP)")
                if await testConnection(rawHTTP, serverToken: tokenToUse) {
                    return rawHTTP
                }
            }
            return nil
        }

        // Try raw HTTPS as last resort for this connection.
        // API calls can trust self-signed certs, but media playback should prefer a valid TLS endpoint.
        let httpsURI = connection.uri.replacingOccurrences(of: "http://", with: "https://")
        print("🔐 PlexAuthManager: Trying HTTPS fallback: \(httpsURI)...")
        let (success, certHash) = await testConnectionWithCertExtraction(httpsURI, serverToken: tokenToUse)
        if success {
            // If we have a cert hash, prefer plex.direct for playback compatibility
            if let hash = certHash {
                let plexDirectURI = buildPlexDirectURL(
                    address: connection.address,
                    port: connection.port,
                    subdomainHash: hash
                )
                if await testConnection(plexDirectURI, serverToken: tokenToUse) {
                    return plexDirectURI
                }
            }
            // Fall back to raw HTTPS if plex.direct failed
            print("🔐 PlexAuthManager: ✅ HTTPS fallback works: \(httpsURI)")
            return httpsURI
        }
        print("🔐 PlexAuthManager: ❌ HTTPS fallback failed: \(httpsURI)")

        // If we extracted a plex.direct hash from the certificate error, try that
        if let hash = certHash {
            let plexDirectURI = buildPlexDirectURL(
                address: connection.address,
                port: connection.port,
                subdomainHash: hash
            )
            if await testConnection(plexDirectURI, serverToken: tokenToUse) {
                return plexDirectURI
            }
            print("🔐 PlexAuthManager: ❌ plex.direct failed: \(plexDirectURI)")
        }
        return nil
    }

    /// Whether a persisted URL plausibly belongs to `server`: its host:port
    /// matches one of the server's advertised connections (http or https), or
    /// the URL embeds the server's machineIdentifier (plex.direct form).
    private func urlBelongs(_ urlString: String, to server: PlexDevice) -> Bool {
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
    private func connectionScore(_ connection: PlexConnection) -> Int {
        var score = 0

        // Prefer non-relay (direct connections)
        if !connection.relay { score += 1000 }

        // Prefer local connections
        if connection.local {
            score += 500
            // For local: prefer HTTP (avoids certificate issues)
            if connection.protocolType == "http" { score += 50 }
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
            request.timeoutInterval = 5.0
            request.addValue("application/json", forHTTPHeaderField: "Accept")
            request.addValue(token, forHTTPHeaderField: "X-Plex-Token")

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 5.0
            config.timeoutIntervalForResource = 5.0

            // Use a delegate that trusts self-signed certs for Plex
            let session = URLSession(configuration: config, delegate: PlexCertificateDelegate(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }

            let (_, response) = try await session.data(for: request)

            if let httpResponse = response as? HTTPURLResponse {
                let ok = (200...299).contains(httpResponse.statusCode)
                if !ok {
                    Self.addConnectionTestBreadcrumb(
                        urlString: urlString, outcome: "http_\(httpResponse.statusCode)")
                }
                return ok
            }
            return false
        } catch {
            print("🔐 PlexAuthManager: Connection test error: \(error.localizedDescription)")
            let nsError = error as NSError
            Self.addConnectionTestBreadcrumb(
                urlString: urlString, outcome: "\(nsError.domain)#\(nsError.code)")
            return false
        }
    }

    /// One breadcrumb per failed connection probe, so a later "all candidates
    /// failed" capture carries the exact per-candidate failure trail
    /// (GitHub #224 — these failures used to be print-only and invisible).
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
    private func testConnectionWithCertExtraction(_ urlString: String, serverToken: String? = nil) async -> (Bool, String?) {
        guard let token = serverToken ?? authToken,
              let url = URL(string: "\(urlString)/identity") else {
            return (false, nil)
        }

        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 5.0
            request.addValue("application/json", forHTTPHeaderField: "Accept")
            request.addValue(token, forHTTPHeaderField: "X-Plex-Token")

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

    /// Sign out and clear credentials
    func signOut() {
        pollingTask?.cancel()
        pollingTask = nil

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

        // Clear non-sensitive data from UserDefaults
        userDefaults.removeObject(forKey: usernameKey)
        userDefaults.removeObject(forKey: userThumbKey)
        userDefaults.removeObject(forKey: serverURLKey)
        userDefaults.removeObject(forKey: serverNameKey)
        userDefaults.removeObject(forKey: hasPersistedSessionKey)

        // Clear any legacy tokens that might still exist
        userDefaults.removeObject(forKey: legacyTokenKey)
        userDefaults.removeObject(forKey: legacyServerTokenKey)

        // Clear user profile selection
        PlexUserProfileManager.shared.reset()

        // Clear cached library / hub / metadata content from the previous
        // session. Without this, after a sign-out + sign-in to a different
        // server (or even the same one), the user sees the previous
        // session's cached hubs and libraries until fresh fetches replace
        // them — visually confusing on a multi-server account because the
        // UI labels the connection with the new server while showing the
        // previous server's content.
        Self.onSignedOut?()

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
                SentryBridge.capture(error: error) { scope in
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
            // This allows cached content to still be shown.
            //
            // Match the saved server by URL first, then by saved name as a
            // fallback (Plex occasionally rotates a server's connection
            // URIs, which breaks URL-matching while the name stays stable).
            // If neither identifies the saved server, leave selection alone
            // — the prior `?? servers.first` fallback silently swapped users
            // to whichever server happened to be first in the account's
            // server list, which on a multi-server account (e.g. own + shared)
            // could pull them onto the wrong server entirely.
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
                SentryBridge.capture(error: error) { scope in
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
        await resumeServerSelection()
    }

    /// Fetch the account's servers and enter selection (or auto-select a
    /// single server). Used at the end of PIN auth AND to recover the
    /// account-linked-but-no-server state: a failed first connection used to
    /// strand users on a "Connected!" dead end with no way to retry or
    /// unlink (GitHub #224).
    func resumeServerSelection() async {
        guard let token = authToken else { return }
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
