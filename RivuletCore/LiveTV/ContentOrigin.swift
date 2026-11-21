// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContentOrigin.swift
//  Rivulet
//
//  Where an IPTV list says a category or title is from, as the viewer reads
//  it: the country or language tag the panel put in front ("┃NL┃", "| UK |",
//  "┃FR-4K┃") shown as a flag before the name, once the tag itself is gone.
//  A language with no one country (Arabic, ex-Yugoslav) keeps its short code;
//  several languages, a globe. Tags that name no place (PPV, UCL) mark nothing.
//

import Foundation

nonisolated enum ContentOrigin {
    /// Tags whose letters are not a country code, or not the one they look like.
    private static let named: [String: String] = [
        "UK": "GB", "EN": "GB", "ENG": "GB", "USA": "US", "QC": "CA",
        "HINDI": "IN", "TAMIL": "IN", "TELUGU": "IN", "PUNJABI": "IN", "MALAYALAM": "IN",
        "PAKISTAN": "PK", "PAK": "PK", "SOM": "SO", "LAT": "MX", "LATINO": "MX",
    ]
    /// Groups with no single flag.
    private static let symbols: [String: String] = [
        "MULTI": "🌐", "INT": "🌐", "WORLD": "🌐", "ASIA": "🌏", "AFRICA": "🌍",
    ]
    /// Words in a tag that say nothing on a badge ("MULTI / LINGO").
    private static let fillerWords: Set<String> = ["LINGO", "LANG", "LANGUAGES"]
    /// Languages read as their code: "AR" here is Arabic, not Argentina.
    private static let languages: Set<String> = ["AR", "EXYU", "EX-YU", "KURD", "VO", "VOSTFR"]

    /// The flag, symbol or code for a tag ("NL", "FR-4K", "MULTI / LINGO"), nil when it names no place.
    static func marker(forTag tag: String) -> String? {
        origin(forTag: tag).map(marker(forOrigin:))
    }

    /// The place a tag names, as a stable key: a region ("NL", "GB" for "UK"), a language
    /// code ("AR") or a group ("MULTI"). What a smart list keeps.
    static func origin(forTag tag: String) -> String? {
        let base = tag.uppercased()
            .split(whereSeparator: { $0 == " " || $0 == "/" || $0 == "-" }).first.map(String.init) ?? ""
        if symbols[base] != nil || languages.contains(base) { return base }
        let region = named[base] ?? base
        guard region.count == 2, region.allSatisfy({ $0.isASCII && $0.isLetter }),
              Locale.Region.isoRegions.contains(where: { $0.identifier == region }) else { return nil }
        return region
    }

    /// The first origin among a name's tags.
    static func origin(forTags tags: [String]) -> String? {
        tags.lazy.compactMap(origin(forTag:)).first
    }

    /// An origin's flag, symbol or code.
    static func marker(forOrigin origin: String) -> String {
        if let symbol = symbols[origin] { return symbol }
        if languages.contains(origin) { return origin }
        return flag(origin)
    }

    /// An origin as the viewer reads it: "🇳🇱 Netherlands", "Arabic", "🌐 Multilingual".
    static func title(forOrigin origin: String) -> String {
        let name: String
        switch origin {
        case "MULTI": name = String(localized: "Multilingual")
        case "INT", "WORLD": name = String(localized: "International")
        case "ASIA": name = String(localized: "Asia")
        case "AFRICA": name = String(localized: "Africa")
        default:
            if languages.contains(origin) {
                if origin == "VO" || origin == "VOSTFR" { return String(localized: "Original Version") }
                if origin == "EXYU" || origin == "EX-YU" { return String(localized: "Ex-Yugoslav") }
                let code = origin == "KURD" ? "ku" : origin.lowercased()
                name = Locale.current.localizedString(forLanguageCode: code)
                    .flatMap { $0.lowercased() == origin.lowercased() ? nil : $0 } ?? origin
                // A language reads as its name alone; its code adds nothing beside it.
                return name
            }
            name = Locale.current.localizedString(forRegionCode: origin) ?? origin
        }
        return "\(marker(forOrigin: origin)) \(name)"
    }

    /// The first marker among a name's tags.
    static func marker(forTags tags: [String]) -> String? {
        tags.lazy.compactMap(marker(forTag:)).first
    }

    /// A name without its tags, after the marker of the first that has one: "┃NL┃ Comedy" reads "🇳🇱 Comedy".
    static func marked(_ name: String) -> String {
        let (bare, tags) = XtreamService.splitTags(name)
        guard let sign = marker(forTags: tags) else { return bare }
        return "\(sign) \(bare)"
    }

    /// A poster badge for a title's tag: its marker with what else the tag says ("FR-4K" reads "🇫🇷 4K").
    static func badge(forTag tag: String?) -> String? {
        guard let tag, !tag.isEmpty else { return nil }
        guard let sign = marker(forTag: tag) else { return tag }
        let parts = tag.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "/" })
        let rest = parts.dropFirst()
            .filter { marker(forTag: String($0)) == nil && !fillerWords.contains($0.uppercased()) }
            .joined(separator: " ")
        return rest.isEmpty ? sign : "\(sign) \(rest)"
    }

    private static func flag(_ region: String) -> String {
        String(String.UnicodeScalarView(region.unicodeScalars.compactMap { Unicode.Scalar(0x1F1E6 + $0.value - 65) }))
    }
}
