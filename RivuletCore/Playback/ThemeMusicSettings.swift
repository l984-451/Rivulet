// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

// Theme Music and Theme Music Volume (Settings > Appearance > Details). The tune itself is
// played by the app (ThemeMusic); the defaults live here so the rows and the player agree.

import Foundation

nonisolated enum ThemeMusicSettings {

    /// Bool; absent = on.
    static let enabledKey = "themeMusicEnabled"
    /// Int percent, one of `volumeOptions`; absent = `defaultVolume`.
    static let volumeKey = "themeMusicVolume"

    static let volumeOptions = [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
    /// Theme files are mastered loud, and the tune sits under a page the user is reading.
    static let defaultVolume = 30

    static var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    static func clampVolume(_ percent: Int) -> Int {
        min(max(percent, volumeOptions[0]), 100)
    }

    static var volumePercent: Int {
        get { clampVolume(UserDefaults.standard.object(forKey: volumeKey) as? Int ?? defaultVolume) }
        set { UserDefaults.standard.set(clampVolume(newValue), forKey: volumeKey) }
    }

    /// The player's gain, 0...1, on top of the TV's own volume.
    static var volume: Float { Float(volumePercent) / 100 }

    /// The option after `current`, wrapping 100% back to 10% (the Settings row).
    static func nextVolume(after current: Int) -> Int {
        let index = volumeOptions.firstIndex { $0 >= current } ?? volumeOptions.count - 1
        return volumeOptions[(index + 1) % volumeOptions.count]
    }

    static func volumeLabel(_ percent: Int) -> String { "\(clampVolume(percent))%" }
}
