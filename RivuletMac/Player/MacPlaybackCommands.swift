// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import SwiftUI

/// The Playback menu. The keys live here rather than in the player view, so they show beside
/// their items and fall through to the window when no player is up.
struct MacPlaybackCommands: Commands {
    @ObservedObject var playback: MacPlaybackController

    var body: some Commands {
        CommandMenu("Playback") {
            let session = playback.session
            let player = session?.player
            let active = playback.isActive

            Button(player?.state == .playing ? "Pause" : "Play") { playback.togglePlayPause() }
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!active)
            Button("Skip Back") { playback.skip(forward: false) }
                .keyboardShortcut(.leftArrow, modifiers: [])
                .disabled(!active)
            Button("Skip Forward") { playback.skip(forward: true) }
                .keyboardShortcut(.rightArrow, modifiers: [])
                .disabled(!active)
            let plexSession = playback.plexSession
            Button("Next Episode") { plexSession?.playNext() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!active || plexSession?.nextEpisode == nil)
            Button("Skip Intro or Credits") {
                if let marker = plexSession?.activeMarker { plexSession?.skip(marker) }
            }
            .keyboardShortcut("s", modifiers: [])
            .disabled(!active)

            Button("Channel Up") { playback.stepChannel(1) }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!active || !(session is MacLivePlayback))
            Button("Channel Down") { playback.stepChannel(-1) }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(!active || !(session is MacLivePlayback))

            Divider()

            Button("Volume Up") { playback.adjustVolume(by: 0.1) }
                .keyboardShortcut(.upArrow, modifiers: [])
                .disabled(!active)
            Button("Volume Down") { playback.adjustVolume(by: -0.1) }
                .keyboardShortcut(.downArrow, modifiers: [])
                .disabled(!active)
            Button(player?.isMuted == true ? "Unmute" : "Mute") { playback.toggleMute() }
                .keyboardShortcut("m", modifiers: [])
                .disabled(!active)

            Divider()

            Menu("Speed") {
                Picker("Speed", selection: Binding(get: { player?.rate ?? 1 }, set: { player?.setRate($0) })) {
                    ForEach(MacPlayerSpeeds.all, id: \.self) { Text(MacPlayerSpeeds.label($0)).tag($0) }
                }
                .pickerStyle(.inline)
            }
            .disabled(!active)

            Menu("Audio") {
                if let session {
                    Picker("Audio", selection: Binding(
                        get: { session.selectedAudioID },
                        set: { id in if let id { session.selectAudio(id) } }
                    )) {
                        ForEach(session.audioTracks) { MacTrackLabel(track: $0).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.inline)
                }
            }
            .disabled(!active || session?.audioTracks.isEmpty != false)

            Menu("Subtitles") {
                if let session {
                    Picker("Subtitles", selection: Binding(
                        get: { session.selectedSubtitleID }, set: { session.selectSubtitle($0) }
                    )) {
                        Text("Off").tag(Int?.none)
                        ForEach(session.subtitleTracks) { MacTrackLabel(track: $0).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.inline)
                }
            }
            .disabled(!active || session?.subtitleTracks.isEmpty != false)
            Button("Toggle Subtitles") { playback.toggleSubtitles() }
                .keyboardShortcut("c", modifiers: [])
                .disabled(!active || session?.subtitleTracks.isEmpty != false)

            if let session = plexSession, !session.request.isLocal {
                Menu("Quality") {
                    Picker("Quality", selection: Binding(
                        get: { session.request.quality }, set: { session.switchQuality($0) }
                    )) {
                        ForEach(StreamingQuality.allChoices, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                }
                .disabled(!active)
            }

            if let session = plexSession, !session.chapters.isEmpty {
                Menu("Chapters") {
                    ForEach(Array(session.chapters.enumerated()), id: \.offset) { index, chapter in
                        Button(chapter.tag ?? String(localized: "Chapter \(index + 1)")) { session.seekToChapter(chapter) }
                    }
                }
                .disabled(!active)
            }

            Divider()

            Toggle("Fill Window", isOn: Binding(get: { player?.fillsScreen ?? false }, set: { player?.fillsScreen = $0 }))
                .disabled(!active)
            Button("Full Screen") { playback.toggleFullScreen() }
                .keyboardShortcut("f", modifiers: [])
                .disabled(!active)
            Button("Picture in Picture") { playback.startPictureInPicture() }
                .keyboardShortcut("p", modifiers: [.control, .command])
                .disabled(!active || !playback.isPictureInPicturePossible)
            Button("Close Player") { playback.escape() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!active)
        }
    }
}

/// Playback speeds offered by the menu and the chrome.
enum MacPlayerSpeeds {
    static let all: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    static func label(_ rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "x"
    }
}

/// A track's name over its detail line, as a menu or picker row.
struct MacTrackLabel: View {
    let track: AetherPlayer.Track

    var body: some View {
        let detail = track.detail
        if detail.isEmpty || detail == track.name {
            Text(track.name)
        } else {
            Text("\(track.name) · \(detail)")
        }
    }
}
