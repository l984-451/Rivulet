// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  WatchTogetherClient.swift
//  Rivulet
//
//  Connects the room to the iOS and Mac players, which share `PlaybackStart` and
//  `PlexPlaybackRequest`: what to describe, what to open, and the press funnel.
//  The apps supply the player, the alerts and the views.
//

import Foundation
import OpenWatchParty

/// An iOS or Mac player session the room can follow.
@MainActor
protocol WatchTogetherPlayback: WatchTogetherPlayer {
    var request: PlexPlaybackRequest { get }
}

extension PlexPlaybackRequest {
    /// The playing title on its own server, as the room's resolver names it.
    @MainActor var watchTogetherItem: WatchTogetherItem? {
        if let playback = providerPlayback {
            return WatchTogetherItem(providerID: playback.item.ref.providerID, itemID: playback.item.ref.itemID,
                                     sourceID: playback.stream.source.id)
        }
        guard let key = item.ratingKey,
              let providerID = item.serverID.map({ "plex:\($0)" }) ?? MediaProviderRegistry.shared.plexProvider?.id
        else { return nil }
        // `item.Media` leads with the playing version.
        return WatchTogetherItem(providerID: providerID, itemID: key, sourceID: item.Media?.first.map { "\($0.id)" })
    }
}

@MainActor
final class WatchTogetherClient {
    static let shared = WatchTogetherClient()

    let session = WatchTogetherSession.shared
    /// The app's Plex session, which plays Plex titles. Set at launch.
    weak var plex: PlexSession?
    /// Starts `prepared` on this app's player and returns the session it made.
    var start: ((PreparedPlayback) -> (any WatchTogetherPlayback)?)?
    private weak var playback: (any WatchTogetherPlayback)?
    private var adapter: WatchTogetherPlayerAdapter?

    private init() {
        session.resolver = { try await WatchTogetherResolver.candidates(for: $0) }
        session.onOpen = { [weak self] item, position in self?.open(item, at: position) }
    }

    private static var client: String {
        "Rivulet/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")"
    }

    private static var displayName: String {
        PlexUserProfileManager.shared.selectedUser?.displayName ?? PlexAuthManager.shared.username ?? PlexAPI.deviceName
    }

    // MARK: - Starting

    /// Opens a room on what `playback` is playing, paused until someone presses play.
    func host(from playback: any WatchTogetherPlayback) async throws {
        try await session.create(name: Self.displayName, client: Self.client)
        do {
            try await share(playback, holdPaused: true)
        } catch {
            session.leave()
            throw error
        }
    }

    func join(code: String) async throws {
        try await session.join(code: code, name: Self.displayName, client: Self.client)
    }

    private func share(_ playback: any WatchTogetherPlayback, holdPaused: Bool) async throws {
        guard let item = playback.request.watchTogetherItem else { throw PartyError(.invalidMessage) }
        let duration = playback.syncDuration > 0 ? playback.syncDuration : playback.request.item.durationSeconds ?? 1
        let media = try await WatchTogetherResolver.describe(
            MediaItemRef(providerID: item.providerID, itemID: item.itemID), durationMs: Int64(max(duration, 1) * 1000))
        try session.share(media, item: item, at: holdPaused ? playback.syncPosition : 0, holdPaused: holdPaused)
        bind(playback, item: item)
    }

    private func bind(_ playback: any WatchTogetherPlayback, item: WatchTogetherItem) {
        adapter?.stopTrimming()
        let adapter = WatchTogetherPlayerAdapter(player: playback)
        self.playback = playback
        self.adapter = adapter
        session.attach(adapter, item: item)
        adapter.startTrimming { [weak self, weak adapter] in
            adapter.flatMap { self?.session.drift(of: $0) }
        }
    }

    private func unbind() {
        adapter?.stopTrimming()
        adapter = nil
        playback = nil
        session.detach()
    }

    /// The host moved to another title (Up Next, a playlist): the room follows.
    func itemChanged(_ playback: any WatchTogetherPlayback) {
        guard self.playback === playback, session.isActive else { return }
        session.detach()
        guard session.isHost else { return }
        Task { try? await share(playback, holdPaused: false) }
    }

    func playbackClosed(_ playback: any WatchTogetherPlayback) {
        guard self.playback === playback else { return }
        unbind()
        session.leave()
    }

    // MARK: - Presses

    /// True when the room takes the press; the SDK drives the player when the relay answers.
    func requestPlay(from playback: any WatchTogetherPlayback) -> Bool { follows(playback) && session.requestPlay() }
    func requestPause(from playback: any WatchTogetherPlayback) -> Bool { follows(playback) && session.requestPause() }
    func requestSeek(to time: TimeInterval, from playback: any WatchTogetherPlayback) -> Bool {
        follows(playback) && session.requestSeek(to: time)
    }

    private func follows(_ playback: any WatchTogetherPlayback) -> Bool {
        self.playback === playback && session.isActive
    }

    /// What plays next is the host's call.
    func blocksLocalAdvance(_ playback: any WatchTogetherPlayback) -> Bool {
        follows(playback) && session.isGuest
    }

    // MARK: - Opening the room's title

    private func open(_ item: WatchTogetherItem, at position: TimeInterval?) {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.providerID) else { return }
        // Replacing the player must not read as leaving the room.
        unbind()
        Task {
            guard let detail = try? await provider.fullDetail(for: MediaItemRef(providerID: item.providerID, itemID: item.itemID)),
                  let prepared = try? await PlaybackStart.prepare(
                      detail.item, fromBeginning: true, sourceID: item.sourceID, queue: nil, plex: plex,
                      startOffset: position),
                  let playback = start?(prepared)
            else { return }
            bind(playback, item: item)
        }
    }

    #if DEBUG
    /// Field test: RIVULET_OWP_RELAY names a relay, RIVULET_WT_JOIN=<code> joins at launch.
    func debugJoinIfAsked() {
        guard let code = ProcessInfo.processInfo.environment["RIVULET_WT_JOIN"] else { return }
        Task {
            try? await Task.sleep(for: .seconds(8))
            do {
                try await join(code: code)
                while session.isActive {
                    let drift = adapter.flatMap { session.drift(of: $0) }.map(String.init) ?? "?"
                    NSLog("[WatchTogether] %@", "position=\(adapter?.positionMs ?? -1) drift=\(drift)ms members=\(session.members.map(\.name))")
                    try? await Task.sleep(for: .seconds(1))
                }
            } catch {
                NSLog("[WatchTogether] %@", "join failed: \(error)")
            }
        }
    }
    #endif
}
