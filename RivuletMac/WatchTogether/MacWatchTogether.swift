// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MacWatchTogether.swift
//  Rivulet Mac
//
//  The Mac player's side of Watch Together: its sync hooks, alerts, the File menu's
//  join and the player's room popover. The room logic is `WatchTogetherClient`.
//

import AppKit
import OpenWatchParty
import SwiftUI

extension MacPlexPlayback: WatchTogetherPlayback {
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

@MainActor
enum MacWatchTogether {
    static var client: WatchTogetherClient { .shared }

    static func install(controller: MacPlaybackController, plex: PlexSession) {
        client.plex = plex
        client.start = { [weak controller] prepared in
            guard let controller else { return nil }
            controller.start(MacPlexPlayback(request: prepared.request, plex: prepared.backend, queue: prepared.queue))
            return controller.session as? MacPlexPlayback
        }
        client.session.onMismatch = { askAboutMismatch($0) }
        client.session.onNoCopy = { reportNoCopy($0) }
        #if DEBUG
        client.debugJoinIfAsked()
        #endif
    }

    /// File > Join Watch Together: asks for a code, then joins.
    static func askToJoin() {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.placeholderString = String(localized: "Room Code")
        let alert = NSAlert()
        alert.messageText = String(localized: "Join a Room")
        alert.informativeText = String(localized: "Enter the code from the person hosting.")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "Join"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let code = field.stringValue
        Task {
            do {
                try await client.join(code: code)
            } catch {
                let failure = NSAlert()
                failure.messageText = String(localized: "Couldn't Join")
                failure.informativeText = switch WatchTogetherSession.failure(for: error) {
                case .roomNotFound: String(localized: "No room has that code. Rooms end when everyone leaves.")
                case .roomFull: String(localized: "That room is full or locked.")
                case .invalidCode: String(localized: "Room codes have 6 letters and numbers.")
                case .unavailable, .unreachable: String(localized: "Couldn't reach Watch Together. Check your connection and try again.")
                case .other: String(localized: "Couldn't join that room.")
                }
                failure.runModal()
            }
        }
    }

    private static func askAboutMismatch(_ delta: TimeInterval) {
        let seconds = Int(abs(delta).rounded())
        let alert = NSAlert()
        alert.messageText = String(localized: "Different Version")
        alert.informativeText = delta > 0
            ? String(localized: "Your copy is \(seconds) seconds longer than the room's, so it may not line up.")
            : String(localized: "Your copy is \(seconds) seconds shorter than the room's, so it may not line up.")
        alert.addButton(withTitle: String(localized: "Play Anyway"))
        alert.addButton(withTitle: String(localized: "Sit This One Out"))
        client.session.answerMismatch(accept: alert.runModal() == .alertFirstButtonReturn)
    }

    private static func reportNoCopy(_ title: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Not in Your Library")
        alert.informativeText = String(localized: "None of your servers have \(title).")
        alert.addButton(withTitle: String(localized: "Stay"))
        alert.addButton(withTitle: String(localized: "Leave Room"))
        if alert.runModal() == .alertSecondButtonReturn { client.session.leave() }
    }
}

/// The player's room popover: a button to open one, or the code and who's here.
struct MacWatchTogetherPane: View {
    let playback: MacPlexPlayback
    @ObservedObject private var room = WatchTogetherSession.shared
    @State private var starting = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Watch Together").font(.headline)
            if let code = room.code {
                HStack {
                    Text(code)
                        .font(.title2.monospaced().weight(.semibold))
                        .textSelection(.enabled)
                    Spacer()
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(code, forType: .string)
                    }
                }
                ForEach(room.members) { member in
                    LabeledContent(member.name, value: status(of: member))
                }
                Button("Leave Room", role: .destructive) { room.leave() }
            } else {
                Text(failed
                     ? "Couldn't start a room."
                     : "Get a code to share. Playback pauses here until someone presses play.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(starting ? "Starting…" : "Start a Room") { start() }
                    .disabled(starting)
            }
        }
        .padding()
        .frame(width: 300)
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
