// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// The Playback menu. Placeholder: the player agent adds play/pause, seeking, tracks and speed.
struct MacPlaybackCommands: Commands {
    @ObservedObject var playback: MacPlaybackController

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Close Player") { playback.close() }
                .disabled(!playback.isPresented)
        }
    }
}
