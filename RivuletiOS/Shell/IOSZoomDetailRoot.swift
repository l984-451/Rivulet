// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// The detail page the custom zoom opens from a Home row. It is hosted outside the app's SwiftUI
/// tree, so it gets UIKit's traits but none of the SwiftUI environment: it brings its own stack,
/// routes and zoom namespace, and `open` passes every environment object.
struct IOSZoomDetailRoot: View {
    let item: MediaItem
    let close: () -> Void
    /// Pages pushed from here (More Like This, a person) zoom with the system zoom inside this stack.
    @Namespace private var zoom

    /// Opens `item`'s page from its tile in the Home row `hubID`. The page closes back into the tile
    /// while the item is still in that row, and fades out once a refresh has taken it away.
    static func open(_ item: MediaItem, sourceID: String, hubID: String, cornerRadius: CGFloat) {
        guard let plex = IOSPlaybackController.shared.plex else { return }
        let browse = plex.browse
        IOSCustomZoom.open(from: {
            guard let row = browse.homeRows.first(where: { $0.id == hubID }),
                  row.items.prefix(HomeFeed.railLimit).contains(where: { $0.id == item.id }) else { return nil }
            return IOSZoomSourceFrames.frames[sourceID]
        }, cornerRadius: cornerRadius, hidesSource: { IOSZoomSourceFrames.setHidden($0 ? sourceID : nil) }) { close in
            AnyView(IOSZoomDetailRoot(item: item, close: close)
                .iosSessionObjects(plex)
                .environmentObject(IOSPlaybackController.shared))
        }
    }

    var body: some View {
        NavigationStack {
            IOSPlexDetailView(item: item)
                .toolbar {
                    // The stack's root has no back button of its own; this one closes the zoom.
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Back", systemImage: "chevron.backward", action: close)
                    }
                }
                // Also the page's one action host: a pushed detail gets its own from the routes.
                .iosPlexDestinations()
        }
        .environment(\.plexZoomNamespace, zoom)
    }
}
