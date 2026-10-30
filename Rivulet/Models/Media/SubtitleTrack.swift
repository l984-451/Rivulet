// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SubtitleTrack.swift
//  Rivulet
//
//  Per-subtitle-stream metadata for the subtitle picker.
//

import Foundation

struct SubtitleTrack: Hashable, Sendable, Identifiable {
    let id: String
    let index: Int
    let codec: String              // "srt", "ass", "pgs", "vobsub"
    let language: String?
    let title: String?
    let extendedTitle: String?     // long-form Plex `extendedDisplayTitle` etc.
    let isDefault: Bool
    let isForced: Bool
    let isHearingImpaired: Bool
    let isEmbedded: Bool           // native in-band delivery, not the subtitle's original storage location
    let externalURL: URL?          // populated only when this delivery mounts a sidecar
    /// Backend-side "this is the user's current pick" flag. See `AudioTrack.isSelected`.
    let isSelected: Bool
    /// Nil inherits legacy source headers; an explicit empty dictionary sends no credentials.
    var externalHTTPHeaders: [String: String]? = nil
    /// Exact native demuxer identity, distinct from the provider's selection ordinal.
    /// Only populated when the playback plan explicitly selects an embedded stream.
    var nativeStreamIndex: Int? = nil
    /// Silo's canonical sync identity survives host-side delivery projection.
    var siloSyncTarget: SiloSubtitleSyncTarget? = nil
}
