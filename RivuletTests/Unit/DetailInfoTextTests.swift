// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import XCTest
@testable import Rivulet

/// The detail pages' rating and Audio line (`ContentRatingDisplay`, `AudioLanguageSummary`).
final class DetailInfoTextTests: XCTestCase {

    private func track(_ codec: String, _ channels: Int, _ language: String?, profile: String? = nil) -> AudioTrack {
        AudioTrack(
            id: UUID().uuidString, index: 0, codec: codec, profile: profile,
            channels: channels, channelLayout: nil,
            language: language, title: nil, extendedTitle: nil,
            bitrate: nil, samplingRate: nil,
            isDefault: false, isForced: false, isSelected: false
        )
    }

    private let names = ["de": "Deutsch", "en": "Englisch"]

    // MARK: - Rating

    func test_unratedWordsShowNothing() {
        for raw in ["NR", "nr", "Not Rated", "Unrated", " NR ", "", nil] {
            XCTAssertNil(ContentRatingDisplay.shown(raw), "\(String(describing: raw))")
        }
    }

    func test_realRatingIsKept() {
        XCTAssertEqual(ContentRatingDisplay.shown("FSK-16"), "FSK-16")
        XCTAssertEqual(ContentRatingDisplay.shown("PG-13"), "PG-13")
    }

    // MARK: - Audio line

    func test_eachLanguageOnceWithItsFormats() {
        let tracks = [
            track("eac3", 8, "de"), track("ac3", 6, "de"),
            track("truehd", 8, "en", profile: "Atmos"), track("ac3", 6, "en"),
        ]
        XCTAssertEqual(
            AudioLanguageSummary.text(tracks, name: { self.names[$0] }),
            "Deutsch (E-AC3 7.1, AC3 5.1), Englisch (TrueHD 7.1 Atmos, AC3 5.1)"
        )
    }

    func test_sameFormatTwiceIsListedOnce() {
        let tracks = [track("ac3", 6, "de"), track("ac3", 6, "de")]
        XCTAssertEqual(AudioLanguageSummary.text(tracks, name: { self.names[$0] }), "Deutsch (AC3 5.1)")
    }

    func test_unknownCodecNamesTheLanguageAlone() {
        XCTAssertEqual(AudioLanguageSummary.text([track("unknown", 2, "en")], name: { self.names[$0] }), "Englisch")
    }

    func test_tracksWithoutLanguageAreLeftOut() {
        XCTAssertNil(AudioLanguageSummary.text([track("aac", 2, nil)], name: { self.names[$0] }))
    }
}
