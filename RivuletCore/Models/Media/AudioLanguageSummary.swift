// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// The detail pages' Audio line on every app: each language once, with its tracks' formats in the
/// player's words (`qualityLabel`), and "AD" for an audio description track:
/// "German (E-AC3 5.1, AAC 2.0), English (TrueHD 7.1 Atmos, AD)". Each app names languages its own way.
enum AudioLanguageSummary {
    static func entries(_ tracks: [AudioTrack], name: (String) -> String?) -> [String] {
        var order: [String] = []
        var formats: [String: [String]] = [:]
        for track in tracks {
            guard let code = track.language, !code.isEmpty, let language = name(code) else { continue }
            if formats[language] == nil { order.append(language); formats[language] = [] }
            // A track of unknown codec names its language with no format.
            if track.codec.lowercased() != "unknown" { add(track.qualityLabel, to: &formats[language]) }
            if (track.title ?? track.extendedTitle ?? "").localizedCaseInsensitiveContains("descri") {
                add("AD", to: &formats[language])
            }
        }
        return order.map { language in
            let list = formats[language] ?? []
            return list.isEmpty ? language : "\(language) (\(list.joined(separator: ", ")))"
        }
    }

    static func text(_ tracks: [AudioTrack], name: (String) -> String?) -> String? {
        let list = entries(tracks, name: name)
        return list.isEmpty ? nil : list.joined(separator: ", ")
    }

    private static func add(_ format: String, to list: inout [String]?) {
        if list?.contains(format) == false { list?.append(format) }
    }
}
