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

    /// MediaRemote's options key for a language command sent from another device
    /// (the TV Remote app, Home Assistant, Unfolded Circle remotes). tvOS leaves
    /// `MPChangeLanguageOptionCommandEvent.languageOption` nil for these and only
    /// passes the option on as protobuf bytes under this key.
    static let mediaRemoteOptionDataKey = "kMRMediaRemoteOptionLanguageOptionData"

    /// The option in MediaRemote's `LanguageOption` protobuf: type = 1, languageTag = 2,
    /// characteristics = 3, displayName = 4, identifier = 5. Nil without an identifier.
    static func option(protobuf data: Data) -> MPNowPlayingInfoLanguageOption? {
        let bytes = [UInt8](data)
        var index = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0, shift: UInt64 = 0
            while index < bytes.count, shift < 64 {
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
            }
            return nil
        }
        var type: UInt = 0
        var strings: [UInt64: String] = [:]
        var characteristics: [String] = []
        while index < bytes.count {
            guard let key = varint() else { return nil }
            switch key & 7 {
            case 0:
                guard let value = varint() else { return nil }
                if key >> 3 == 1 { type = UInt(value) }
            case 2:
                guard let length = varint().map(Int.init), length <= bytes.count - index else { return nil }
                let string = String(decoding: bytes[index..<index + length], as: UTF8.self)
                index += length
                if key >> 3 == 3 { characteristics.append(string) } else { strings[key >> 3] = string }
            case 1: index += 8
            case 5: index += 4
            default: return nil
            }
        }
        guard let identifier = strings[5], let optionType = MPNowPlayingInfoLanguageOptionType(rawValue: type)
        else { return nil }
        return MPNowPlayingInfoLanguageOption(
            type: optionType, languageTag: strings[2] ?? "und", characteristics: characteristics,
            displayName: strings[4] ?? identifier, identifier: identifier)
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
