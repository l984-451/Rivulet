// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Artwork size tiers shared by provider requests and image decoding.
/// Full-size artwork preserves the tvOS 4K ceiling; thumbnails fit poster rows.
nonisolated enum ImageQuality: Sendable {
    /// Small UI: poster rows, continue-watching, cast, episode stills, logos, blurred backdrops.
    case thumb
    /// Large surfaces that fill much of the screen: home hero, carousel, detail backdrops.
    case full
    /// Channel logos drawn at under 128 pt.
    case logo

    var maxPixelSize: CGFloat {
        switch self {
        case .thumb: return 900
        case .full:  return 3840
        case .logo:  return 256
        }
    }
}
