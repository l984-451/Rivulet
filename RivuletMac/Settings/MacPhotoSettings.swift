// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Settings > Photos: the slideshow. Same keys as the other apps (`PhotoPreferences`).
struct MacPhotoSettingsView: View {
    @AppStorage(PhotoPreferences.intervalKey) private var interval = 5.0
    @AppStorage(PhotoPreferences.transitionKey) private var transition = PhotoPreferences.Transition.dissolve.rawValue
    @AppStorage(PhotoPreferences.playsClipsKey) private var playsClips = true

    var body: some View {
        Form {
            Section("Slideshow") {
                Picker("Slideshow Interval", selection: $interval) {
                    ForEach(PhotoPreferences.intervals, id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
                Picker("Transition", selection: $transition) {
                    Text("Dissolve").tag(PhotoPreferences.Transition.dissolve.rawValue)
                    Text("Pan and Zoom").tag(PhotoPreferences.Transition.panAndZoom.rawValue)
                }
                Toggle("Play Clips in Slideshow", isOn: $playsClips)
            }
        }
        .formStyle(.grouped)
    }
}
