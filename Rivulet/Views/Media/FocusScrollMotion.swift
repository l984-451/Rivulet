// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Horizontal shelf timing and vertical grid reveal geometry.
// Detail transitions have their own timing.

import CoreGraphics
import Foundation

enum FocusScrollMotion {
    /// Duration, in seconds, of a horizontal shelf settle.
    static let settleDuration: CFTimeInterval = 0.6

    /// Eased progress for a horizontal shelf settle. Cubic ease-out: fast start,
    /// decelerating to a gentle stop. `t` is linear progress in 0...1.
    static func ease(_ t: Double) -> Double {
        1 - pow(1 - t, 3)
    }

    /// Edge margin the focused item keeps when a long list scrolls.
    static let edgeInset: CGFloat = 180

    /// Smallest offset change that keeps `frame` at least `edgeInset` inside a
    /// viewport of `height` resting at `offset`. An item too tall to fit is centred.
    static func minimalOffset(revealing frame: CGRect, from offset: CGFloat, height: CGFloat) -> CGFloat {
        let inset = height >= 2 * edgeInset ? edgeInset : 0
        if frame.height > height - 2 * inset { return frame.midY - height / 2 }
        if frame.minY < offset + inset { return frame.minY - inset }
        if frame.maxY > offset + height - inset { return frame.maxY - height + inset }
        return offset
    }
}
