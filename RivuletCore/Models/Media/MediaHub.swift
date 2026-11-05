// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaHub.swift
//  Rivulet
//
//  A home-screen rail. Plex returns curated hubs (genre rails,
//  "Because you watched..."); other providers compose hubs from primitives.
//

import Foundation

nonisolated struct MediaHub: Identifiable, Hashable, Sendable {
    let id: String                  // hub identifier
    let providerID: String
    let title: String
    let style: HubStyle
    let items: [MediaItem]
    /// Opaque to callers: what `MediaProvider.hubPage` needs to page this row. Nil when the row cannot page.
    var pagingKey: String? = nil
    /// The user put this row on the server's own home screen (Plex "promoted"). Other servers have no such setting.
    var isPromoted = false

    enum HubStyle: Sendable, Hashable, Codable {
        case shelf
        case hero
        case clip
    }
}
