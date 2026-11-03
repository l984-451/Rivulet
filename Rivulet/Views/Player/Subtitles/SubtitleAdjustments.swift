// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SubtitleAdjustments.swift
//  Rivulet
//
//  Subtitle delay and height steppers for the VOD and Live TV Subtitles panels.
//  Delay is sticky per media (ratingKey or channel id). Height is one global offset
//  from AVPlayer's position (#461), and does not move a cue that carries its own placement.
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

    // MARK: - Height (global)

    /// Points moved per stepper press.
    static let heightUnitPt: CGFloat = 10
    /// Stepper range: far enough down to reach the screen edge under a wide film's
    /// letterbox bar, and up to the top of the screen.
    static let heightUnitRange = -30...80

    private static let heightKey = "subtitleHeightUnits"

    /// Height offset in UNITS (positive = subtitles sit higher). 0 is AVPlayer's position.
    static var heightUnits: Int {
        get { clampUnits(UserDefaults.standard.integer(forKey: heightKey)) }
        set { UserDefaults.standard.set(clampUnits(newValue), forKey: heightKey) }
    }

    // MARK: - Rail clearance

    /// The rail's TOP edge measured from the bottom of the SCREEN: the rail
    /// spans the screen's bottom `PlayerRailView.railHeight` (340) points.
    static let railTopFromScreenBottom: CGFloat = 340

    /// The margin a resting cue box keeps off the picture bottom, as a fraction of
    /// picture height. Measured against AVKit (tvOS 27), the same for every style.
    static let bottomMarginFraction: CGFloat = 0.05

    /// The margin a cue box keeps off the rail top while the rail is up. AVKit's
    /// lift is a constant, the same for every style, picture shape and caption
    /// size (measured, tvOS 27 sim).
    static let railMargin: CGFloat = 22

    /// The lowest a caption may sit while the rail is showing. Lives here
    /// because BOTH overlays need it and they must agree: captions should not
    /// change height when a title falls back from the engine to the HLS route.
    /// How much higher AVKit sets captions while an info pane is open: just above
    /// its risen pills (measured, tvOS 27 sim; the pills rise 334, captions 116).
    static let paneLift: CGFloat = 116

    static let controlsFloor: CGFloat = railTopFromScreenBottom + railMargin

    /// "0", "+3", "-2" — the stepper's centre label.
    static func formattedHeight(_ units: Int) -> String {
        units == 0 ? "0" : String(format: "%+d", units)
    }

    /// Extra bottom padding for the default caption band, from the stored units.
    static func heightOffset(forUnits units: Int) -> CGFloat {
        CGFloat(clampUnits(units)) * heightUnitPt
    }

    private static func clampUnits(_ units: Int) -> Int {
        min(max(units, heightUnitRange.lowerBound), heightUnitRange.upperBound)
    }
}
