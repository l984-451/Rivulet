// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Account > Home.
struct IOSHomeSettingsView: View {
    /// Same key as the tvOS Home > Hero setting.
    @AppStorage("showHomeHero") private var showHero = true

    var body: some View {
        Form {
            Section {
                Toggle("Hero", isOn: $showHero)
            } footer: {
                Text("Shows featured titles at the top of Home.")
            }
        }
        .navigationTitle("Home")
    }
}

/// Account > Playback: streaming quality, skip buttons, automatic skips and the markers they use.
struct IOSPlaybackSettingsView: View {
    @AppStorage("playerSkipBackwardSeconds") private var skipBackwardSeconds = 10
    @AppStorage("playerSkipForwardSeconds") private var skipForwardSeconds = 30
    @AppStorage("autoSkipIntro") private var autoSkipIntro = false
    @AppStorage("autoSkipRecap") private var autoSkipRecap = false
    @AppStorage("autoSkipCredits") private var autoSkipCredits = false
    @AppStorage("autoSkipAds") private var autoSkipAds = false
    @AppStorage("useIntroDB") private var useIntroDB = false
    /// Same keys as the tvOS Home and Away Streaming Quality settings.
    @AppStorage(StreamingQuality.homeKey) private var homeQuality = StreamingQuality.homeDefault
    @AppStorage(StreamingQuality.awayKey) private var awayQuality = StreamingQuality.awayDefault

    var body: some View {
        Form {
            Section {
                Picker("Home", selection: $homeQuality) { qualityOptions }
                Picker("Away", selection: $awayQuality) { qualityOptions }
            } header: {
                Text("Streaming Quality")
            } footer: {
                Text("Away covers cellular, a personal hotspot, Low Data Mode and connections outside your home network. Auto converts only when the file will not fit your connection.")
            }

            Section {
                Picker("Skip Back", selection: $skipBackwardSeconds) {
                    ForEach([5, 10, 15, 30], id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Picker("Skip Forward", selection: $skipForwardSeconds) {
                    ForEach([10, 15, 30, 60], id: \.self) { Text("\($0) seconds").tag($0) }
                }
            } header: {
                Text("Skip Buttons")
            } footer: {
                Text("These also set how far a double tap jumps.")
            }

            Section {
                Toggle("Intros", isOn: $autoSkipIntro)
                Toggle("Recaps", isOn: $autoSkipRecap)
                Toggle("Credits", isOn: $autoSkipCredits)
                Toggle("Commercials", isOn: $autoSkipAds)
            } header: {
                Text("Skip Automatically")
            } footer: {
                Text("A skip button still appears for every marker during playback.")
            }

            Section {
                Toggle("Community Markers", isOn: $useIntroDB)
            } footer: {
                Text("Fills in intro and credits markers that Plex is missing, from introdb.app. Only the show’s IMDb ID and episode number are sent.")
            }
        }
        .navigationTitle("Playback")
    }

    private var qualityOptions: some View {
        ForEach(StreamingQuality.allChoices, id: \.self) { Text($0.label).tag($0) }
    }
}
