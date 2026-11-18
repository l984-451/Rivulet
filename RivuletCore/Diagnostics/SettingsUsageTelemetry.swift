// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Which settings people use: at most once a day, one Sentry log ("Settings snapshot") whose
// attributes are the stored setting values, keyed by their UserDefaults key. Stored values, never
// the text Settings shows, so every language and all three apps report the same strings.

import Foundation
import Sentry

@MainActor
enum SettingsUsageTelemetry {
    private static let lastSentKey = "settingsSnapshotLastSent"
    /// Marks the stored-value format, so a report can skip the display-text snapshots before it.
    static let schema = "2"

    /// The synced preferences plus the device-local ones worth counting.
    static var keys: Set<String> {
        SyncCatalog.exactKeys.union([
            "showPosterTitles", "upscaleLowResolution", StereoWithSubwoofer.key, "dolbyVisionFEL", SyncCatalog.enabledKey,
            "profilePickerAfter",
        ]).union(contentFilterCategories.map { "contentFilter.\($0).enabled" })
    }

    /// `FilterCategory.userToggleable` (tvOS); pinned by a test.
    static let contentFilterCategories = ["profanity", "blasphemy", "slur", "sexualLanguage",
                                          "violence", "sexNudity", "frightening", "substances"]

    /// Free text the user typed: reported only as set or not.
    private static let freeTextKeys: Set<String> = ["contentFilter.customWords"]

    static func sendIfDue(now: Date = Date()) {
        let last = UserDefaults.standard.object(forKey: lastSentKey) as? Date ?? .distantPast
        guard now.timeIntervalSince(last) >= 24 * 60 * 60 else { return }
        UserDefaults.standard.set(now, forKey: lastSentKey)
        SentryBridge.log(.info, "Settings snapshot", attributes: snapshot())
    }

    /// "default" for a key never written. Lists report their length, never their contents.
    static func snapshot(defaults: UserDefaults = .standard) -> [String: String] {
        var values = ["schema": schema]
        for key in keys {
            values[key] = value(defaults.object(forKey: key), freeText: freeTextKeys.contains(key))
        }
        // Stored per profile and as JSON: the effective choice instead.
        values["track.subtitleMode"] = SubtitleMode.current.rawValue
        values["track.subtitleLanguage"] = TrackIntentStore.subtitleLanguage
        values["track.subtitleSDH"] = String(TrackIntentStore.subtitleSDH)
        values["track.audioLanguage"] = TrackIntentStore.audioIntent.map { TrackLanguage.normalize($0.language) } ?? "default"
        values["streaming.home"] = StreamingQuality.setting(home: true, defaults: defaults).rawValue
        values["streaming.away"] = StreamingQuality.setting(home: false, defaults: defaults).rawValue
        return values
    }

    static func value(_ stored: Any?, freeText: Bool = false) -> String {
        switch stored {
        case nil: return "default"
        case _ where freeText: return "set"
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID(): return String(number.boolValue)
        case let number as NSNumber: return number.stringValue
        case let text as String:
            // An enum's raw value; anything longer or URL-shaped could be the user's own text.
            return text.count <= 40 && !text.contains("://") ? text : "set"
        case let list as [Any]: return String(list.count)
        default: return "set"
        }
    }
}
