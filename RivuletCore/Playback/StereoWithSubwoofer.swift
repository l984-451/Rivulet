// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Every soundtrack as stereo with the LFE mixed into left and right, for 2.1 speakers on a
/// stereo link (#614). Per device: it follows the speakers, so it does not sync.
enum StereoWithSubwoofer {
    static let key = "stereoWithSubwoofer"
    /// The engine's `lfeMixDB`: 0 dB puts the LFE 3 dB down on each side.
    static let lfeMixDB = 0.0

    static func isOn(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }
}
