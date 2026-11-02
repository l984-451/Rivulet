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
        let main = NowPlayingLanguageOptions.option(audio[0], type: .audible)
        XCTAssertEqual(main.languageTag, "en")
        XCTAssertEqual(main.languageOptionCharacteristics, [MPLanguageOptionCharacteristicIsMainProgramContent])
        XCTAssertTrue(main.displayName?.hasPrefix("English (") ?? false)

        let commentary = NowPlayingLanguageOptions.option(audio[1], type: .audible)
        XCTAssertEqual(commentary.languageOptionCharacteristics, [MPLanguageOptionCharacteristicIsAuxiliaryContent])

        let forced = NowPlayingLanguageOptions.option(subtitles[0], type: .legible)
        XCTAssertEqual(forced.languageOptionCharacteristics, [MPLanguageOptionCharacteristicContainsOnlyForcedSubtitles])
        let sdh = NowPlayingLanguageOptions.option(subtitles[1], type: .legible)
        XCTAssertEqual(sdh.languageOptionCharacteristics, [MPLanguageOptionCharacteristicTranscribesSpokenDialog,
                                             MPLanguageOptionCharacteristicDescribesMusicAndSound])
        XCTAssertEqual(NowPlayingLanguageOptions.option(subtitles[2], type: .legible).languageTag, "und")
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
    func test_siloOriginalAudioRolesKeepProviderSelectionIDs() {
        let provider = [
            MediaTrack(id: -10_000_001, name: "English", languageCode: "eng", codec: "ac3", streamIndex: 0),
            MediaTrack(id: -10_000_002, name: "English", languageCode: "eng", codec: "ac3", streamIndex: 1),
        ]
        let engine = [
            MediaTrack(id: 2, name: "English", streamIndex: 2),
            MediaTrack(id: 4, name: "English", isAudioDescription: true, streamIndex: 4),
        ]
        let projected = UniversalPlayerViewModel.projectNativeAudioRoles(provider: provider, engine: engine)
        XCTAssertEqual(projected.map(\.id), provider.map(\.id))
        XCTAssertFalse(projected[0].describesVideo)
        XCTAssertTrue(projected[1].describesVideo)
        let option = NowPlayingLanguageOptions.option(projected[1], type: .audible)
        XCTAssertEqual(option.identifier, "-10000002")
        XCTAssertEqual(option.languageOptionCharacteristics, [MPLanguageOptionCharacteristicDescribesVideo])
        XCTAssertTrue(option.displayName?.contains("Audio Description") == true)
        XCTAssertEqual(NowPlayingLanguageOptions.selection(for: option, enable: true, audio: projected, subtitles: []),
                       .audio(-10_000_002))
        XCTAssertEqual(UniversalPlayerViewModel.projectNativeAudioRoles(provider: provider, engine: [engine[1]]), provider)
    }

    func test_remoteSiloSelectionAndOffUseShimIDs() {
        let tracks = [
            MediaTrack(id: -10_000_003, name: "English", languageCode: "eng"),
            MediaTrack(id: -10_000_004, name: "English", languageCode: "eng"),
        ]
        let chosen = NowPlayingLanguageOptions.option(tracks[1], type: .legible)
        XCTAssertEqual(NowPlayingLanguageOptions.selection(for: chosen, enable: true, audio: [], subtitles: tracks),
                       .subtitle(-10_000_004))
        XCTAssertEqual(NowPlayingLanguageOptions.selection(for: chosen, enable: false, audio: [], subtitles: tracks),
                       .subtitle(nil))
        let stale = MPNowPlayingInfoLanguageOption(type: .legible, languageTag: "en", characteristics: nil,
                                                  displayName: "", identifier: "-10000009")
        XCTAssertNil(NowPlayingLanguageOptions.selection(for: stale, enable: true, audio: [], subtitles: tracks))
        let noID = MPNowPlayingInfoLanguageOption(type: .legible, languageTag: "en", characteristics: nil,
                                                 displayName: "", identifier: "")
        XCTAssertEqual(NowPlayingLanguageOptions.selection(for: noID, enable: true, audio: [], subtitles: tracks),
                       .subtitle(-10_000_003))
        let audible = NowPlayingLanguageOptions.option(tracks[0], type: .audible)
        XCTAssertNil(NowPlayingLanguageOptions.selection(for: audible, enable: false, audio: tracks, subtitles: []))
    }
}
