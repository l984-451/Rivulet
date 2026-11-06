// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Values sent with a single native start, with watch subtitle defaults kept separate.
nonisolated struct SiloPlaybackPolicyApplication: Sendable {
    let quality: MediaQualityPreference
    let maxBitrate: Int?
    let audioLanguage: String?
    let subtitleLanguage: SiloResolvedPolicyValue<String>
    let subtitleMode: SiloResolvedPolicyValue<SiloLocalSubtitleMode>
    let showForcedSubtitles: SiloResolvedPolicyValue<Bool>
    let ignoreLearnedLimit: Bool

    init(policy: SiloResolvedPlaybackPolicy) throws {
        if case .value(let value) = policy.quality { quality = value } else { quality = .automatic }
        if case .value(let kbps) = policy.maxBitrateKbps {
            guard kbps > 0 else { throw MediaProviderError.backendSpecific(underlying: "Invalid Silo bitrate limit.") }
            let product = kbps.multipliedReportingOverflow(by: 1_000)
            guard !product.overflow else { throw MediaProviderError.backendSpecific(underlying: "Silo bitrate limit is too large.") }
            maxBitrate = product.partialValue
        } else { maxBitrate = nil }
        if case .value(let language) = policy.audioLanguage { audioLanguage = language } else { audioLanguage = nil }
        subtitleLanguage = policy.subtitleLanguage
        subtitleMode = policy.subtitleMode
        showForcedSubtitles = policy.showForcedSubtitles
        ignoreLearnedLimit = policy.bufferingPolicy == .value(.never)
    }

    func audioIndex(in version: SiloVersion) -> Int? {
        guard let audioLanguage, !audioLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let tracks = version.audioTracks ?? []
        return tracks.indices.filter { SiloInitialSubtitleSelection.languagesMatch(tracks[$0].language, audioLanguage) }
            .sorted { lhs, rhs in
                if tracks[lhs].default != tracks[rhs].default { return tracks[lhs].default }
                return lhs < rhs
            }.first
    }

    static func initialAudioIndex(in version: SiloVersion, policy: Self?, explicitIndex: Int?,
                                  prefersAudioDescription: Bool) -> Int? {
        if let explicitIndex { return explicitIndex }
        let preferred = policy?.audioIndex(in: version)
        guard prefersAudioDescription else { return preferred }
        let tracks = version.audioTracks ?? []
        let baseline = preferred ?? version.effectiveAudioTrackIndex
            ?? tracks.indices.first(where: { tracks[$0].default }) ?? tracks.indices.first
        guard let baseline, tracks.indices.contains(baseline),
              let language = tracks[baseline].language else { return preferred }
        func describesVideo(_ track: SiloAudioTrack) -> Bool {
            let text = [track.title, track.embeddedTitle].compactMap { $0?.lowercased() }.joined(separator: " ")
            return ["descri", "narration", "dvs", "impaired"].contains(where: text.contains)
        }
        if describesVideo(tracks[baseline]) { return preferred }
        return tracks.indices.first {
            describesVideo(tracks[$0]) && SiloInitialSubtitleSelection.languagesMatch(tracks[$0].language, language)
        } ?? preferred
    }
}
