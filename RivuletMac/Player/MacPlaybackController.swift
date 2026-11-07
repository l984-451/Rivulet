// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Combine
import SwiftUI

/// A title to play. The player view turns it into a session (Plex session or provider backend,
/// local or remote), the way `IOSPlaybackController.startItem` does on iOS.
struct MacPlayRequest: Identifiable {
    let id = UUID()
    let item: MediaItem
    var fromBeginning = false
    /// A version to play instead of the best one.
    var sourceID: String?
    /// A playlist, which replaces Up Next.
    var queue: PlayQueue<PlaylistEntry>?
}

/// Owns "what is playing". Anything that plays a title calls `play`; `macPlaybackHost` shows
/// the player full-window while `request` is set. The player agent owns the session behind it.
@MainActor
final class MacPlaybackController: ObservableObject {
    @Published private(set) var request: MacPlayRequest?
    /// Shown in an alert by the host when playback fails to start.
    @Published var playbackError: String?

    var isPresented: Bool { request != nil }

    /// The one way to play a title from any server.
    func play(_ item: MediaItem, fromBeginning: Bool = false, sourceID: String? = nil,
              queue: PlayQueue<PlaylistEntry>? = nil) {
        request = MacPlayRequest(item: item, fromBeginning: fromBeginning, sourceID: sourceID, queue: queue)
    }

    func close() { request = nil }
}

extension View {
    /// Covers the window with the player while a request is set.
    func macPlaybackHost(_ controller: MacPlaybackController) -> some View {
        modifier(MacPlaybackHost(controller: controller))
    }
}

private struct MacPlaybackHost: ViewModifier {
    @ObservedObject var controller: MacPlaybackController

    func body(content: Content) -> some View {
        content
            .overlay {
                if let request = controller.request {
                    MacPlayerView(request: request) { controller.close() }
                        .id(request.id)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: controller.request?.id)
            .alert(
                "Couldn't Play",
                isPresented: Binding(get: { controller.playbackError != nil },
                                     set: { if !$0 { controller.playbackError = nil } }),
                actions: { Button("OK") {} },
                message: { Text(controller.playbackError ?? "") }
            )
    }
}
