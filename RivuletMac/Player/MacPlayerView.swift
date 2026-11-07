// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// The full-window player for one request. Parity source: RivuletiOS/Player/ and
/// RivuletiOS/Plex/IOSPlexPlayerView.swift. Placeholder until the player lands.
struct MacPlayerView: View {
    let request: MacPlayRequest
    /// Closes the player.
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Text(request.item.title).font(.title2).foregroundStyle(.white)
                Text("Player not built yet").foregroundStyle(.secondary)
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
            }
        }
        .ignoresSafeArea()
    }
}
