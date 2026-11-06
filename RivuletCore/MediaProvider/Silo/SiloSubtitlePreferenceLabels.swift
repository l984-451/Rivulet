// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Silo's own names for the subtitle axes, plus what the profile resolves to,
/// so Rivulet's rows read the same as Silo's settings. Pure mapping: no state.
nonisolated enum SiloSubtitlePreferenceLabels {
    /// A contract language tag ("nl", "pt-BR") as a localized name.
    static func languageName(_ tag: String) -> String {
        let identifier = tag.replacingOccurrences(of: "_", with: "-")
        if let name = Locale.current.localizedString(forIdentifier: identifier), !name.isEmpty {
            return name.capitalized
        }
        return TrackLanguage.displayName(identifier)
    }

    /// All ISO languages, augmented with server tags and the current choice.
    /// Prefer the original server or override spelling when it aliases an ISO code.
    static func languageOptions(additional: [String], current: String? = nil) -> [String] {
        var seen = Set<String>()
        var options: [(tag: String, name: String)] = []
        for tag in [current].compactMap({ $0 }) + additional + Locale.isoLanguageCodes {
            let value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = languageKey(value)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            options.append((value, languageName(value)))
        }
        return options.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.tag < $1.tag : comparison == .orderedAscending
        }.map(\.tag)
    }

    static func languageKey(_ tag: String) -> String {
        let parts = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-").lowercased().split(separator: "-")
        guard let first = parts.first else { return "" }
        let normalized = TrackLanguage.normalize(String(first))
        let language = Locale.LanguageCode(normalized).identifier(.alpha2) ?? normalized
        return ([language] + parts.dropFirst().map(String.init)).joined(separator: "-")
    }

    /// The row's trailing value: the profile's language while inheriting.
    static func languageValue(override: SiloLocalPolicyValue<String>, resolved: String?) -> String {
        switch override {
        case .inherit: return follow(resolved.map(languageName))
        case .clear: return String(localized: "None")
        case .value(let tag): return languageName(tag)
        }
    }

    /// Silo's contract labels for `playback.subtitle_mode`.
    static func modeName(_ mode: SiloSubtitleMode) -> String {
        switch mode {
        case .auto: String(localized: "Auto")
        case .always: String(localized: "Always on")
        case .off: String(localized: "Off")
        }
    }

    static func modeOptions(resolved: SiloSubtitleMode?)
        -> [(SiloLocalPolicyValue<SiloLocalSubtitleMode>, String)] {
        [(.inherit, follow(resolved.map(modeName))),
         (.value(.auto), modeName(.auto)),
         (.value(.always), modeName(.always)),
         (.value(.off), modeName(.off)),
         (.clear, String(localized: "Clear"))]
    }

    static func forcedOptions(resolved: Bool?) -> [(SiloLocalPolicyValue<Bool>, String)] {
        [(.inherit, follow(resolved.map { $0 ? String(localized: "On") : String(localized: "Off") })),
         (.value(true), String(localized: "On")),
         (.value(false), String(localized: "Off")),
         (.clear, String(localized: "Clear"))]
    }

    private static func follow(_ resolved: String?) -> String {
        guard let resolved else { return String(localized: "Follow Silo") }
        return String(localized: "Follow Silo · \(resolved)")
    }
}
