// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

/// The detail pages' Audio line (`AudioLanguageSummary`).
final class AudioLanguageSummaryTests: XCTestCase {

    private func track(_ codec: String, _ channels: Int, _ language: String?,
                       profile: String? = nil, title: String? = nil) -> AudioTrack {
        AudioTrack(
            id: UUID().uuidString, index: 0, codec: codec, profile: profile,
            channels: channels, channelLayout: nil,
            language: language, title: title, extendedTitle: nil,
            bitrate: nil, samplingRate: nil,
            isDefault: false, isForced: false, isSelected: false
        )
    }

    private let names = ["de": "Deutsch", "en": "Englisch"]
    private func text(_ tracks: [AudioTrack]) -> String? { AudioLanguageSummary.text(tracks, name: { self.names[$0] }) }

    func test_eachLanguageOnceWithItsFormats() {
        let tracks = [
            track("eac3", 8, "de"), track("ac3", 6, "de"),
            track("truehd", 8, "en", profile: "Atmos"), track("ac3", 6, "en"),
        ]
        XCTAssertEqual(text(tracks), "Deutsch (E-AC3 7.1, AC3 5.1), Englisch (TrueHD 7.1 Atmos, AC3 5.1)")
    }

    func test_sameFormatTwiceIsListedOnce() {
        XCTAssertEqual(text([track("ac3", 6, "de"), track("ac3", 6, "de")]), "Deutsch (AC3 5.1)")
    }

    func test_audioDescriptionIsMarkedAD() {
        let tracks = [track("eac3", 6, "en"), track("aac", 2, "en", title: "English Audio Description")]
        XCTAssertEqual(text(tracks), "Englisch (E-AC3 5.1, AAC 2.0, AD)")
    }

    func test_unknownCodecNamesTheLanguageAlone() {
        XCTAssertEqual(text([track("unknown", 2, "en")]), "Englisch")
    }

    func test_tracksWithoutLanguageAreLeftOut() {
        XCTAssertNil(text([track("aac", 2, nil)]))
    }
}
