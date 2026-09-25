// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ProfanityDictionary.swift
//  Rivulet
//
//  Categorized word/phrase list used to mute language directly from the
//  subtitle track — the same idea as cleanvid and the Kodi "mute profanity"
//  add-on, but applied live instead of re-encoding the file. The lists are
//  intentionally compact and easy to edit; they are a starting point, not an
//  exhaustive dictionary. They hold the forms subtitles actually use
//  ("fuckin'", "dammit"), because an entry only ever matches a whole word.
//

import Foundation

/// A single dictionary entry: a lowercased word or phrase, its category, and
/// how strong it is.
nonisolated struct ProfanityEntry: Sendable {
    let term: String
    let category: FilterCategory
    let severity: FilterSeverity
}

/// Which language categories a line of dialogue contains, independent of the
/// user's settings. Lets a whole subtitle file be scanned once and re-judged
/// cheaply when a setting changes.
nonisolated struct LanguageHits: Sendable, Equatable {
    private(set) var categories: Set<FilterCategory> = []
    /// Strongest profanity in the line; nil when there is none.
    private(set) var strongestProfanity: FilterSeverity?

    var isEmpty: Bool { categories.isEmpty }

    mutating func record(_ entry: ProfanityEntry) {
        categories.insert(entry.category)
        if entry.category == .profanity {
            strongestProfanity = max(strongestProfanity ?? entry.severity, entry.severity)
        }
    }

    /// Profanity honors the user's strength threshold; every other language
    /// category (slurs, blasphemy, crude/sexual) is all-or-nothing.
    func mutes(enabledCategories: Set<FilterCategory>, profanityThreshold: FilterSeverity) -> Bool {
        for category in categories where enabledCategories.contains(category) {
            guard category == .profanity else { return true }
            if let strongestProfanity, strongestProfanity >= profanityThreshold { return true }
        }
        return false
    }
}

