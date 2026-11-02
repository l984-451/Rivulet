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
            let options = audio.map { option($0, type: .audible, among: audio) }
            let main = audio.firstIndex(where: \.isDefault) ?? 0
            groups.append(MPNowPlayingInfoLanguageOptionGroup(
                languageOptions: options, defaultLanguageOption: options[main], allowEmptySelection: false))
        }
        if !subtitles.isEmpty {
            groups.append(MPNowPlayingInfoLanguageOptionGroup(
                languageOptions: subtitles.map { option($0, type: .legible, among: subtitles) },
                defaultLanguageOption: nil, allowEmptySelection: true))
        }
        return groups
    }

    /// The selected audio track and, unless subtitles are off, the selected subtitle track.
    static func current(audio: [MediaTrack], subtitles: [MediaTrack],
                        audioId: Int?, subtitleId: Int?) -> [MPNowPlayingInfoLanguageOption] {
        [audio.first { $0.id == audioId }.map { option($0, type: .audible, among: audio) },
         subtitles.first { $0.id == subtitleId }.map { option($0, type: .legible, among: subtitles) }]
            .compactMap { $0 }
    }

    static func option(_ track: MediaTrack, type: MPNowPlayingInfoLanguageOptionType,
                       among tracks: [MediaTrack]) -> MPNowPlayingInfoLanguageOption {
        let title = type == .audible ? track.audioMenuTitle : track.subtitleMenuTitle
        let detail = type == .audible ? track.audioMenuSubtitle(among: tracks) : track.subtitleMenuSubtitle
        return MPNowPlayingInfoLanguageOption(
            type: type,
            languageTag: languageTag(track),
            characteristics: characteristics(track, type: type),
            displayName: detail.isEmpty ? title : "\(title) (\(detail))",
            identifier: String(track.id))
    }

    /// The track a remote picked: by identifier, else the first full track in the option's language.
    static func trackId(for option: MPNowPlayingInfoLanguageOption, in tracks: [MediaTrack]) -> Int? {
        if let id = option.identifier.flatMap(Int.init), tracks.contains(where: { $0.id == id }) { return id }
        guard let tag = option.languageTag else { return nil }
        let matching = tracks.filter { languageTag($0) == tag }
        return (matching.first { !$0.isForced } ?? matching.first)?.id
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
