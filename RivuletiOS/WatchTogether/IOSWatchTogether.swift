// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  IOSWatchTogether.swift
//  Rivulet iOS
//
//  The iOS player's side of Watch Together: its sync hooks, presses, alerts and
//  views. The room logic is `WatchTogetherClient`, shared with the Mac app.
//

import OpenWatchParty
import SwiftUI
import UIKit

extension IOSPlexPlayback: WatchTogetherPlayback {
    var syncPosition: TimeInterval { player.precisePosition }
    var syncDuration: TimeInterval { player.duration }
    var syncIntendsToPlay: Bool { player.intendsToPlay }
    var syncIsBuffering: Bool { player.isBuffering }
    var syncHasFrame: Bool {
        switch player.state {
        case .playing, .paused, .ended: !player.isStarting
        default: false
        }
    }
    func syncPlay() { player.play() }
    func syncPause() { player.pause() }
    func syncSetRate(_ rate: Float) { player.setSyncRate(rate) }
    func syncSeek(to time: TimeInterval) async -> TimeInterval? { await player.seekLanding(to: time) }
}

/// The iOS half of Watch Together: starting the room's titles on this player, and its alerts.
@MainActor
enum IOSWatchTogether {
    static var client: WatchTogetherClient { .shared }

    static func install(controller: IOSPlaybackController, plex: PlexSession) {
        client.plex = plex
        client.start = { [weak controller] prepared in
            guard let controller else { return nil }
            controller.start(IOSPlexPlayback(request: prepared.request, plex: prepared.backend, queue: prepared.queue))
            return controller.session as? IOSPlexPlayback
        }
        client.session.onMismatch = { askAboutMismatch($0) }
        client.session.onNoCopy = { reportNoCopy($0) }
        #if DEBUG
        client.debugJoinIfAsked()
        #endif
    }

    // MARK: - Presses

    /// The room takes a press when this session follows it, and the player acts when the relay answers.
    private static func room(_ session: any IOSPlaybackSession) -> IOSPlexPlayback? { session as? IOSPlexPlayback }

    static func play(_ session: any IOSPlaybackSession) {
        if let playback = room(session), client.requestPlay(from: playback) { return }
        session.player.play()
    }

    static func pause(_ session: any IOSPlaybackSession) {
        if let playback = room(session), client.requestPause(from: playback) { return }
        session.player.pause()
    }

    static func togglePlayPause(_ session: any IOSPlaybackSession) {
        session.player.state == .playing ? pause(session) : play(session)
    }

    static func seek(_ session: any IOSPlaybackSession, to time: TimeInterval) {
        if let playback = room(session), client.requestSeek(to: time, from: playback) { return }
        Task { await session.player.seek(to: time) }
    }

    /// Inside a room a skip is a seek, so it reaches everyone.
    static func skip(_ session: any IOSPlaybackSession, by seconds: Double) {
        if let playback = room(session), client.requestSeek(to: max(0, session.player.currentTime + seconds), from: playback) {
            return
        }
        Task { await session.player.skip(by: seconds) }
    }

    // MARK: - Alerts

    private static func askAboutMismatch(_ delta: TimeInterval) {
        let seconds = Int(abs(delta).rounded())
        let message = delta > 0
            ? String(localized: "Your copy is \(seconds) seconds longer than the room's, so it may not line up.")
            : String(localized: "Your copy is \(seconds) seconds shorter than the room's, so it may not line up.")
        let alert = UIAlertController(title: String(localized: "Different Version"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Sit This One Out"), style: .cancel) { _ in
            client.session.answerMismatch(accept: false)
        })
        alert.addAction(UIAlertAction(title: String(localized: "Play Anyway"), style: .default) { _ in
            client.session.answerMismatch(accept: true)
        })
        top?.present(alert, animated: true)
    }

