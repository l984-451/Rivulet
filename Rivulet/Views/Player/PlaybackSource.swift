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
    let stream: StreamInfo
    let extras: PlaybackExtras
}

enum PlaybackSource {
    case plex                              // legacy path, unchanged
    case provider(ProviderPlayback)
}
