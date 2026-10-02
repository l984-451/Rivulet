// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaProviderRegistry.swift
//  Rivulet
//
//  Single source of truth for active MediaProvider instances. Phase 2 wires
//  this to populate from CredentialRegistry / PlexAuthManager. Wave 1 single-
//  server reality: at most one Plex provider entry. Multi-server support
//  arrives in a later wave.
//

import Foundation

@Observable @MainActor
final class MediaProviderRegistry {
    static let shared = MediaProviderRegistry()

    private(set) var providers: [String: any MediaProvider] = [:]

    func provider(for id: String) -> (any MediaProvider)? {
        providers[id]
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

    func register(_ provider: any MediaProvider) {
        providers[provider.id] = provider
        if provider.kind == .plex { currentPlexID = provider.id }
    }

    func unregister(providerID: String) {
        providers.removeValue(forKey: providerID)
        if providerID == currentPlexID { currentPlexID = nil }
    }

    /// Brings the registry in line with what is signed in: the Plex server from
    /// `PlexAuthManager`, the Jellyfin server from `JellyfinSession`. Called at
    /// launch, after any Plex auth change (ContentView), and after Jellyfin
    /// sign-in or sign-out. Jellyfin is rebuilt from its stored account each
    /// time; Plex entries go only when Plex is signed out.
    func populateFromCurrentAuth() {
        let auth = PlexAuthManager.shared
        populate(
            plexServerURL: auth.selectedServerURL,
            plexToken: auth.selectedServerToken,
            plexMachineID: auth.selectedServer?.machineIdentifier,
            plexName: auth.selectedServer?.name
                ?? UserDefaults.standard.string(forKey: "selectedServerName")
                ?? "Plex"
        )
    }

    /// `populateFromCurrentAuth` with the Plex sign-in passed in, so the
    /// registry's rules are testable without a real Plex account.
    func populate(plexServerURL: String?, plexToken: String?, plexMachineID: String?, plexName: String) {
        // Non-Plex servers' library settings belong to their own users, so
        // they load and unload with the sign-in, not the Plex profile.
        defer {
            LibrarySettingsManager.shared.setProviderScopes(providers.values
                .filter { $0.kind != .plex }
                .sorted { $0.id < $1.id }
                .map { .init(providerID: $0.id, accountID: $0.accountID) })
        }
        providers = providers.filter { $0.value.kind != .jellyfin }
        if let jellyfin = JellyfinSession.storedProvider() { register(jellyfin) }
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
