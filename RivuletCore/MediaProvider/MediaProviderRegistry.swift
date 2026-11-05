// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The active MediaProvider instances (the Plex servers and one server per other kind), keyed by id.

import Foundation
import Synchronization

@Observable @MainActor
final class MediaProviderRegistry {
    static let shared = MediaProviderRegistry()

    private(set) var providers: [String: any MediaProvider] = [:]

    /// Whether the Plex providers list a library's collections beside its titles. The iOS app
    /// turns it off at launch, before the first `populate`.
    static var plexIncludesCollections = true

    /// Told the other servers after each populate. tvOS loads their library settings here.
    @ObservationIgnored var onSecondaryProvidersChanged: (([any MediaProvider]) -> Void)?

    func provider(for id: String) -> (any MediaProvider)? {
        providers[id]
    }

    func enabledProviders() -> [any MediaProvider] {
        Array(providers.values)
    }

    /// The kind of the server a provider id names: the registered provider's,
    /// else what the id says (a server signed out under tiles still on screen).
    func kind(of providerID: String) -> MediaProviderKind? {
        providers[providerID]?.kind ?? MediaProviderKind(providerID: providerID)
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

    /// Every server Home and the sidebar show beside the selected Plex server:
    /// the extra Plex servers in their given order (by name), then each other
    /// kind in `MediaProviderKind` order, a kind's servers sorted by id.
    var secondaryProviders: [any MediaProvider] {
        extraPlexIDs.compactMap { providers[$0] }
            + MediaProviderKind.otherServerKinds.flatMap { kind in
                providers.values.filter { $0.kind == kind }.sorted { $0.id < $1.id }
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
        if provider.kind == .plex {
            currentPlexID = provider.id
            if self === Self.shared { MediaItemRef.selectedPlexIDs.withLock { _ = $0.insert(provider.id) } }
        }
    }

    func unregister(providerID: String) {
        providers.removeValue(forKey: providerID)
        if providerID == currentPlexID { currentPlexID = nil }
        if self === Self.shared { MediaItemRef.selectedPlexIDs.withLock { _ = $0.remove(providerID) } }
    }

    /// Brings the registry in line with what is signed in: the Plex server from
    /// `PlexAuthManager`, each other kind's server from its stored account
    /// (`OtherServerKind`). Called at launch, after any Plex auth change
    /// (ContentView), and after another server's sign-in or sign-out. Those
    /// are rebuilt from their stored accounts each time; Plex entries go only
    /// when Plex is signed out.
    func populateFromCurrentAuth() {
        let auth = PlexAuthManager.shared
        let extras = PlexExtraServers.shared
        populate(
            plexServerURL: auth.selectedServerURL,
            plexToken: auth.selectedServerToken,
            plexMachineID: auth.selectedServer?.machineIdentifier,
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
        defer { onSecondaryProvidersChanged?(secondaryProviders) }
        providers = providers.filter { $0.value.kind == .plex && !extraPlexIDs.contains($0.key) }
        extraPlexIDs = []
        for other in OtherServerKind.all {
            if let stored = other.storedProvider() { register(stored) }
        }
        guard let serverURL = plexServerURL, let token = plexToken else {
            providers = providers.filter { $0.value.kind != .plex }
            currentPlexID = nil
            if self === Self.shared { MediaItemRef.selectedPlexIDs.withLock { $0 = [] } }
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
            authToken: token,
            includesCollections: Self.plexIncludesCollections
        ))
        for (server, token) in extraPlex where server.machineID != machineID {
            providers[server.providerID] = PlexProvider(machineIdentifier: server.machineID, displayName: server.name,
                                                        serverURL: server.url, authToken: token, accountID: plexOwnerID,
                                                        includesCollections: Self.plexIncludesCollections)
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
