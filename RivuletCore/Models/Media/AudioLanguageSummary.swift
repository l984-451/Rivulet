// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// The detail pages' Audio line: each language once, with its tracks' formats, as the Apple TV
/// app lists them ("Deutsch (E-AC3 5.1, AAC 2.0), Englisch (TrueHD 7.1 Atmos)").
/// Each app names a language its own way, so it passes its own `name`.
enum AudioLanguageSummary {
    static func entries(_ tracks: [AudioTrack], name: (String) -> String?) -> [String] {
        var order: [String] = []
        var formats: [String: [String]] = [:]
        for track in tracks {
            guard let code = track.language, !code.isEmpty, let language = name(code) else { continue }
            if formats[language] == nil { order.append(language); formats[language] = [] }
            // A track of unknown codec names its language with no format.
            guard track.codec.lowercased() != "unknown" else { continue }
            let format = track.qualityLabel
            if formats[language]?.contains(format) == false { formats[language]?.append(format) }
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
}
