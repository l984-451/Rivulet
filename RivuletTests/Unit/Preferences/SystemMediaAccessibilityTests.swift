// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

final class SystemMediaAccessibilityTests: XCTestCase {

    private let audio = [
        MediaTrack(id: 1, name: "English", languageCode: "eng", codec: "truehd", isDefault: true, channels: 8),
        MediaTrack(id: 2, name: "English", languageCode: "eng", codec: "ac3", isAudioDescription: true, channels: 2),
        MediaTrack(id: 3, name: "French", languageCode: "fra", codec: "ac3", channels: 6),
    ]

    func test_audioDescription_takesTheDescribedTrackInTheResolvedLanguage() {
        let english = AudioIntent(language: "eng")
        XCTAssertEqual(TrackIntentResolver.resolveAudio(intent: english, in: audio, prefersAudioDescription: false)?.id, 1)
        XCTAssertEqual(TrackIntentResolver.resolveAudio(intent: english, in: audio, prefersAudioDescription: true)?.id, 2)
        // No described French track: French stays.
        let french = AudioIntent(language: "fra")
        XCTAssertEqual(TrackIntentResolver.resolveAudio(intent: french, in: audio, prefersAudioDescription: true)?.id, 3)
    }

    func test_captionsAlwaysOn_overridesTheStoredIntent() {
        XCTAssertEqual(TrackIntentStore.effectiveSubtitleIntent(stored: .off, captionsAlwaysOn: false), .off)
        XCTAssertEqual(TrackIntentStore.effectiveSubtitleIntent(stored: .off, captionsAlwaysOn: true),
                       .track(language: TrackLanguage.device, forced: false, hearingImpaired: true, codec: nil))
        XCTAssertEqual(
            TrackIntentStore.effectiveSubtitleIntent(
                stored: .foreignAudio(language: "spa", hearingImpaired: false), captionsAlwaysOn: true),
            .track(language: "spa", forced: false, hearingImpaired: true, codec: nil))
    }

    func test_captionsAlwaysOn_prefersSDH() {
        let subtitles = [
            MediaTrack(id: 10, name: "English", languageCode: "eng", isForced: true),
            MediaTrack(id: 11, name: "English", languageCode: "eng"),
            MediaTrack(id: 12, name: "English", languageCode: "eng", isHearingImpaired: true),
        ]
        let intent = TrackIntentStore.effectiveSubtitleIntent(stored: .track(language: "eng", forced: false,
                                                                             hearingImpaired: false, codec: nil),
                                                              captionsAlwaysOn: true)
        XCTAssertEqual(TrackIntentResolver.resolveSubtitle(intent: intent, in: subtitles)?.id, 12)
    }
}
