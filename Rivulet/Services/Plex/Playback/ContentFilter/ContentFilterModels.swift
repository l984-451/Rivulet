// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContentFilterModels.swift
//  Rivulet
//
//  Value types for the local content filter (VidAngel/ClearPlay-style
//  real-time muting and scene skipping). Nothing here touches the media
//  file — filters are applied live during playback (mute the audio, or
//  seek past a scene), matching the client-side approach protected by the
//  Family Movie Act of 2005.
//

import Foundation

// MARK: - Severity

/// How strong a filtered word/scene is. Lets the user keep mild language while
/// still muting strong language. Ordered: `.mild < .moderate < .strong`.
nonisolated enum FilterSeverity: Int, Codable, Sendable, Comparable, CaseIterable, CustomStringConvertible {
    case mild = 0
    case moderate = 1
    case strong = 2

    static func < (lhs: FilterSeverity, rhs: FilterSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var description: String {
        switch self {
        case .mild: return "Mild"
        case .moderate: return "Moderate"
        case .strong: return "Strong"
        }
    }

    /// Map an MCF/EDL severity token onto our scale.
    init(mcf raw: String) {
        switch raw.trimmingCharacters(in: .whitespaces).lowercased() {
        case "low", "mild", "1":            self = .mild
        case "high", "severe", "strong", "3": self = .strong
        default:                            self = .moderate  // "medium"/"moderate"/unknown
        }
    }
}

// MARK: - Action

/// What the player does with a region: silence the audio, or seek past it.
nonisolated enum FilterAction: String, Codable, Sendable {
    case mute
    case skip

    /// Skip is the stronger action — when a cue asks for both, skip wins.
    static func strongest(_ a: FilterAction, _ b: FilterAction) -> FilterAction {
        (a == .skip || b == .skip) ? .skip : .mute
    }
}

// MARK: - Category

/// The kinds of content the filter can act on.
///
/// Text-detectable categories (`isTextDetectable`) are found automatically from
/// the subtitle track — no external data needed. Scene categories can only come
/// from an imported filter list (MCF/EDL), because dialogue text can't reveal a
/// silent violent or nude scene.
nonisolated enum FilterCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    // Detected from subtitle dialogue
    case profanity
    case blasphemy
    case slur
    case sexualLanguage
    // Scene-based (require an imported filter list)
    case violence
    case sexNudity
    case frightening
    case substances
    /// Anything an imported list tagged that we don't map to a specific bucket.
    case other

    var id: String { rawValue }

    /// True when the category can be found from subtitle text alone.
    var isTextDetectable: Bool {
        switch self {
        case .profanity, .blasphemy, .slur, .sexualLanguage: return true
        case .violence, .sexNudity, .frightening, .substances, .other: return false
        }
    }

    /// Default action when a filter list doesn't specify one. Language mutes;
    /// scenes skip.
    var defaultAction: FilterAction {
        isTextDetectable ? .mute : .skip
    }

    var displayName: String {
        switch self {
        case .profanity: return "Profanity"
        case .blasphemy: return "Blasphemy"
        case .slur: return "Slurs"
        case .sexualLanguage: return "Crude & Sexual Language"
        case .violence: return "Violence & Gore"
        case .sexNudity: return "Sex & Nudity"
        case .frightening: return "Frightening & Intense"
        case .substances: return "Drugs, Alcohol & Smoking"
        case .other: return "Other"
        }
    }

    /// UserDefaults key for this category's on/off state.
    var enabledDefaultsKey: String { "contentFilter.\(rawValue).enabled" }

    /// Sensible default: everything on once the master filter is enabled.
    var defaultEnabled: Bool { true }

    /// Categories exposed as individual toggles in Settings, in display order.
    static let userToggleable: [FilterCategory] = [
        .profanity, .blasphemy, .slur, .sexualLanguage,
        .violence, .sexNudity, .frightening, .substances
    ]

    /// Map a free-form category token (an EDL's optional 4th field, or an MCF
    /// name outside the spec) onto our set. Resilient to the many spellings
    /// community filter files use in the wild. Order matters: the first match
    /// wins, so language entries come before "sex" catches "sexual humor".
    static func matching(_ raw: String) -> FilterCategory {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        // Our own names round-trip ("sexualLanguage" must not land on "sex").
        if let exact = allCases.first(where: { $0.rawValue.lowercased() == key }) { return exact }
        for (needles, category) in categoryAliases {
            if needles.contains(where: { key.contains($0) }) { return category }
        }
        return .other
    }

    private static let categoryAliases: [(needles: [String], category: FilterCategory)] = [
        (["blasphem", "deity", "religio"], .blasphemy),
        (["slur", "racial", "racism", "ethnic", "discrimin", "sexism", "homophob"], .slur),
        (["sexualdialogue", "sexual dialogue", "sexual language", "sexual humor", "sexual-humor", "innuendo", "crude"], .sexualLanguage),
        (["nudity", "nude", "sex", "porn", "erotic", "intercourse"], .sexNudity),
        (["gore", "violen", "blood", "brutal", "torture", "murder", "fight", "weapon"], .violence),
        (["fright", "fear", "horror", "disturb", "intense", "jump", "scary", "scare"], .frightening),
        (["drug", "alcohol", "smok", "substance", "narcotic", "drink", "cigar", "tobacco"], .substances),
        (["profan", "language", "curse", "swear", "vulgar"], .profanity)
    ]

    /// Map a Movie Content Filter category name onto our set, following MCF's
    /// own topics (moviecontentfilter.com/specification). An MCF file is the
    /// full annotation of a title, not a per-user filter, so it also tags
    /// things no content filter should act on (product placement, "tedious"
    /// scenes, kisses). Those return nil and are dropped at parse time. Names
    /// outside the spec fall back to `matching`, and are dropped if that finds
    /// nothing either, rather than riding the master switch as `.other`.
    init?(mcfName raw: String) {
        let key = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if Self.ignoredMCFNames.contains(key) { return nil }
        if let mapped = Self.mcfNames[key] {
            self = mapped
            return
        }
        let fallback = Self.matching(key)
        guard fallback != .other else { return nil }
        self = fallback
    }

    private static let ignoredMCFNames: Set<String> = [
        // Commercial content topic
        "commercial", "advertbreak", "consumerism", "productplacement",
        // Dispensable scenes topic
        "dispensable", "idiocy", "tedious",
        // Filed under the Sex topic, but not what a family filter means by it
        "kissing"
    ]

    /// Every category in the MCF 1.1.0 spec, lowercased, by topic.
    private static let mcfNames: [String: FilterCategory] = {
        var names: [String: FilterCategory] = [:]
        func add(_ category: FilterCategory, _ list: [String]) {
            for name in list { names[name] = category }
        }
        add(.profanity, ["language", "swearing", "namecalling"])
        add(.blasphemy, ["blasphemy"])
        add(.sexualLanguage, ["sexualdialogue", "vulgarity"])
        add(.slur, ["discrimination", "adultism", "antisemitism", "genderism", "homophobia",
                    "misandry", "misogyny", "racism", "sexism", "supremacism", "transphobia",
                    "xenophobia"])
        add(.sexNudity, ["nudity", "barebuttocks", "exposedgenitalia", "fullnudity", "toplessness",
                         "sex", "adultery", "analsex", "coitus", "masturbation", "objectification",
                         "oralsex", "premaritalsex", "promiscuity", "prostitution"])
        add(.violence, ["violence", "choking", "crueltytoanimals", "culturalviolence", "desecration",
                        "emotionalviolence", "kicking", "massacre", "murder", "punching", "rape",
                        "slapping", "slavery", "stabbing", "torture", "warfare", "weapons"])
        add(.frightening, ["fear", "accident", "acrophobia", "aliens", "arachnophobia", "astraphobia",
                           "aviophobia", "chemophobia", "claustrophobia", "coulrophobia", "cynophobia",
                           "death", "dentophobia", "emetophobia", "enochlophobia", "explosion", "fire",
                           "gerascophobia", "ghosts", "grave", "hemophobia", "hylophobia",
                           "melissophobia", "misophonia", "musophobia", "mysophobia", "nosocomephobia",
                           "nyctophobia", "siderodromophobia", "thalassophobia", "vampires"])
        add(.substances, ["drugs", "alcohol", "antipsychotics", "cigarettes", "depressants", "gambling",
                          "hallucinogens", "stimulants"])
        return names
    }()
}

