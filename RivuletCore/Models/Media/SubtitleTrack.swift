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
    let isEmbedded: Bool           // false = external file; externalURL populated
    let externalURL: URL?
    /// Backend-side "this is the user's current pick" flag. See `AudioTrack.isSelected`.
    let isSelected: Bool
}
