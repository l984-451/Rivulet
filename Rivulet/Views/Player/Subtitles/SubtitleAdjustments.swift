// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SubtitleAdjustments.swift
//  Rivulet
//
//  Subtitle delay and height steppers for the VOD and Live TV Subtitles panels.
//  Both are sticky per media (ratingKey or channel id) and default to 0. Height
//  does not move a cue that carries its own placement.
//

import Foundation
import CoreGraphics

enum SubtitleAdjustments {

    // MARK: - Delay (per media)

    /// One stepper press worth of delay, in seconds.
    static let delayStep: Double = 0.1

    private static let delayMapKey = "subtitleDelayByMedia"

    /// Stored delay for a media key ("plex:<ratingKey>" / "live:<channelId>").
    /// 0 when never adjusted.
    static func delay(forKey key: String) -> Double {
        let map = UserDefaults.standard.dictionary(forKey: delayMapKey) as? [String: Double]
        return map?[key] ?? 0
    }

    /// Persists `value` for `key`. A value of 0 removes the entry so the map
    /// only holds media the user actually adjusted.
    static func setDelay(_ value: Double, forKey key: String) {
        var map = (UserDefaults.standard.dictionary(forKey: delayMapKey) as? [String: Double]) ?? [:]
        if abs(value) < delayStep / 2 {
            map.removeValue(forKey: key)
        } else {
            map[key] = value
        }
        UserDefaults.standard.set(map, forKey: delayMapKey)
    }

    /// Rounds a raw delay to one decimal so repeated ±0.1 steps can't drift
    /// into binary-fraction noise (0.30000000000000004).
    static func roundedDelay(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }

    /// "0.0s", "+0.3s", "-1.2s" — the stepper's centre label.
    static func formattedDelay(_ value: Double) -> String {
        if abs(value) < delayStep / 2 { return "0.0s" }
        return String(format: "%+.1fs", value)
    }

    // MARK: - Height (per media)

    /// Points moved per stepper press.
    static let heightUnitPt: CGFloat = 10
    /// Stepper range: ±10 units (±100 pt).
    static let heightUnitMax = 10

    /// Defaults key holding the height for one media key. A key per media
    /// rather than one entry in a map, unlike delay, so a media that was never
    /// adjusted costs nothing and clearing one is a plain remove.
    private static func heightKey(forMediaKey mediaKey: String) -> String {
        "subtitleHeightUnits:\(mediaKey)"
    }

    /// Height offset in UNITS for a media key (positive = subtitles sit
    /// higher). 0 when never adjusted.
    static func heightUnits(forMediaKey mediaKey: String) -> Int {
        clampUnits(UserDefaults.standard.integer(forKey: heightKey(forMediaKey: mediaKey)))
    }

    /// Persists `units` for `mediaKey`. A value of 0 removes the entry, so
    /// defaults never accumulate for media the user only watched.
    static func setHeightUnits(_ units: Int, forMediaKey mediaKey: String) {
        let key = heightKey(forMediaKey: mediaKey)
        let clamped = clampUnits(units)
        if clamped == 0 {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(clamped, forKey: key)
        }
    }

    // MARK: - Rail clearance

    /// The rail's TOP edge measured from the bottom of the SCREEN: the rail
    /// spans the screen's bottom `PlayerRailView.railHeight` (340) points.
    static let railTopFromScreenBottom: CGFloat = 340

    /// The margin a resting caption keeps off the picture bottom, as a fraction
    /// of picture height. Measured against AVKit (tvOS 27): its built-in Default
    /// style sits 3.5pt higher than every other style.
    static let bottomMarginFraction: CGFloat = 0.0493
    static let systemDefaultBottomMarginFraction: CGFloat = 0.0526

    /// The margin a caption keeps off the rail top while the rail is up. AVKit's
    /// lift is a constant, the same for every picture shape and caption size;
    /// the built-in Default style sits higher, as it does at rest (measured,
    /// tvOS 27 sim, within 1pt at 1.0, 1.5 and Default; device agrees).
    static let railMargin: CGFloat = 19
    static let systemDefaultRailMargin: CGFloat = 26

    /// The lowest a caption may sit while the rail is showing. Lives here
    /// because BOTH overlays need it and they must agree: captions should not
    /// change height when a title falls back from the engine to the HLS route.
    /// How much higher AVKit sets captions while an info pane is open: just above
    /// its risen pills (measured, tvOS 27 sim; the pills rise 334, captions 116).
    static let paneLift: CGFloat = 116

    static func controlsFloor(isSystemDefault: Bool) -> CGFloat {
        railTopFromScreenBottom + (isSystemDefault ? systemDefaultRailMargin : railMargin)
    }

    /// "0", "+3", "-2" — the stepper's centre label.
    static func formattedHeight(_ units: Int) -> String {
        units == 0 ? "0" : String(format: "%+d", units)
    }

    /// Extra bottom padding for the default caption band, from the stored units.
    static func heightOffset(forUnits units: Int) -> CGFloat {
        CGFloat(clampUnits(units)) * heightUnitPt
    }

    private static func clampUnits(_ units: Int) -> Int {
        max(-heightUnitMax, min(heightUnitMax, units))
    }
}
