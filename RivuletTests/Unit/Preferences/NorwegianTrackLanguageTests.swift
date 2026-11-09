// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Testing
@testable import Rivulet

@MainActor
struct NorwegianTrackLanguageTests {
    @Test(arguments: ["no", "nor", "nb", "nob", "Norwegian", "Norwegian Bokmål"])
    func bokmalFoldsIntoNorwegian(language: String) {
        #expect(TrackLanguage.normalize(language) == "nor")
        #expect(TrackLanguage.choices.contains(TrackLanguage.normalize(language)))
    }

    @Test(arguments: ["nb-NO", "nb", "no-NO", "no"])
    func systemLanguageSelectsNorwegian(language: String) {
        #expect(TrackLanguage.language(fromPreferred: [language, "en"]) == "nor")
    }

    @Test(arguments: ["no", "nor", "nb", "nob"], ["no", "nor", "nb", "nob"])
    func resolvesCompatibleTracks(preference: String, language: String) {
        let tracks = [track(1, "eng"), track(2, language)]
        let intent = SubtitleIntent.track(language: preference, forced: false, hearingImpaired: false, codec: nil)
        #expect(TrackIntentResolver.resolveSubtitle(intent: intent, in: tracks)?.id == 2)
        #expect(TrackIntentResolver.resolveAudio(intent: AudioIntent(language: preference), in: tracks,
                                                 prefersAudioDescription: false)?.id == 2)
        #expect(TrackLanguage.isForeign(language, to: preference) == false)
        #expect(CaptionsOnMuteLogic.track(in: tracks, preferredLanguage: preference, audioLanguage: "eng")?.id == 2)
    }

    @Test(arguments: ["nn", "nno"])
    func nynorskRemainsDistinct(language: String) {
        #expect(TrackLanguage.matches(language, "nor") == false)
        #expect(TrackLanguage.matches(language, "nb") == false)
    }

    @Test func subtitleSearchAsksForNorwegian() {
        #expect(SubtitleSearchLanguage.alpha2(preferred: "nob", device: "eng") == "no")
        #expect(SubtitleSearchLanguage.alpha2(preferred: nil, device: TrackLanguage.language(fromPreferred: ["nb-NO"])) == "no")
    }

    private func track(_ id: Int, _ language: String) -> MediaTrack {
        MediaTrack(id: id, name: "Track \(id)", languageCode: language, codec: "srt")
    }
}
