// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// One library: Recommended (its own rows under a hero) or Browse (every title), with sort and
/// filter. Parity source: RivuletiOS/Plex/Library/IOSPlexLibraryView.swift.
struct MacLibraryView: View {
    let library: MediaLibrary

    var body: some View {
        MacFeaturePlaceholder(title: LocalizedStringKey(library.title), symbol: library.icon,
                              source: "RivuletiOS/Plex/Library/IOSPlexLibraryView.swift")
            .navigationTitle(library.title)
    }
}
