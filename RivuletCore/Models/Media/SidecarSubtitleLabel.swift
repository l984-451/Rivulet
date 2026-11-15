// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Menu label for an external subtitle file. Jellyfin and Emby name unlabeled sidecars
/// "(SRT)", so 21 files read as one entry; this tells them apart.
enum SidecarSubtitleLabel {
    /// Language name, else the filename's language tag (`movie.fr.srt`), else the title,
    /// else a numbered label. `fallbackNumber` is used when the title is not a number.
    static func make(language: String?, title: String?, path: String?, fallbackNumber: Int) -> String {
        let title = title?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let isNumeric = title.map { $0.allSatisfy(\.isNumber) } ?? false
        if let name = languageName(language) ?? path.flatMap(filenameLanguage) {
            guard let title, !isNumeric, title.caseInsensitiveCompare(name) != .orderedSame else { return name }
            return "\(name) (\(title))"
        }
        if let title, !isNumeric { return title }
        return String(localized: "Subtitle \(title ?? String(fallbackNumber))")
    }

    private static func languageName(_ code: String?) -> String? {
        guard let code, !code.isEmpty, code.lowercased() != "und" else { return nil }
        guard let name = Locale.current.localizedString(forLanguageCode: code), name.lowercased() != code.lowercased()
        else { return code.count > 3 ? code : nil }
        return name
    }

    /// `Movie.en.forced.srt` -> English. Tags are the dotted parts between the stem and extension.
    static func filenameLanguage(_ path: String) -> String? {
        let parts = (path as NSString).lastPathComponent.split(separator: ".").map(String.init)
        guard parts.count > 2 else { return nil }
        return parts.dropFirst().dropLast().reversed().lazy
            .filter { (2...3).contains($0.count) && $0.allSatisfy(\.isLetter) }
            .compactMap { languageName($0) }.first
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
