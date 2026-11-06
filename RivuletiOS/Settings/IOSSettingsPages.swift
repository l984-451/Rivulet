// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Account > Library.
struct IOSLibrarySettingsView: View {
    @EnvironmentObject private var browse: IOSBrowseStore
    @AppStorage(IOSLibrarySettingsView.showPlaylistsKey) private var showPlaylists = true
    /// The tvOS sidebar's key, so sync and a shared profile agree.
    @AppStorage("showFavoritesTab") private var showFavorites = false

    static let showPlaylistsKey = "iosShowPlaylists"

    var body: some View {
        Form {
            Section {
                Toggle("Playlists", isOn: $showPlaylists)
            } footer: {
                Text("Lists each server's video playlists under Library.")
            }
            if browse.offersFavorites {
                Section {
                    Toggle("Favorites", isOn: $showFavorites)
                } footer: {
                    Text("Lists your favorite movies and shows from every server under Library.")
                }
            }
        }
        .navigationTitle("Library")
    }
}

/// Account > Playback: streaming quality, skip buttons, automatic skips and the markers they use.
struct IOSPlaybackSettingsView: View {
    @AppStorage(SkipLengthKeys.back) private var skipBackwardSeconds = 10
    @AppStorage(SkipLengthKeys.forward) private var skipForwardSeconds = 30
    /// Observed so the skip pickers redraw; read and written through `MarkerSkipMode`.
    @AppStorage("autoSkipIntro") private var autoSkipIntro = false
    @AppStorage("autoSkipRecap") private var autoSkipRecap = false
    @AppStorage("autoSkipCredits") private var autoSkipCredits = false
    @AppStorage("autoSkipAds") private var autoSkipAds = false
    @AppStorage("showSkipIntro") private var showSkipIntro = true
    @AppStorage("showSkipRecap") private var showSkipRecap = true
    @AppStorage("showSkipCredits") private var showSkipCredits = true
    @AppStorage("showSkipAds") private var showSkipAds = true
    @AppStorage("useIntroDB") private var useIntroDB = false
    /// Same keys as the tvOS Home and Away Streaming Quality settings.
    @AppStorage(StreamingQuality.homeKey) private var homeQuality = StreamingQuality.homeDefault
    @AppStorage(StreamingQuality.awayKey) private var awayQuality = StreamingQuality.awayDefault
    @AppStorage(AetherPlayer.upscaleKey) private var upscales = false
    /// Bumped on every track-intent write: `TrackIntentStore` is not observable.
    @State private var trackRevision = 0

    var body: some View {
        Form {
            audioAndSubtitles

            Section {
                Picker(String(localized: "streaming.home", defaultValue: "Home"), selection: $homeQuality) { qualityOptions }
                Picker("Away", selection: $awayQuality) { qualityOptions }
            } header: {
                Text("Streaming Quality")
            } footer: {
                Text("Away covers cellular, a personal hotspot, Low Data Mode and connections outside your home network. Auto converts only when the file will not fit your connection.")
            }

            Section {
                Picker("Skip Back", selection: $skipBackwardSeconds) {
                    ForEach(SkipLengthKeys.options, id: \.self) { Text("\($0) seconds").tag($0) }
                }
                Picker("Skip Forward", selection: $skipForwardSeconds) {
                    ForEach(SkipLengthKeys.options, id: \.self) { Text("\($0) seconds").tag($0) }
                }
            } header: {
                Text("Skip Buttons")
            } footer: {
                Text("These also set how far a double tap jumps.")
            }

            Section {
                skipPicker("Intros", marker: "intro")
                skipPicker("Recaps", marker: "recap")
                skipPicker("Credits", marker: "credits")
                skipPicker("Commercials", marker: "commercial")
            } header: {
                Text("Skip Markers")
            } footer: {
                Text("Manual shows a skip button, Automatic skips on its own, and Off shows nothing.")
            }

            Section {
                Toggle("Upscale SD and 720p", isOn: $upscales)
            } footer: {
                Text("Sharpens video smaller than your screen with Apple's machine learning upscaler. Uses more power, and stops on its own if the device can't keep up. HDR and Dolby Vision play as before.")
            }

            Section {
                Toggle("Community Markers", isOn: $useIntroDB)
            } footer: {
                Text("Fills in intro and credits markers that Plex is missing, from introdb.app. Only the show’s IMDb ID and episode number are sent.")
            }
        }
        .navigationTitle("Playback")
    }

    /// Same intents as the tvOS Audio & Subtitles settings, saved per Plex profile.
    private var audioAndSubtitles: some View {
        let _ = trackRevision
        let subtitlesOn = SubtitleMode.current != .off
        return Section {
            Picker("Audio Language", selection: trackBinding(
                get: { TrackIntentStore.audioIntent.map { TrackLanguage.normalize($0.language) } ?? "" },
                set: { TrackIntentStore.audioIntent = $0.isEmpty ? nil : AudioIntent(language: $0) }
            )) {
                Text(TrackLanguage.audioSettingName(nil)).tag("")
                ForEach([TrackLanguage.original] + TrackLanguage.sortedChoices, id: \.self) {
                    Text(TrackLanguage.audioSettingName($0)).tag($0)
                }
            }
            Picker("Subtitles", selection: trackBinding(get: { SubtitleMode.current },
                                                        set: { TrackIntentStore.setSubtitles(mode: $0) })) {
                ForEach(SubtitleMode.choices, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("Subtitle Language", selection: trackBinding(
                get: { TrackLanguage.normalize(TrackIntentStore.subtitleLanguage) },
                set: { TrackIntentStore.setSubtitles(language: $0) }
            )) {
                ForEach(TrackLanguage.sortedChoices, id: \.self) { Text(TrackLanguage.displayName($0)).tag($0) }
            }
            .disabled(!subtitlesOn)
            Toggle("SDH Subtitles", isOn: trackBinding(get: { TrackIntentStore.subtitleSDH },
                                                       set: { TrackIntentStore.setSubtitles(sdh: $0) }))
                .disabled(!subtitlesOn)
        } header: {
            Text("Audio & Subtitles")
        } footer: {
            Text("Foreign Audio shows subtitles when a title's audio is in another language, and only forced subtitles otherwise. Saved for each Plex profile.")
        }
        .onAppear { trackRevision += 1 }
    }

    private func trackBinding<Value>(get: @escaping () -> Value, set: @escaping (Value) -> Void) -> Binding<Value> {
        Binding(get: get, set: { set($0); trackRevision += 1 })
    }

    private var qualityOptions: some View {
        ForEach(StreamingQuality.allChoices, id: \.self) { Text($0.label).tag($0) }
    }

    private func skipPicker(_ title: LocalizedStringKey, marker: String) -> some View {
        Picker(title, selection: Binding(
            get: { MarkerSkipMode.current(for: marker) },
            set: { MarkerSkipMode.set($0, for: marker) }
        )) {
            ForEach(MarkerSkipMode.allCases, id: \.self) { Text($0.label).tag($0) }
        }
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
                VStack(alignment: .leading, spacing: 6) {
                    Text("Original saves the file as it is on the server. Smaller sizes are converted by the server first, and a size at or above the file's own downloads the Original.")
                    Text("Only Plex converts. Jellyfin and Emby always download the original file.")
                }
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