// MARK: - Region

/// A single time-coded filter window from an imported list.
nonisolated struct FilterRegion: Identifiable, Codable, Sendable {
    let id: Int
    let start: TimeInterval
    let end: TimeInterval
    let category: FilterCategory
    let severity: FilterSeverity
    let action: FilterAction

    func contains(_ time: TimeInterval) -> Bool {
        time >= start && time < end
    }
}

// MARK: - List

/// An imported, time-coded filter list for one title (parsed from MCF or EDL).
nonisolated struct ContentFilterList: Codable, Sendable {
    /// Regions sorted by start time.
    let regions: [FilterRegion]

    init(regions: [FilterRegion]) {
        self.regions = regions.sorted { $0.start < $1.start }
    }

    var isEmpty: Bool { regions.isEmpty }

    static let empty = ContentFilterList(regions: [])
}

// MARK: - Item

/// What the filter knows about the title being played. Built by the player once
/// full metadata is in hand, so a list lookup can key on identifiers that
/// survive a library rebuild or a second server (IMDb id, file name), not only
/// the server-local rating key.
nonisolated struct ContentFilterItem: Sendable, Equatable {
    var ratingKey: String?
    var imdbID: String?
    var tmdbID: String?
    var tvdbID: String?
    /// Media file name without directory or extension, e.g. "The Matrix (1999)".
    /// The name cleanvid, Kodi and MPlayer give a sidecar EDL.
    var fileName: String?
    /// Runtime in seconds. Used to spot an MCF list timed to another release.
    var duration: TimeInterval?
    /// The title's own external subtitle file, read in full for language
    /// muting when it is in a format the filter can parse.
    var transcript: TranscriptSource?

    nonisolated struct TranscriptSource: Sendable, Equatable {
        let url: URL
        /// Plex stream codec ("srt", "ass", "vtt", …); picks the parser.
        let format: String
        /// The stream's `/library/streams/…` path, to recognize the same file
        /// when it is the subtitle track on screen.
        let streamKey: String
    }

    /// "/media/Movies/The Matrix (1999)/The Matrix (1999).mkv" → "The Matrix (1999)".
    /// Plex reports the server's own path, so Windows separators are handled too.
    static func baseName(ofPath path: String) -> String? {
        guard let last = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last else { return nil }
        let name = String(last)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }
}
