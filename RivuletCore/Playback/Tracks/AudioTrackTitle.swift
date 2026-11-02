//
//  AudioTrackTitle.swift
//  Rivulet
//
//  What an audio stream's own title tells the listener (#447). Most titles only
//  repeat the language and the format, or are the file's release name.
//

import Foundation

nonisolated enum AudioTrackTitle {
    /// Format vocabulary, from the titles on a real library ("DTS-HD MA / 5.1 / 48 kHz / 3596 kbps").
    private static let formatWords = #"(?i)(?<![\p{L}\p{N}])(?:"#
        + #"(?:dolby(?:\s+digital(?:\s+plus)?)?|true-?hd|dts(?:[-.:](?:x|hd|hr|ma))*|hdma|hd|hr|ma|master\s+audio"#
        + #"|high[-\s]+res(?:olution)?|ddp|dd\+?|e?-?ac-?3|eac|he-aac|lc|aac|flac|alac|opus|vorbis|mp[23]|l?pcm|wav)[\d.,]*"#
        + #"|\d[\d .,-]*\s?(?:k?hz|[km]b(?:ps|/?s)|bits?|ch|chnls|channels?|objects?)|\d[.,]\d"#
        + #"|atmos|atoms|surround|ex|core|stereo|mono|channels?|vbr|cbr|with|audio|track|soundtrack|mix|main(?:\s+movie)?"#
        + #"|descriptive|description|described|blu-?ray|remux|web-?dl|webrip|eb3|standard\s+format"#
        + #")(?![\p{L}\p{N}])"#
    private static let separators = "/|~@¬:,;.\\-–—"
    /// Where a language or country name is likely to be written in some other language.
    private static let nameLocales = ["en", "fr", "de", "es", "it", "pt", "ru", "zh", "ja", "ko", "hi", "ar"]

    /// The title with language and format removed; nil when nothing is left to say.
    static func description(of title: String?, language: String?, languageCode: String?) -> String? {
        guard var text = title?.trimmingCharacters(in: .whitespacesAndNewlines), !text.contains("://"),
              !text.split(whereSeparator: \.isWhitespace).contains(where: { $0.split(separator: ".").count >= 4 })
        else { return nil }

        // A commentary names its speakers, so only the text before the word is cleaned.
        var speakers = ""
        if let word = text.range(of: "commentary", options: .caseInsensitive) {
            speakers = String(text[word.lowerBound...])
            text = String(text[..<word.lowerBound])
        }

        let edges = CharacterSet(charactersIn: separators.replacingOccurrences(of: "\\", with: "")).union(.whitespacesAndNewlines)
        text = text
            .replacingOccurrences(of: #"(?i)\(from [^)]*\)|\bw/"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: formatWords, with: " ", options: .regularExpression)
            .replacingOccurrences(of: languagePattern(language, languageCode), with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\(\W*\)|\[\W*\]"#, with: " ", options: .regularExpression)
        // Removing words can leave half a bracket behind.
        for (open, close) in [("(", ")"), ("[", "]")] where text.components(separatedBy: open).count != text.components(separatedBy: close).count {
            text = text.replacingOccurrences(of: open, with: " ").replacingOccurrences(of: close, with: " ")
        }
        text = text
            .replacingOccurrences(of: "\\s+(?:[\(separators)]+\\s+)+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: edges)
            .replacingOccurrences(of: #"^[(\[]([^()\[\]]*)[)\]]$"#, with: "$1", options: .regularExpression)

        let described = [text, speakers].filter { !$0.isEmpty }.joined(separator: " ")
        // Bare "Commentary" is the role, which the menu already shows in the user's language.
        guard described.contains(where: \.isLetter), described.lowercased() != "commentary" else { return nil }
        return described
    }

    private static func languagePattern(_ language: String?, _ code: String?) -> String {
        // A country only ever repeats the language ("English (United States)").
        var names = nameLocales.flatMap { locale in
            ["US", "GB"].compactMap { Locale(identifier: locale).localizedString(forRegionCode: $0) }
        } + [language, code].compactMap { $0 }
        if let code {
            names.append(Locale.LanguageCode(code).identifier(.alpha3) ?? code)
            names += (nameLocales + [code]).compactMap { Locale(identifier: $0).localizedString(forLanguageCode: code) }
        }
        let alternatives = Set(names).map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        return "(?i)(?<![\\p{L}\\p{N}])(?:\(alternatives))(?![\\p{L}\\p{N}])"
    }
}
