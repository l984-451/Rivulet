// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
import MediaPlayer
@testable import Rivulet

final class NowPlayingLanguageOptionsTests: XCTestCase {

    private let audio = [
        MediaTrack(id: 1, name: "English", language: "English", languageCode: "eng", codec: "truehd",
                   isDefault: true, channels: 8),
        MediaTrack(id: 2, name: "English", language: "English", languageCode: "eng", codec: "ac3",
                   isCommentary: true, title: "Commentary", channels: 2),
        MediaTrack(id: 3, name: "French", language: "French", languageCode: "fra", codec: "ac3", channels: 6),
    ]
    private let subtitles = [
        MediaTrack(id: 10, name: "English", language: "English", languageCode: "eng", isForced: true),
        MediaTrack(id: 11, name: "English", language: "English", languageCode: "eng", isHearingImpaired: true),
        MediaTrack(id: 12, name: "Track 12"),
    ]

    func test_groups() {
        let groups = NowPlayingLanguageOptions.groups(audio: audio, subtitles: subtitles)
        XCTAssertEqual(groups.count, 2)
        XCTAssertFalse(groups[0].allowEmptySelection)
        XCTAssertEqual(groups[0].defaultLanguageOption?.identifier, "1")
        XCTAssertEqual(groups[0].languageOptions.map(\.languageOptionType), [.audible, .audible, .audible])
        XCTAssertTrue(groups[1].allowEmptySelection)
        XCTAssertEqual(groups[1].languageOptions.map(\.identifier), ["10", "11", "12"])
        XCTAssertTrue(NowPlayingLanguageOptions.groups(audio: [], subtitles: []).isEmpty)
    }

    func test_optionFields() {
        let main = NowPlayingLanguageOptions.option(audio[0], type: .audible, among: audio)
        XCTAssertEqual(main.languageTag, "en")
        XCTAssertEqual(main.languageOptionCharacteristics, [MPLanguageOptionCharacteristicIsMainProgramContent])
        XCTAssertTrue(main.displayName?.hasPrefix("English (") ?? false)

        let commentary = NowPlayingLanguageOptions.option(audio[1], type: .audible, among: audio)
        XCTAssertEqual(commentary.languageOptionCharacteristics, [MPLanguageOptionCharacteristicIsAuxiliaryContent])

        let forced = NowPlayingLanguageOptions.option(subtitles[0], type: .legible, among: subtitles)
        XCTAssertEqual(forced.languageOptionCharacteristics, [MPLanguageOptionCharacteristicContainsOnlyForcedSubtitles])
        let sdh = NowPlayingLanguageOptions.option(subtitles[1], type: .legible, among: subtitles)
        XCTAssertEqual(sdh.languageOptionCharacteristics, [MPLanguageOptionCharacteristicTranscribesSpokenDialog,
                                             MPLanguageOptionCharacteristicDescribesMusicAndSound])
        XCTAssertEqual(NowPlayingLanguageOptions.option(subtitles[2], type: .legible, among: subtitles).languageTag, "und")
    }

    func test_current_omitsSubtitlesWhenOff() {
        let on = NowPlayingLanguageOptions.current(audio: audio, subtitles: subtitles, audioId: 3, subtitleId: 11)
        XCTAssertEqual(on.map(\.identifier), ["3", "11"])
        let off = NowPlayingLanguageOptions.current(audio: audio, subtitles: subtitles, audioId: 3, subtitleId: nil)
        XCTAssertEqual(off.map(\.identifier), ["3"])
    }

    func test_trackId_byIdentifierThenLanguage() {
        let picked = MPNowPlayingInfoLanguageOption(type: .legible, languageTag: "en", characteristics: nil,
                                                    displayName: "", identifier: "11")
        XCTAssertEqual(NowPlayingLanguageOptions.trackId(for: picked, in: subtitles), 11)
        // No usable identifier: the first full track in that language, skipping forced.
        let byTag = MPNowPlayingInfoLanguageOption(type: .legible, languageTag: "en", characteristics: nil,
                                                   displayName: "", identifier: "")
        XCTAssertEqual(NowPlayingLanguageOptions.trackId(for: byTag, in: subtitles), 11)
        let stale = MPNowPlayingInfoLanguageOption(type: .audible, languageTag: "de", characteristics: nil,
                                                   displayName: "", identifier: "99")
        XCTAssertNil(NowPlayingLanguageOptions.trackId(for: stale, in: audio))
    }
}
