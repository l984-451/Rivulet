// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley
//
//  NowPlayingLanguageOptions.swift
//  Rivulet
//
//  A title's audio and subtitle tracks as Now Playing language options, which
//  the system's remotes (Control Center, the TV Remote app, any MediaRemote
//  client) list and pick from. Each option's identifier is the track id.
//

import Foundation
import MediaPlayer

enum NowPlayingLanguageOptions {

    /// One group per kind that has tracks. Subtitles allow an empty selection (Off).
    static func groups(audio: [MediaTrack], subtitles: [MediaTrack]) -> [MPNowPlayingInfoLanguageOptionGroup] {
        var groups: [MPNowPlayingInfoLanguageOptionGroup] = []
        if !audio.isEmpty {
            let options = audio.map { option($0, type: .audible) }
            let main = audio.firstIndex(where: \.isDefault) ?? 0
            groups.append(MPNowPlayingInfoLanguageOptionGroup(
                languageOptions: options, defaultLanguageOption: options[main], allowEmptySelection: false))
        }
        if !subtitles.isEmpty {
            groups.append(MPNowPlayingInfoLanguageOptionGroup(
                languageOptions: subtitles.map { option($0, type: .legible) },
                defaultLanguageOption: nil, allowEmptySelection: true))
        }
        return groups
    }

    /// The selected audio track and, unless subtitles are off, the selected subtitle track.
    static func current(audio: [MediaTrack], subtitles: [MediaTrack],
                        audioId: Int?, subtitleId: Int?) -> [MPNowPlayingInfoLanguageOption] {
        [audio.first { $0.id == audioId }.map { option($0, type: .audible) },
         subtitles.first { $0.id == subtitleId }.map { option($0, type: .legible) }]
            .compactMap { $0 }
    }

    static func option(_ track: MediaTrack, type: MPNowPlayingInfoLanguageOptionType) -> MPNowPlayingInfoLanguageOption {
        let title = type == .audible ? track.audioMenuTitle : track.subtitleMenuTitle
        let detail = type == .audible ? track.audioMenuSubtitle : track.subtitleMenuSubtitle
        return MPNowPlayingInfoLanguageOption(
            type: type,
            languageTag: languageTag(track),
            characteristics: characteristics(track, type: type),
            displayName: detail.isEmpty ? title : "\(title) (\(detail))",
            identifier: String(track.id))
    }

    /// Resolve published identifiers exactly; unrecognizable identifiers may
    /// fall back to language, but a stale numeric ID must not select another track.
    static func trackId(for option: MPNowPlayingInfoLanguageOption, in tracks: [MediaTrack]) -> Int? {
        if let id = option.identifier.flatMap(Int.init) {
            return tracks.contains(where: { $0.id == id }) ? id : nil
        }
        guard let tag = option.languageTag else { return nil }
        let matching = tracks.filter { languageTag($0) == tag }
        return (matching.first { !$0.isForced } ?? matching.first)?.id
    }

    enum Selection: Equatable {
        case audio(Int)
        case subtitle(Int?)
    }

    static func selection(for option: MPNowPlayingInfoLanguageOption, enable: Bool,
                          audio: [MediaTrack], subtitles: [MediaTrack]) -> Selection? {
        switch option.languageOptionType {
        case .audible:
            guard enable, let id = trackId(for: option, in: audio) else { return nil }
            return .audio(id)
        case .legible:
            guard enable else { return .subtitle(nil) }
            guard let id = trackId(for: option, in: subtitles) else { return nil }
            return .subtitle(id)
        @unknown default:
            return nil
        }
    }

    /// BCP 47 for the option: "en" from "eng" or "English", "und" when unknown.
    static func languageTag(_ track: MediaTrack) -> String {
        let code = track.languageCode ?? track.language
        guard TrackLanguage.isKnown(code) else { return "und" }
        let key = TrackLanguage.normalize(code)
        return Locale.LanguageCode(key).identifier(.alpha2) ?? key
    }

    private static func characteristics(_ track: MediaTrack, type: MPNowPlayingInfoLanguageOptionType) -> [String] {
        if type == .legible {
            var traits: [String] = []
            if track.isForced { traits.append(MPLanguageOptionCharacteristicContainsOnlyForcedSubtitles) }
            if track.isHearingImpaired {
                traits += [MPLanguageOptionCharacteristicTranscribesSpokenDialog,
                           MPLanguageOptionCharacteristicDescribesMusicAndSound]
            }
            return traits
        }
        if track.describesVideo { return [MPLanguageOptionCharacteristicDescribesVideo] }
        return [track.audioRole == nil ? MPLanguageOptionCharacteristicIsMainProgramContent
                                       : MPLanguageOptionCharacteristicIsAuxiliaryContent]
    }
}
