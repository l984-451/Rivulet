// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import CoreGraphics

/// The caption Height setting (#461): one global offset for the default caption
/// band, in stepper units. Positive sits higher. Shared by all three apps.
enum CaptionHeight {
    /// Points moved per step.
    static let unitPt: CGFloat = 20
    /// Far enough down to reach the screen edge under a wide film's letterbox bar,
    /// and up to the top of the screen.
    static let unitRange = -15...40
    /// The highest the band's bottom edge may rest, as a fraction of the screen height.
    static let highestBandFraction: CGFloat = 0.8
    /// Steps were 10 pt under `subtitleHeightUnits`; that value carries over halved.
    static let key: String = {
        let defaults = UserDefaults.standard, old = "subtitleHeightUnits", new = "subtitleHeightSteps"
        if defaults.object(forKey: new) == nil, defaults.object(forKey: old) != nil {
            defaults.set((Double(defaults.integer(forKey: old)) / 2).rounded(), forKey: new)
            defaults.removeObject(forKey: old)
        }
        return new
    }()

    static var units: Int {
        get { clamp(UserDefaults.standard.integer(forKey: key)) }
        set { UserDefaults.standard.set(clamp(newValue), forKey: key) }
    }

    static func step(by steps: Int) { units += steps }

    /// "0", "+3", "-2": the stepper's centre label.
    static func formatted(_ units: Int) -> String {
        units == 0 ? "0" : String(format: "%+d", units)
    }

    static func offset(forUnits units: Int) -> CGFloat {
        CGFloat(clamp(units)) * unitPt
    }

    /// Where the default band's bottom edge rests, measured from the TOP of a
    /// container of `height`: the picture's resting edge moved by the setting,
    /// kept on screen, and above `cap` (the chrome's top) when given.
    static func bandBottom(resting: CGFloat, units: Int, containerHeight height: CGFloat,
                           cap: CGFloat? = nil) -> CGFloat {
        let lifted = resting - offset(forUnits: units)
        let onScreen = min(max(lifted, height * (1 - highestBandFraction)), height)
        return min(onScreen, cap ?? onScreen)
    }

    private static func clamp(_ units: Int) -> Int {
        min(max(units, unitRange.lowerBound), unitRange.upperBound)
    }
}
