// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import CoreGraphics

nonisolated enum PhotoLetterbox {
    /// True when a photo's aspect is more than 5% off the screen's, so its bars get the blurred fill.
    static func needsFill(imageSize: CGSize, screenSize: CGSize) -> Bool {
        guard imageSize.width > 0, imageSize.height > 0, screenSize.width > 0, screenSize.height > 0 else {
            return false
        }
        let ratio = (imageSize.width / imageSize.height) / (screenSize.width / screenSize.height)
        return abs(ratio - 1) > 0.05
    }
}
