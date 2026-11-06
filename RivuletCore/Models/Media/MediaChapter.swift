// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  MediaChapter.swift
//  Rivulet
//
//  Chapter marker on a playable item.
//

import Foundation

struct MediaChapter: Hashable, Identifiable, Sendable {
    let id: String
    let title: String?
    let start: TimeInterval
    let end: TimeInterval?
    let thumbnailURL: URL?
}
