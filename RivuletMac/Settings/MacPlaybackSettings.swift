// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// Settings > Playback: audio and subtitles, streaming quality, skip buttons, markers.
/// Parity source: IOSPlaybackSettingsView (Downloads is iOS only).
struct MacPlaybackSettingsView: View {
    @AppStorage(SkipLengthKeys.back) private var skipBackwardSeconds = 10
    @AppStorage(SkipLengthKeys.forward) private var skipForwardSeconds = 30
    /// Observed so the skip pickers redraw (and Credits); read and written through `MarkerSkipMode`.
    @AppStorage("autoSkipIntro") private var autoSkipIntro = false
    @AppStorage("autoSkipRecap") private var autoSkipRecap = false
    @AppStorage(CreditsBehavior.storageKey) private var atTheCredits = ""
    @AppStorage("autoSkipAds") private var autoSkipAds = false
    @AppStorage("showSkipIntro") private var showSkipIntro = true
    @AppStorage("showSkipRecap") private var showSkipRecap = true
    @AppStorage("showSkipAds") private var showSkipAds = true
    @AppStorage("useIntroDB") private var useIntroDB = false
    @AppStorage(StreamingQuality.homeKey) private var homeQuality = StreamingQuality.homeDefault
    @AppStorage(StreamingQuality.awayKey) private var awayQuality = StreamingQuality.awayDefault
    /// The key the player reads (AetherPlayer.upscaleKey).
    @AppStorage("upscaleLowResolution") private var upscales = false
    /// Bumped on every track-intent write: `TrackIntentStore` is not observable.
    @State private var trackRevision = 0
    @AppStorage(AutoplayCountdown.storageKey) private var autoplayCountdown = AutoplayCountdown.fiveSeconds.rawValue
    @AppStorage(AutoplayLimit.storageKey) private var autoplayLimit = AutoplayLimit.off.rawValue
    @AppStorage(CinemaExtras.countKey) private var cinemaTrailers = 0

    var body: some View {
        Form {
            audioAndSubtitles

            Section {
                Picker(String(localized: "streaming.home", defaultValue: "Home"), selection: $homeQuality) { qualityOptions }
                Picker("Away", selection: $awayQuality) { qualityOptions }
            } header: {
                Text("Streaming Quality")
            } footer: {
                Text("Away covers a personal hotspot and connections outside your home network. Auto converts only when the file will not fit your connection.")
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
                Text("These set how far the skip buttons jump.")
            }

            Section {
                skipPicker("Intros", marker: "intro")
                skipPicker("Recaps", marker: "recap")
                skipPicker("Commercials", marker: "commercial")
            } header: {
                Text("Skip Markers")
            } footer: {
                Text("Manual shows a skip button, Automatic skips on its own, and Off shows nothing.")
            }

            Section {
                Picker("Credits", selection: Binding(
                    get: { CreditsBehavior.current() }, set: { CreditsBehavior.set($0) }
                )) {
                    ForEach(CreditsBehavior.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Up Next opens the next episode card when the credits start. Skip Button shows only Skip Credits, then Up Next opens at the end. Off waits for the end. Countdown decides autoplay.")
            }

            Section {
                Picker("Countdown", selection: $autoplayCountdown) {
                    ForEach(AutoplayCountdown.allCases, id: \.rawValue) { Text($0.description).tag($0.rawValue) }
                }
                Picker("Limit", selection: $autoplayLimit) {
                    ForEach(AutoplayLimit.allCases, id: \.rawValue) { Text($0.description).tag($0.rawValue) }
                }
            } header: {
                Text("Autoplay")
            } footer: {
                Text("Countdown is how long Up Next waits before the next episode starts. Limit stops autoplay after that many episodes in a row.")
            }

            Section {
                Picker("Trailers Before Movies", selection: $cinemaTrailers) {
                    Text("Off").tag(0)
                    ForEach(CinemaExtras.countOptions.dropFirst(), id: \.self) { Text("\($0)").tag($0) }
                }
            } footer: {
                Text("Plays trailers and pre-roll videos from your Plex server's Cinema Trailers settings before a movie that starts from the beginning.")
            }

            Section {
                Toggle("Upscale SD and 720p", isOn: $upscales)
            } footer: {
                Text("Sharpens video smaller than your screen with Apple's machine learning upscaler. Uses more power, and stops on its own if the Mac can't keep up. HDR and Dolby Vision play as before.")
            }

            Section {
                Toggle("Community Markers", isOn: $useIntroDB)
            } footer: {
                Text("Fills in intro and credits markers that Plex is missing, from introdb.app. Only the show’s IMDb ID and episode number are sent.")
            }
        }
        .formStyle(.grouped)
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
