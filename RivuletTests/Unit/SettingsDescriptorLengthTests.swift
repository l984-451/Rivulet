// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsDescriptorLengthTests.swift
//  RivuletTests
//
//  Every Settings explainer fits the panel's line limit, in every language.
//

import XCTest
@testable import Rivulet

@MainActor
final class SettingsDescriptorLengthTests: XCTestCase {
    /// Greek translations that still run over, waiting on their translator.
    private static let knownOverflow: Set<String> = [
        "el autoSkipAds", "el generatedSubtitles", "el instantResume", "el plexServerEnabled"
    ]

    /// Lines the panel's label needs for `text` at full width.
    private func lines(_ text: String) -> Int {
        let label = UILabel()
        label.font = SettingsLeftPanelView.descriptionFont
        label.numberOfLines = 0
        label.text = text
        let height = label.sizeThatFits(CGSize(width: SettingsLeftPanelView.width, height: .greatestFiniteMagnitude)).height
        return Int((height / label.font.lineHeight).rounded())
    }

    /// The `lang` text for an English description, including ones built around a server name.
    private func translation(of english: String, in bundle: Bundle) -> String? {
        let miss = "\u{0}"
        let direct = bundle.localizedString(forKey: english, value: miss, table: nil)
        if direct != miss { return direct }
        let name = MediaProviderKind.emby.displayName
        guard english.contains(name) else { return nil }
        let format = bundle.localizedString(forKey: english.replacingOccurrences(of: name, with: "%@"), value: miss, table: nil)
        return format == miss ? nil : String(format: format, name)
    }

    func test_everyDescriptionFitsThePanel() throws {
        let limit = SettingsLeftPanelView.descriptionLines
        let languages = Bundle.main.localizations.filter { $0 != "Base" && $0 != "en" }
        for (id, descriptor) in SettingsDescriptorStore.descriptors {
            XCTAssertLessThanOrEqual(lines(descriptor.description), limit, "en \(id)")
            for lang in languages {
                guard let path = Bundle.main.path(forResource: lang, ofType: "lproj"),
                      let bundle = Bundle(path: path),
                      let text = translation(of: descriptor.description, in: bundle),
                      !Self.knownOverflow.contains("\(lang) \(id)") else { continue }
                XCTAssertLessThanOrEqual(lines(text), limit, "\(lang) \(id): \(text)")
            }
        }
    }
}
