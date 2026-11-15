// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Testing
@testable import Rivulet

@MainActor
@Suite(.serialized)
struct CinemaHandoffTests {
    private func item(_ key: String, type: String) throws -> PlexMetadata {
        try JSONDecoder().decode(PlexMetadata.self, from: Data("""
        {"ratingKey":"\(key)","type":"\(type)","duration":100000,
         "Media":[{"id":1,"Part":[{"id":1,"key":"/library/parts/\(key)/video.mkv"}]}]}
        """.utf8))
    }

    @Test(arguments: [false, true])
    func failingSecondClipPreservesTheRemainingCinemaQueue(_ hasThirdClip: Bool) async throws {
        let defaults = UserDefaults.standard
        let keys = [CinemaExtras.countKey, StreamingQuality.homeKey, StreamingQuality.awayKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(3, forKey: CinemaExtras.countKey)
        defaults.set(StreamingQuality.original.rawValue, forKey: StreamingQuality.homeKey)
        defaults.set(StreamingQuality.original.rawValue, forKey: StreamingQuality.awayKey)

        let movie = try item("100", type: "movie")
        let clips = try (hasThirdClip ? ["22", "23", "24"] : ["22", "23"]).map { try item($0, type: "clip") }
        let reporter = PlexProgressReporter(countedPlay: { _, _, _ in false }, openSession: { _, _, _, _ in }, request: { _, _ in Data() })
        let vm = UniversalPlayerViewModel(metadata: movie, serverURL: "https://plex.invalid", authToken: "test",
                                          plexProgressReporter: reporter)
        defer { vm.stopPlayback() }
        vm.plexCinemaExtras = { _, _, _, _ in clips }
        vm.plexMetadataFetch = { _, _, key in clips.first { $0.ratingKey == key } ?? movie }
        vm.plexMetadataLookup = { _, _, key in clips.first { $0.ratingKey == key } ?? movie }
        vm.plexTranscodeStop = { _, _, _ in }
        vm.plexPlaybackRefresh = {}
        var loaded: [String] = []
        vm.playbackRouteStart = { vm, _, _ in
            let key = try #require(vm.metadata.ratingKey)
            loaded.append(key)
            if key == "23" { throw URLError(.cannotConnectToHost) }
            vm.updatePlaybackState(.playing)
        }

        await vm.startPlayback()
        #expect(loaded == ["22"])
        await vm.finishPlayback()
        if hasThirdClip {
            #expect(loaded == ["22", "23", "24"])
            #expect(vm.metadata.ratingKey == "24")
            await vm.finishPlayback()
        }
        #expect(loaded == (hasThirdClip ? ["22", "23", "24", "100"] : ["22", "23", "100"]))
        #expect(vm.metadata.ratingKey == "100")
        #expect(vm.isPlayingCinemaExtra == false)
        #expect(vm.playbackState == .playing)
    }
}
