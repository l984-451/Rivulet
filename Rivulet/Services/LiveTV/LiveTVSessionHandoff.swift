// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveTVSessionHandoff.swift
//  Rivulet
//
//  A running live session in transit between surfaces: the full-screen
//  player, the corner player the guide keeps going after Back (issue #318),
//  and a multiview tile. Handing it over rebinds the same player to a new
//  render surface instead of tuning again, so the picture does not stop and
//  a Plex tuner is not grabbed twice.
//
//  Exactly one surface owns a handoff at a time. Whoever holds it last and
//  has no further use for it calls `stop()`.
//

import Foundation

@MainActor
final class LiveTVSessionHandoff {
    let channel: UnifiedChannel
    let player: AetherPlayer
    /// The Plex tuner's timeline keepalive, still running. A no-op object for
    /// other sources.
    let keepalive: PlexLiveTimelineKeepalive
    /// Whether AVPlayer is playing the origin's HLS itself, which decides who
    /// renders subtitles once the session lands.
    let isNativeHLSRoute: Bool

    private(set) var isStopped = false

    init(channel: UnifiedChannel, player: AetherPlayer,
         keepalive: PlexLiveTimelineKeepalive, isNativeHLSRoute: Bool) {
        self.channel = channel
        self.player = player
        self.keepalive = keepalive
        self.isNativeHLSRoute = isNativeHLSRoute
    }

    /// End the session: release the tuner and stop the engine.
    func stop() {
        guard !isStopped else { return }
        isStopped = true
        keepalive.stop()
        player.stop()
    }
}