    private static func reportNoCopy(_ title: String) {
        let alert = UIAlertController(title: String(localized: "Not in Your Library"),
                                      message: String(localized: "None of your servers have \(title)."),
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Stay"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Leave Room"), style: .default) { _ in
            client.session.leave()
        })
        top?.present(alert, animated: true)
    }

    static var top: UIViewController? {
        let scene = UIApplication.shared.connectedScenes.first { $0.activationState == .foregroundActive } as? UIWindowScene
        var top = scene?.windows.first(where: \.isKeyWindow)?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

// MARK: - Views

/// Account sheet: enter a code. The sheet closes first so the player can present.
struct IOSWatchTogetherJoinSection: View {
    @Environment(\.dismiss) private var dismiss
    @State private var asking = false
    @State private var code = ""

    var body: some View {
        Section {
            Button {
                code = ""
                asking = true
            } label: {
                Label("Join a Room", systemImage: "person.2")
            }
        } header: {
            Text("Watch Together")
        } footer: {
            Text("Each person streams from their own server. To start a room, open the Watch Together button in the player.")
        }
        .alert("Join a Room", isPresented: $asking) {
            TextField("Room Code", text: $code)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Join") {
                let entered = code
                dismiss()
                Task { await IOSWatchTogetherJoin.join(entered) }
            }
        } message: {
            Text("Enter the code from the person hosting.")
        }
    }
}

@MainActor
private enum IOSWatchTogetherJoin {
    static func join(_ code: String) async {
        do {
            try await WatchTogetherClient.shared.join(code: code)
        } catch {
            let message = switch WatchTogetherSession.failure(for: error) {
            case .roomNotFound: String(localized: "No room has that code. Rooms end when everyone leaves.")
            case .roomFull: String(localized: "That room is full or locked.")
            case .invalidCode: String(localized: "Room codes have 6 letters and numbers.")
            case .unavailable, .unreachable: String(localized: "Couldn't reach Watch Together. Check your connection and try again.")
            case .other: String(localized: "Couldn't join that room.")
            }
            let alert = UIAlertController(title: String(localized: "Couldn't Join"), message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            IOSWatchTogether.top?.present(alert, animated: true)
        }
    }
}

/// The player's room sheet: a button to open one, or the code and who's here.
struct IOSWatchTogetherPane: View {
    let playback: IOSPlexPlayback
    @ObservedObject private var room = WatchTogetherSession.shared
    @Environment(\.dismiss) private var dismiss
    @State private var starting = false
    @State private var failed = false

    var body: some View {
        NavigationStack {
            List {
                if let code = room.code {
                    Section("Room Code") {
                        Text(code)
                            .font(.title.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                        ShareLink(item: code) { Label("Share Code", systemImage: "square.and.arrow.up") }
                    }
                    Section("Here Now") {
                        ForEach(room.members) { member in
                            LabeledContent(member.name, value: status(of: member))
                        }
                    }
                    Section {
                        Button("Leave Room", role: .destructive) {
                            room.leave()
                            dismiss()
                        }
                    }
                } else {
                    Section {
                        Button(starting ? "Starting…" : "Start a Room") { start() }
                            .disabled(starting)
                    } footer: {
                        Text(failed
                             ? "Couldn't start a room."
                             : "Get a code to share. Playback pauses here until someone presses play.")
                    }
                }
            }
            .navigationTitle("Watch Together")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }

    private func start() {
        starting = true
        failed = false
        Task {
            do {
                try await WatchTogetherClient.shared.host(from: playback)
            } catch {
                failed = true
            }
            starting = false
        }
    }

    private func status(of member: WatchTogetherSession.Member) -> String {
        let status = switch member.status {
        case .watching: String(localized: "Ready")
        case .loading: String(localized: "Loading")
        case .buffering: String(localized: "Buffering")
        case .away: String(localized: "Away")
        case .noCopy: String(localized: "Doesn't have this title")
        }
        return member.isHost ? String(localized: "Host • \(status)") : status
    }
}
