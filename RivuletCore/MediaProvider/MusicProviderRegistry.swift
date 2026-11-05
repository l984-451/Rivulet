// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MusicProviderRegistry.swift
//  Rivulet
//
//  Sibling to MediaProviderRegistry, holding MusicProvider instances keyed
//  by provider ID. Same ID convention ("plex:<machineID>") lets a single
//  backend register into both registries and be cross-referenced via
//  MediaItemRef.providerID.
//

import Foundation

@Observable @MainActor
final class MusicProviderRegistry {
    static let shared = MusicProviderRegistry()

    private(set) var providers: [String: any MusicProvider] = [:]

    /// Counts rebuilds from auth (sign-in, sign-out, server or profile switch),
    /// so a per-account cache knows when to refetch.
    private(set) var generation = 0

    func provider(for id: String) -> (any MusicProvider)? {
        providers[id]
    }

    /// The provider that owns an item.
    func provider(for ref: MediaItemRef) -> (any MusicProvider)? {
        providers[ref.providerID]
    }

    /// The Plex provider registered last. Earlier ones stay, as in `MediaProviderRegistry`:
    /// a restored session ids its server by a hash of the URL, so a new address mints a new
    /// id while queued tracks and open pages still carry the old one.
    private var currentPlexID: String?

    /// The signed-in server. Never "first provider": a stale entry could come first.
    var primaryProvider: (any MusicProvider)? {
        currentPlexID.flatMap { providers[$0] }
    }

    /// Each signed-in server once, Plex first, then each other kind in
    /// `MediaProviderKind` order (a kind's servers sorted by id). Stale Plex ids kept for old refs are left out.
    var signedInProviders: [any MusicProvider] {
        [primaryProvider].compactMap { $0 }
            + MediaProviderKind.otherServerKinds.flatMap { kind in
                providers.values.filter { $0.kind == kind }.sorted { $0.id < $1.id }
            }
    }

    func register(_ provider: any MusicProvider) {
        providers[provider.id] = provider
        if provider.kind == .plex { currentPlexID = provider.id }
    }

    func unregister(providerID: String) {
        providers.removeValue(forKey: providerID)
        if providerID == currentPlexID { currentPlexID = nil }
    }

    /// Brings the registry in line with what is signed in: the Plex server from
    /// `PlexAuthManager.shared`, each other kind's server from its stored account
    /// (`OtherServerKind`). Called at app launch, after Plex auth changes (sign-in,
    /// sign-out, server switch), and after another server's sign-in or sign-out.
    func populateFromCurrentAuth() {
        OtherServerKind.all.forEach(populateOtherServer)
        let auth = PlexAuthManager.shared
        guard
            let serverURL = auth.selectedServerURL,
            let token = auth.selectedServerToken
        else {
            if providers.values.contains(where: { $0.kind == .plex }) { generation += 1 }
            providers = providers.filter { $0.value.kind != .plex }
            currentPlexID = nil
            return
        }
        let machineID: String = {
            if let id = auth.selectedServer?.machineIdentifier { return id }
            return Self.stableHash(of: serverURL)
        }()
        let displayName = auth.selectedServer?.name
            ?? UserDefaults.standard.string(forKey: "selectedServerName")
            ?? "Plex"
        let provider = PlexMusicProvider(
            machineIdentifier: machineID,
            displayName: displayName,
            serverURL: serverURL,
            authToken: token
        )
        // The same id and token is the same account: its caches stay. A restored session's
        // hashed id changes with the address, so there a new address does count as a rebuild.
        if (providers[provider.id] as? PlexMusicProvider)?.authToken != token { generation += 1 }
        register(provider)
    }

    /// Rebuilt from the stored account each time, as `MediaProviderRegistry` does.
    private func populateOtherServer(_ other: OtherServerKind) {
        let stored = other.storedMusicProvider()
        let previous = providers.values.first { $0.kind == other.kind }
        let same = switch (previous, stored) {
        case (nil, nil): true
        case let (previous?, stored?): previous.id == stored.id && other.isSameMusicAccount(previous, stored)
        default: false
        }
        if !same { generation += 1 }
        providers = providers.filter { $0.value.kind != other.kind }
        if let stored { register(stored) }
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
