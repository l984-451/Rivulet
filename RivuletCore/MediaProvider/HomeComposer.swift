// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomeComposer.swift
//  Rivulet
//
//  Builds [MediaHub] for the home screen from a MediaProvider. For Plex,
//  prefers the server's curated hubs (genre rails, "Because you watched...").
//  For other providers, synthesizes from primitives (continueWatching +
//  recentlyAdded). The home view consumes [MediaHub] without knowing the source.
//

import Foundation

enum HomeComposer {
    /// Returns hubs for the home screen.
    static func compose(provider: any MediaProvider) async throws -> [MediaHub] {
        if let plex = provider as? PlexProvider {
            let native = try await plex.hubs()
            if !native.isEmpty { return native }
        }
        return try await synthesizeFromPrimitives(provider: provider)
    }

    private static func synthesizeFromPrimitives(provider: any MediaProvider) async throws -> [MediaHub] {
        async let cw = provider.continueWatching(limit: 20)
        async let ra = provider.recentlyAdded(limit: 20)
        let cwItems = (try? await cw) ?? []
        let raItems = (try? await ra) ?? []
        var hubs: [MediaHub] = []
        if !cwItems.isEmpty {
            hubs.append(MediaHub(
                id: "synth.continueWatching", providerID: provider.id,
                title: String(localized: "Continue Watching"), style: .shelf, items: cwItems
            ))
        }
        if !raItems.isEmpty {
            hubs.append(MediaHub(
                id: "synth.recentlyAdded", providerID: provider.id,
                title: String(localized: "Recently Added"), style: .shelf, items: raItems
            ))
        }
        return hubs
    }
}
