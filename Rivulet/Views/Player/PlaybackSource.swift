// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlaybackSource.swift
//  Rivulet
//
//  Where the player's item comes from. `.plex` is the legacy path, driven
//  by `PlexMetadata` and the Plex server. `.provider` plays any
//  `MediaProvider` item from its resolved stream and reports through the
//  provider's own `ProgressReporter`; no Plex request is made for it.
//

import Foundation

/// What a provider hands the player for one item. Built by `ProviderPlayback.prepare`.
struct ProviderPlayback: Sendable {
    let provider: any MediaProvider
    let item: MediaItem
    let detail: MediaItemDetail
    var stream: StreamInfo
    let extras: PlaybackExtras
    var quality = ProviderQuality()
}

/// The streaming quality `prepare` settled on for a provider stream.
struct ProviderQuality: Sendable {
    /// The session pick, else the Home or Away setting.
    var choice: StreamingQuality = .original
    var plan: StreamPlan = .original
    var isHome = true
    /// The probe behind an Auto decision, reused for 10 minutes.
    var throughput: (kbps: Int, at: Date)?
    /// The uncapped direct stream, which a later Auto pick probes.
    var probeURL: URL?
}

enum PlaybackSource {
    case plex                              // legacy path, unchanged
    case provider(ProviderPlayback)
}
