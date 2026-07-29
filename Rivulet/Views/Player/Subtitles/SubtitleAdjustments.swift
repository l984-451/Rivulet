// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SubtitleAdjustments.swift
//  Rivulet
//
//  User-tunable subtitle timing and placement, surfaced as steppers inside
//  the OSD Subtitles panel (VOD rail and Live TV rail).
//
//  Both adjustments are STICKY PER MEDIA: keyed by the Plex ratingKey for VOD
//  and the channel id for Live TV, so one channel can hold +3.0s and sit two
//  units higher while another stays at the defaults. Both default to 0.
//
//  Height is stored as whole units of `heightUnitPt`, clamped to
//  ±`heightUnitMax`, and does NOT move a cue that carries its own placement —
//  an authored position must not drift with an app-level offset.
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

    /// The rail's TOP edge measured from the bottom of the SCREEN:
    /// `PlayerRailView.railHeight` (260) + its bottom inset (84).
    static let railTopFromScreenBottom: CGFloat = 344

    /// The margin a caption keeps off whatever it rests above, as a fraction
    /// of the PICTURE height — the bottom of the picture with the rail hidden,
    /// the top of the rail with it showing. One number for both, so captions
    /// keep the same visual distance either way.
    ///
    /// Measured against the picture rather than the screen so letterboxed
    /// content keeps its captions on the image instead of dropping them into
    /// the black bar, and so the placement holds at any presentation size.
    /// Tuned against AVPlayer's own placement (a two-line caption centres at
    /// roughly 8% of picture height).
    static let bottomMarginFraction: CGFloat = 0.06

    /// The lowest a caption may sit while the rail is showing. Lives here
    /// because BOTH overlays need it and they must agree: captions should not
    /// change height when a title falls back from the engine to the HLS route.
    static func controlsFloor(pictureHeight: CGFloat) -> CGFloat {
        railTopFromScreenBottom + pictureHeight * bottomMarginFraction
    }

    /// "0", "+3", "-2" — the stepper's centre label.
    static func formattedHeight(_ units: Int) -> String {
        units == 0 ? "0" : String(format: "%+d", units)
    }

    /// Extra bottom padding for the subtitle overlays, derived from the stored
    /// units. Hosts pass the raw units to the overlays, which convert here, so
    /// the units→points rule lives in one place.
    ///
    /// Applied to the DEFAULT caption band only. A cue carrying its own
    /// placement is exempt — see `AetherSubtitleOverlayView.placedCue`.
    static func heightOffset(forUnits units: Int) -> CGFloat {
        CGFloat(clampUnits(units)) * heightUnitPt
    }

    private static func clampUnits(_ units: Int) -> Int {
        max(-heightUnitMax, min(heightUnitMax, units))
    }
}
