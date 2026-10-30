// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Active media provider instances, keyed by stable server/profile identity.

import Foundation

@Observable @MainActor
final class MediaProviderRegistry {
    static let shared = MediaProviderRegistry()

    private(set) var providers: [String: any MediaProvider] = [:]

    func provider(for id: String) -> (any MediaProvider)? {
        providers[id]
    }

    /// Stable ids can recur after signout or profile switches; a prepared stream
    /// may only cross the presentation boundary under the same captured authority.
    func isCurrentAuthority(_ provider: any MediaProvider) -> Bool {
        guard let current = providers[provider.id] else { return false }
        return current.authorityRevision == provider.authorityRevision && current.accountID == provider.accountID
    }

    func enabledProviders() -> [any MediaProvider] {
        Array(providers.values)
    }

    /// The Plex provider registered last. Earlier ones stay registered: a
    /// restored session ids its server by a hash of the URL, so a mid-session
    /// URL change (connection upgrade, failover) mints a new id while tiles
    /// on screen still carry the old one.
    private var currentPlexID: String?

    /// The signed-in Plex server. Code that maps Plex hubs or metadata into
    /// `MediaItem`s mints its refs from this. Never "first provider": with a
    /// second backend registered that could be the Jellyfin one.
    var plexProvider: (any MediaProvider)? {
        currentPlexID.flatMap { providers[$0] }
    }

    /// The account's other Plex servers, by name (`PlexExtraServers`).
    private var extraPlexIDs: [String] = [] {
        didSet {
            guard self === Self.shared else { return }
            MediaItemRef.extraPlexIDs.withLock { [extraPlexIDs] in $0 = Set(extraPlexIDs) }
        }
    }

    /// Other Plex servers in account order, followed by native servers in stable name order.
    var secondaryProviders: [any MediaProvider] {
        extraPlexIDs.compactMap { providers[$0] }
            + providers.values.filter { $0.kind != .plex }.sorted {
                ($0.displayName, $0.id) < ($1.displayName, $1.id)
            }
    }

    /// The Plex server an item lives on: an extra server's own address and
    /// token, else the selected server's (live, so a connection upgrade counts).
    func plexServer(for providerID: String?) -> PlexServerAddress? {
        if let providerID, extraPlexIDs.contains(providerID), let plex = providers[providerID] as? PlexProvider {
            return PlexServerAddress(address: plex.serverURL, token: plex.authToken)
        }
        let auth = PlexAuthManager.shared
        guard let url = auth.selectedServerURL, let token = auth.selectedServerToken else { return nil }
        return PlexServerAddress(address: url, token: token)
    }

    func register(_ provider: any MediaProvider) {
        providers[provider.id] = provider
        if provider.kind == .plex { currentPlexID = provider.id }
    }

    func unregister(providerID: String) {
        providers.removeValue(forKey: providerID)
        if providerID == currentPlexID { currentPlexID = nil }
    }

    /// Brings providers in line with the selected Plex account and signed-in native server profiles.
    func populateFromCurrentAuth() {
        let auth = PlexAuthManager.shared
        let extras = PlexExtraServers.shared
        populate(
            plexServerURL: auth.selectedServerURL,
            plexToken: auth.selectedServerToken,
            plexMachineID: auth.selectedServerMachineID,
            plexName: auth.selectedServer?.name
                ?? UserDefaults.standard.string(forKey: "selectedServerName")
                ?? "Plex",
            extraPlex: extras.current.compactMap { server in
                extras.token(for: server).map { (server, $0) }
            },
            plexOwnerID: String(auth.contentOwnerID)
        )
    }

    /// `populateFromCurrentAuth` with the Plex sign-in passed in, so the
    /// registry's rules are testable without a real Plex account.
    func populate(plexServerURL: String?, plexToken: String?, plexMachineID: String?, plexName: String,
                  extraPlex: [(server: PlexExtraServers.Server, token: String)] = [], plexOwnerID: String? = nil) {
        // Other servers' library settings belong to their own users (an extra
        // Plex server's to the profile), so they load with the sign-in.
        defer {
            LibrarySettingsManager.shared.setProviderScopes(secondaryProviders
                .sorted { $0.id < $1.id }
                .map { .init(providerID: $0.id, accountID: $0.accountID) })
        }
        providers = providers.filter { $0.value.kind == .plex && !extraPlexIDs.contains($0.key) }
        extraPlexIDs = []
        if let jellyfin = JellyfinSession.storedProvider() { register(jellyfin) }
        if let silo = SiloSession.storedProvider() { register(silo) }
        guard let serverURL = plexServerURL, let token = plexToken else {
            providers = providers.filter { $0.value.kind != .plex }
            currentPlexID = nil
            return
        }
        // Prefer Plex's real machineIdentifier when the user has selected a
        // server in this session. Fall back to a deterministic hash of the
        // server URL when only a restored URL/token is available — this keeps
        // providerID stable across launches (Swift's String.hashValue is
        // randomized per process and would orphan FocusMemory / nav state).
        let machineID = plexMachineID ?? Self.stableHash(of: serverURL)
        register(PlexProvider(
            machineIdentifier: machineID,
            displayName: plexName,
            serverURL: serverURL,
            authToken: token
        ))
        for (server, token) in extraPlex where server.machineID != machineID {
            providers[server.providerID] = PlexProvider(machineIdentifier: server.machineID, displayName: server.name,
                                                        serverURL: server.url, authToken: token, accountID: plexOwnerID)
            extraPlexIDs.append(server.providerID)
        }
    }

    /// Process-stable hash. Avoid `String.hashValue` (per-process randomized).
    private static func stableHash(of input: String) -> String {
        // FNV-1a 64-bit — small, deterministic, no Crypto dependency.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