/// The bundled language dictionary plus the matcher that decides whether a
/// subtitle line should be muted for the user's enabled categories.
nonisolated enum ProfanityDictionary {

    // MARK: - Matching

    /// Whether `text` should be muted, given the enabled categories and the
    /// minimum profanity severity the user wants filtered.
    static func shouldMute(text: String,
                           enabledCategories: Set<FilterCategory>,
                           profanityThreshold: FilterSeverity) -> Bool {
        guard !enabledCategories.isEmpty else { return false }
        return hits(in: text).mutes(enabledCategories: enabledCategories,
                                    profanityThreshold: profanityThreshold)
    }

    /// Every language category `text` contains.
    ///
    /// - Single words match on whole-word boundaries so "class" never trips
    ///   "ass"; masked spellings (f***, sh!t) are matched too.
    /// - "fuck" also matches inside a word ("clusterfuck"): no innocent English
    ///   word contains it. No other term gets that treatment, because every
    ///   other one does ("Scunthorpe", "cocktail", romanized Japanese names).
    /// - Multi-word phrases (e.g. "god damn") match on the normalized line.
    static func hits(in text: String) -> LanguageHits {
        var hits = LanguageHits()
        guard !text.isEmpty else { return hits }
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return hits }

        // Phrase pass (multi-word terms) on the normalized line with masking
        // characters stripped, so "God damn!" still ends in a word boundary.
        let phraseLine = normalized
            .filter { !maskingCharacters.contains($0) }
            .split(separator: " ").joined(separator: " ")
        let paddedLine = " \(phraseLine) "
        for entry in phraseEntries where paddedLine.contains(" \(entry.term) ") {
            hits.record(entry)
        }

        // Word pass: tokenize once, test each token's candidate spellings
        // against the single-word set.
        for token in normalized.split(separator: " ") {
            for candidate in candidateForms(String(token)) {
                if let entry = wordIndex[candidate] {
                    hits.record(entry)
                } else {
                    for entry in infixEntries where candidate.contains(entry.term) {
                        hits.record(entry)
                    }
                }
            }
        }
        return hits
    }

    // MARK: - Normalization

    /// Lowercase, strip subtitle formatting punctuation, and collapse
    /// whitespace so word/phrase matching is stable. Keeps apostrophes and
    /// common masking characters (* ! @ $) so "f***" and "b@stard" survive to
    /// the masking pass.
    private static func normalize(_ text: String) -> String {
        let lowered = text.lowercased()
        var out = String()
        out.reserveCapacity(lowered.count)
        for ch in lowered {
            if ch == "'" || ch == "’" {
                out.append("'")  // curly → straight so phrase terms match
            } else if ch.isLetter || ch.isNumber {
                out.append(ch)
            } else if maskingCharacters.contains(ch) {
                out.append(ch)
            } else {
                out.append(" ")
            }
        }
        return out.split(separator: " ").joined(separator: " ")
    }

    private static let maskingCharacters: Set<Character> = ["*", "!", "@", "$", "#", "%", "&"]

    /// Candidate spellings for a token, in lookup order. Masking characters are
    /// ambiguous — "sh!t" uses "!" as a letter, "shit!" uses it as punctuation —
    /// so both readings are tried: dropped entirely, and leet-substituted.
    /// Known short residues of fully-masked words ("f***" → "f") expand via
    /// `maskedStubs`.
    private static func candidateForms(_ token: String) -> [String] {
        // Stub expansion ("f" → "fuck") only makes sense when the token was
        // actually masked with a censor glyph; without this guard, innocent
        // short tokens ("B1") would expand into hits. A one-letter stub needs
        // two glyphs, so a musical key ("F#", "B#") never reads as one.
        let glyphCount = token.filter { censorGlyphs.contains($0) }.count
        var forms: [String] = []
        func add(_ raw: String) {
            guard !raw.isEmpty else { return }
            let expands = glyphCount >= (raw.count == 1 ? 2 : 1)
            let form = (expands ? maskedStubs[raw] : nil) ?? raw
            if !forms.contains(form) { forms.append(form) }
        }
        // A possessive is its word ("bitch's" → "bitch").
        if token.hasSuffix("'s") {
            add(String(token.dropLast(2)).filter { !maskingCharacters.contains($0) })
        }
        // Other apostrophes never carry meaning for the lookup; strip them
        // once. ("fuckin'" → "fuckin")
        let base = token.filter { $0 != "'" && $0 != "’" }
        // Reading 1: masking characters are punctuation — drop them.
        // ("shit!" → "shit", "f***" → "f" → stub)
        add(base.filter { !maskingCharacters.contains($0) })
        // Reading 2: masking characters stand in for letters — substitute.
        // ("sh!t" → "shit", "b@stard" → "bastard", "sh1t" → "shit")
        var substituted = String()
        substituted.reserveCapacity(base.count)
        for ch in base {
            switch ch {
            case "@": substituted.append("a")
            case "$": substituted.append("s")
            case "!", "1": substituted.append("i")
            case "0": substituted.append("o")
            case "*", "#", "%", "&": break
            default: substituted.append(ch)
            }
        }
        add(substituted)
        return forms
    }

    /// Characters that mark a token as deliberately censored ("f***", "s#it").
    private static let censorGlyphs: Set<Character> = ["*", "#", "%", "&"]

    /// Short residues of masked words → canonical term.
    private static let maskedStubs: [String: String] = [
        "f": "fuck",
        "fk": "fuck",
        "fck": "fuck",
        "fin": "fucking",
        "fing": "fucking",
        "fkin": "fucking",
        "fking": "fucking",
        "fckin": "fucking",
        "fcking": "fucking",
        "sh": "shit",
        "sht": "shit",
        "b": "bitch",
        "btch": "bitch",
        "ahole": "asshole"
    ]

    // MARK: - Dictionary

    /// Single-word entries indexed for O(1) lookup.
    private static let wordIndex: [String: ProfanityEntry] = {
        var index: [String: ProfanityEntry] = [:]
        for entry in wordEntries { index[entry.term] = entry }
        return index
    }()

    /// Terms that also match inside a longer word. See `hits(in:)` before
    /// adding one.
    private static let infixEntries: [ProfanityEntry] = [
        .init(term: "fuck", category: .profanity, severity: .strong)
    ]

    private static func entries(_ terms: [String], _ category: FilterCategory,
                                _ severity: FilterSeverity) -> [ProfanityEntry] {
        terms.map { ProfanityEntry(term: $0, category: category, severity: severity) }
    }

    /// Single-word terms. Kept deliberately small and legible; extend as needed.
    private static let wordEntries: [ProfanityEntry] = [
        entries(["damn", "damned", "dammit", "damnit", "hell", "crap", "crappy", "bloody",
                 "piss", "pissed", "pisses", "pissing", "bugger", "git"],
                .profanity, .mild),
        entries(["ass", "asses", "arse", "arses", "asshole", "assholes", "arsehole", "arseholes",
                 "jackass", "jackasses", "dumbass", "dumbasses", "smartass", "badass", "fatass",
                 "bastard", "bastards", "bitch", "bitches", "bitching", "bitchy", "bitchin",
                 "sumbitch", "dick", "dicks", "dickhead", "dickheads", "prick", "pricks",
                 "douche", "douchebag", "douchebags", "bollocks", "wanker", "wankers"],
                .profanity, .moderate),
        entries(["fuck", "fucker", "fucking", "fucked", "motherfucker",
                 "shit", "shits", "shitty", "shitting", "shitted", "shite", "shithead",
                 "shitheads", "shithole", "shitholes", "shitload", "shitless", "shitstorm",
                 "bullshit", "bullshitting", "bullshitter", "horseshit", "dipshit", "dipshits",
                 "apeshit", "batshit", "chickenshit", "jackshit",
                 "cocksucker", "cocksuckers", "sonofabitch"],
                .profanity, .strong),
        entries(["boobs"], .sexualLanguage, .mild),
        entries(["whore", "whores", "slut", "sluts", "slutty", "tits", "titties", "horny"],
                .sexualLanguage, .moderate),
        entries(["cock", "cocks", "pussy", "pussies", "cunt", "cunts", "twat", "twats",
                 "blowjob", "blowjobs", "handjob", "dildo"],
                .sexualLanguage, .strong),
        entries(["goddamn", "goddamned", "goddam", "goddammit", "goddamnit", "omg"],
                .blasphemy, .moderate),
        // Slurs are all-or-nothing, so their severity is never read. A slur
        // that doubles as an idiom ("a chink in the armor") still mutes: for a
        // filter, a muted idiom is the cheaper mistake.
        entries(["nigger", "niggers", "nigga", "niggas", "chink", "chinks", "gook", "gooks",
                 "spic", "spics", "wetback", "wetbacks", "kike", "kikes", "beaner", "beaners",
                 "raghead", "ragheads", "towelhead", "towelheads", "paki", "pakis", "wop", "wops",
                 "jap", "japs", "kraut", "krauts", "polack", "polacks", "chinaman", "honkies",
                 "faggot", "faggots", "fag", "fags", "dyke", "dykes", "tranny", "trannies",
                 "retard", "retards", "retarded"],
                .slur, .strong)
    ].flatMap { $0 }

    /// Multi-word phrases. Matched against the normalized line, so word order
    /// and boundaries are respected. Blasphemy is phrase-led on purpose so the
    /// word "god" alone never mutes ordinary dialogue ("thank god").
    private static let phraseEntries: [ProfanityEntry] = [
        entries(["god's sake"], .blasphemy, .mild),
        entries(["god damn", "jesus christ", "jesus h christ", "jesus fucking christ",
                 "sweet jesus", "christ almighty", "christ's sake", "god almighty",
                 "my god", "oh god", "good god", "swear to god", "love of god"],
                .blasphemy, .moderate),
        entries(["piss off", "dumb ass", "jack ass"], .profanity, .moderate),
        entries(["son of a bitch"], .profanity, .strong),
        entries(["jerk off", "jerking off"], .sexualLanguage, .moderate),
        entries(["half breed"], .slur, .strong)
    ].flatMap { $0 }
}
