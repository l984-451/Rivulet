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

struct MediaItemRef: Hashable, Codable, Sendable {
    /// Provider identifier — "plex:<machineId>" / "tmdb" / future "jellyfin:<serverId>".
    let providerID: String
    /// Provider-native item identifier (Plex ratingKey / TMDB id / Jellyfin Guid).
    let itemID: String
}

extension MediaItemRef {
    /// An item from a Jellyfin server (`JellyfinProvider.id` is
    /// "jellyfin:<serverID>"). Paths that treat `itemID` as a Plex ratingKey
    /// check this first.
    var isJellyfin: Bool { providerID.hasPrefix("jellyfin:") }

    /// An item from a Plex server (`PlexProvider.id` is "plex:<machineId>").
    /// The legacy Plex play path is the only one that resolves `itemID` as a
    /// ratingKey; every other item plays through its own provider.
    var isPlex: Bool { providerID.hasPrefix("plex:") }
}
