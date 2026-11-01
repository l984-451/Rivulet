// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
//
//  SystemMediaAccessibility.swift
//  Rivulet
//
//  The device's Accessibility settings that AVPlayer applies to track
//  selection on its own: Closed Captions + SDH, and Audio Descriptions.
//  They outrank Rivulet's own subtitle and audio settings, as they do in AVKit.
//

import Foundation
import MediaAccessibility

enum SystemMediaAccessibility {
    /// Accessibility > Subtitles and Captioning > Closed Captions + SDH.
    nonisolated static var captionsAlwaysOn: Bool {
        MACaptionAppearanceGetDisplayType(.user) == .alwaysOn
    }

    /// Accessibility > Audio Descriptions.
    nonisolated static var prefersAudioDescription: Bool {
        let preferred = MAAudibleMediaCopyPreferredCharacteristics().takeRetainedValue() as? [String] ?? []
        return preferred.contains(MAMediaCharacteristicDescribesVideoForAccessibility as String)
    }
}
