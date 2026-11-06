// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaItemRef.swift
//  Rivulet
//
//  Stable identity for any media item across the agnostic layer.
//  Hashable + Codable so it works as NavigationDestination value,
//  FocusMemory key, and cache key.
//

import Foundation
import Synchronization

nonisolated struct MediaItemRef: Hashable, Codable, Sendable {
    /// Provider identifier — "plex:<machineId>" / "tmdb" / "jellyfin:<serverId>".
    let providerID: String
    /// Provider-native item identifier (Plex ratingKey / TMDB id / Jellyfin Guid).
    let itemID: String
}

extension MediaItemRef {
    /// An item from the selected Plex server. The legacy Plex play path is the
    /// only one that resolves `itemID` as a ratingKey against that server; every
    /// other item, an extra Plex server's included, plays through its own provider.
    var isPlex: Bool {
        providerID.hasPrefix("plex:") && !Self.extraPlexIDs.withLock { $0.contains(providerID) }
    }

    /// Provider ids of the Plex servers other than the selected one. Set by
    /// `MediaProviderRegistry`; a lock because refs are read off the main actor.
    static let extraPlexIDs = Mutex<Set<String>>([])

    /// Provider ids the selected Plex server has had this sign-in: an id minted by a URL change
    /// stays valid for tiles already on screen. Set by `MediaProviderRegistry`.
    static let selectedPlexIDs = Mutex<Set<String>>([])
}
