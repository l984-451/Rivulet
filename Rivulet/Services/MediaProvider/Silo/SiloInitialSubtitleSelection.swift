// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Resolves the server's effective preference against the current plan, whose
/// track IDs and combined indices are the only valid replan authority.
nonisolated enum SiloInitialSubtitleSelection: Sendable, Equatable {
    case leavePlan
    case off
    case track(SiloTrackIdentity)

    static func resolve(watch: SiloItem, version: SiloVersion, plan: SiloPlaybackPlan,
                        explicitIndex: Int?, policy: SiloPlaybackPolicyApplication? = nil) throws -> Self {
        if let explicitIndex {
            if explicitIndex < 0 { return .off }
            guard let track = plan.subtitle.inventory.first(where: { $0.combinedIndex == explicitIndex }) else {
                throw MediaProviderError.backendSpecific(underlying: "The selected subtitle is absent from Silo's plan inventory.")
            }
            return .track(SiloTrackIdentity(id: track.trackId, index: track.combinedIndex))
        }

        let tracks = plan.subtitle.inventory.filter { isPlayable($0, in: plan) }
        let mode: String
        switch policy?.subtitleMode {
        case .some(.value(let value)): mode = value.rawValue
        case .some(.clear): mode = "auto"
        case .some(.unavailable), .none: mode = watch.effectiveSubtitleMode?.lowercased() ?? "auto"
        }
        let language: String?
        switch policy?.subtitleLanguage {
        case .some(.value(let value)): language = value.trimmingCharacters(in: .whitespacesAndNewlines)
        case .some(.clear): language = nil
        case .some(.unavailable), .none: language = watch.effectiveSubtitleLanguage?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let audioIndex = plan.selectedTracks.audio?.index ?? version.effectiveAudioTrackIndex
        let audioLanguage = audioIndex.flatMap { (version.audioTracks ?? []).indices.contains($0)
            ? version.audioTracks?[$0].language : nil }
        let showForced: Bool
        switch policy?.showForcedSubtitles {
        case .some(.value(let value)): showForced = value
        case .some(.clear): showForced = false
        case .some(.unavailable), .none: showForced = watch.effectiveShowForcedSubtitles ?? false
        }

        if mode == "off" {
            if showForced, let audioLanguage,
               let forced = best(in: tracks.filter(\.forced), language: audioLanguage, allowFallback: false) {
                return choice(forced)
            }
            return .off
        }
        let localLanguageConflicts: Bool
        if case .some(.value(let selectedLanguage)) = policy?.subtitleLanguage,
           let savedLanguage = watch.effectiveSubtitleTrackSignature?.language {
            localLanguageConflicts = !languagesMatch(selectedLanguage, savedLanguage)
        } else { localLanguageConflicts = false }
        let localModeConflicts: Bool
        if case .some(.value(let selectedMode)) = policy?.subtitleMode {
            localModeConflicts = selectedMode != .always
        } else { localModeConflicts = false }
        let localChoiceConflicts = localLanguageConflicts || localModeConflicts
        if !localChoiceConflicts, let signature = watch.effectiveSubtitleTrackSignature,
           let saved = signatureMatch(signature, in: tracks) { return choice(saved) }
        if language == "" { return .off }
        if mode == "auto", let language, let audioLanguage, languagesMatch(language, audioLanguage) {
            if showForced,
               let forced = best(in: tracks.filter(\.forced), language: audioLanguage, allowFallback: false) {
                return choice(forced)
            }
            return .off
        }
        if let language, let matching = best(in: tracks.filter { !$0.forced }, language: language,
                                              allowFallback: false) { return choice(matching) }
        if mode == "always" {
            if let language, !language.isEmpty { return .leavePlan }
            if let first = best(in: tracks.filter { !$0.forced }, language: nil, allowFallback: true) {
                return choice(first)
            }
        }
        if showForced, let forced = tracks.first(where: \.forced) { return choice(forced) }
        return .leavePlan
    }

    var selectedTrack: SiloTrackIdentity? {
        if case .track(let track) = self { return track }
        return nil
    }

    func differs(from plan: SiloPlaybackPlan) -> Bool {
        switch self {
        case .leavePlan: false
        case .off: plan.selectedTracks.subtitle != nil || plan.subtitle.mode != "off"
        case .track(let track): plan.selectedTracks.subtitle?.id != track.id
            || plan.selectedTracks.subtitle?.index != track.index || plan.subtitle.mode == "off"
        }
    }

    private static func choice(_ track: SiloPlanSubtitleTrack) -> Self {
        .track(SiloTrackIdentity(id: track.trackId, index: track.combinedIndex))
    }

    private static func isPlayable(_ track: SiloPlanSubtitleTrack, in plan: SiloPlaybackPlan) -> Bool {
        if track.source == "embedded", plan.delivery == "original_http", track.delivery != "burn_in_only" { return true }
        if track.delivery == "sidecar" { return track.url?.isEmpty == false }
        return false
    }

    private static func best(in tracks: [SiloPlanSubtitleTrack], language: String?,
                             allowFallback: Bool) -> SiloPlanSubtitleTrack? {
        let matches = language.map { wanted in tracks.filter { languagesMatch($0.language, wanted) } } ?? tracks
        guard !matches.isEmpty || allowFallback else { return nil }
        return (matches.isEmpty ? tracks : matches).sorted { lhs, rhs in
            if lhs.default != rhs.default { return lhs.default }
            if lhs.hearingImpaired != rhs.hearingImpaired { return !lhs.hearingImpaired }
            if lhs.forced != rhs.forced { return !lhs.forced }
            return lhs.combinedIndex < rhs.combinedIndex
        }.first
    }

    private static func signatureMatch(_ signature: SiloSubtitleSignature,
                                       in tracks: [SiloPlanSubtitleTrack]) -> SiloPlanSubtitleTrack? {
        let language = signature.language?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = signature.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard language?.isEmpty == false || label?.isEmpty == false else { return nil }
        return tracks.compactMap { track -> (SiloPlanSubtitleTrack, Int)? in
            if let language, !language.isEmpty, let actual = track.language,
               !languagesMatch(actual, language) { return nil }
            var score = 0
            var strong = false
            if let language, languagesMatch(track.language, language) { score += 5; strong = true }
            if let label, !label.isEmpty, track.label?.localizedCaseInsensitiveContains(label) == true {
                score += 2; strong = true
            }
            guard strong else { return nil }
            if signature.forced == track.forced { score += 1 }
            if signature.hearingImpaired == track.hearingImpaired { score += 1 }
            if signature.source == track.source { score += 1 }
            if signature.codec?.caseInsensitiveCompare(track.codec ?? "") == .orderedSame { score += 1 }
            return (track, score)
        }.max { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0.combinedIndex > rhs.0.combinedIndex : lhs.1 < rhs.1
        }?.0
    }

    static func languagesMatch(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, !lhs.isEmpty, !rhs.isEmpty else { return false }
        func primary(_ value: String) -> String {
            let key = value.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map(String.init) ?? ""
            return ["eng": "en", "fra": "fr", "fre": "fr", "deu": "de", "ger": "de",
                    "spa": "es", "ita": "it", "nld": "nl", "dut": "nl", "por": "pt"].first { $0.key == key }?.value ?? key
        }
        return primary(lhs) == primary(rhs)
    }
}
