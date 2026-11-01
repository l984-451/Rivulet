// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// The tvOS pages' ambient wash (`AmbientBackdropView` under the frosted base): one
/// artwork stretched behind the page, diffused by the system material, with a
/// vignette that keeps the lower half dark. Crossfades over 0.6 s when the art changes.
struct IOSPlexAmbientBackdrop: View {
    let url: URL?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
            if let url {
                IOSPlexImage(url: url)
                    .opacity(0.85)
                    .id(url)
                    .transition(.opacity)
            }
            Rectangle().fill(.regularMaterial)
            // Dark only: in light mode the frost alone keeps dark text readable.
            if colorScheme == .dark {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.10), location: 0),
                        .init(color: .black.opacity(0.25), location: 0.55),
                        .init(color: .black.opacity(0.50), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .animation(.easeInOut(duration: 0.6), value: url)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The wash from an item's backdrop, requested as the Home hero requests it
/// (full width, 16:9), so the hero's page is already in the cache.
private struct IOSPlexItemAmbient: View {
    let item: PlexMetadata
    @EnvironmentObject private var plex: IOSPlexSession
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { proxy in
            IOSPlexAmbientBackdrop(url: IOSPlexArtwork.url(plex, item: item, kind: .backdrop, width: proxy.size.width,
                                                           aspectRatio: 16 / 9, scale: displayScale))
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// Puts the ambient wash behind the page, made from `item`'s backdrop. Only a
    /// page whose header shows that art gets one; nil leaves the page's own background.
    func iosPlexAmbient(_ item: PlexMetadata?) -> some View {
        background { if let item { IOSPlexItemAmbient(item: item) } }
    }
}
