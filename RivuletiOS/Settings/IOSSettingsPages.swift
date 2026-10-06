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

/// Account > Downloads: quality, cellular, storage and Delete All.
struct IOSDownloadSettingsView: View {
    @AppStorage(IOSDownloadCenter.qualityKey) private var quality = StreamingQuality.original
    @AppStorage(IOSDownloadTransfer.cellularKey) private var overCellular = false
    @EnvironmentObject private var downloads: IOSDownloadCenter
    @State private var confirmingDeleteAll = false

    var body: some View {
        Form {
            Section {
                Picker("Download Quality", selection: $quality) {
                    ForEach(IOSDownloadCenter.qualityChoices, id: \.self) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Original saves the file as it is on the server. Smaller sizes are converted by the server first, and a size at or above the file's own downloads the Original.")
            }

            Section {
                Toggle("Download over Cellular", isOn: $overCellular)
            } footer: {
                Text("When off, downloads wait for Wi-Fi on cellular, a personal hotspot or Low Data Mode.")
            }

            Section {
                LabeledContent("Storage Used",
                               value: ByteCountFormatter.string(fromByteCount: downloads.storageUsed, countStyle: .file))
                Button("Delete All Downloads", role: .destructive) { confirmingDeleteAll = true }
                    .disabled(downloads.records.isEmpty)
                    .confirmationDialog("Delete all downloads?", isPresented: $confirmingDeleteAll, titleVisibility: .visible) {
                        Button("Delete All Downloads", role: .destructive) { downloads.deleteAll() }
                    } message: {
                        Text("Every download on this device is removed, for every profile.")
                    }
            }
        }
        .navigationTitle("Downloads")
    }
}
