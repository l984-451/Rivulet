// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  VersionPicker.swift
//  Rivulet
//
//  Which versions an item offers and how each is labelled. The tvOS popup and
//  the iOS menu share this.
//

import Foundation

enum VersionPicker {
    /// The item's versions, best first, or empty when it has only one.
    static func versions(in detail: MediaItemDetail) -> [MediaSource] {
        let ranked = VersionRanking.ordered(detail.mediaSources)
        return ranked.count >= 2 ? ranked : []
    }

    /// One row label per version, same order. Identical labels get the file name.
    static func labels(for sources: [MediaSource]) -> [String] {
        let base = sources.map(rowLabel)
        return zip(sources, base).map { source, label in
            guard base.filter({ $0 == label }).count > 1, let stem = fileStem(source.fileName) else { return label }
            return String(localized: "\(label) · \(stem)")
        }
    }

    /// A row of the picker: one file, on this item or on another copy of it.
    struct Option {
        let source: MediaSource
        /// nil: the item on screen. Otherwise the other copy this file belongs to.
        let copy: MediaItem?
        /// Where the file is; set only when the list spans more than one copy.
        let server: String?
    }

    /// Another copy of the item on screen (another server, or another library on the same one), with its files.
    struct Copy {
        let item: MediaItem
        let server: String
        let sources: [MediaSource]
        var library: String? = nil
    }

    /// This item's files plus every other copy, best first (ties keep this item first), or empty
    /// when there is only one file in all. Rows name their server once copies exist, and their
    /// library too when a server repeats; the shown copy's rows read "This Copy" when its server is unknown.
    static func options(current: [MediaSource], currentServer: String?, currentLibrary: String? = nil,
                        copies: [Copy]) -> [Option] {
        let servers = [currentServer] + copies.map { Optional($0.server) }
        let repeats = Set(servers.compactMap { $0 }).count < servers.count
        func name(_ server: String?, _ library: String?) -> String? {
            guard !copies.isEmpty else { return nil }
            let server = server ?? String(localized: "This Copy")
            guard repeats, let library else { return server }
            return "\(server) · \(library)"
        }
        var all = VersionRanking.ordered(current).map {
            Option(source: $0, copy: nil, server: name(currentServer, currentLibrary))
        }
        for copy in copies {
            all += VersionRanking.ordered(copy.sources).map {
                Option(source: $0, copy: copy.item, server: name(copy.server, copy.library))
            }
        }
        guard all.count >= 2 else { return [] }
        return VersionRanking.rankedIndices(all.map { VersionRanking.key($0.source) }).map { all[$0] }
    }

    /// What picking an option plays: a file of the item on screen, or a file of another item.
    enum Pick {
        case version(String)
        case item(MediaItem, String)
    }

    /// A copy's file plays that copy, from `shown`'s resume point when that is further in: progress
    /// lives on the shown item's server, and the copy's own is usually 0. With `playTarget` (a show's
    /// Play episode) every other file plays that episode; otherwise the file is a version of the item on screen.
    static func pick(_ option: Option, playTarget: MediaItem?, shown: MediaItem? = nil) -> Pick {
        if var copy = option.copy {
            if let shown, shown.userState.viewOffset > copy.userState.viewOffset {
                let state = copy.userState
                copy.userState = MediaUserState(isPlayed: state.isPlayed, viewOffset: shown.userState.viewOffset,
                                                isFavorite: state.isFavorite, lastViewedAt: state.lastViewedAt)
            }
            return .item(copy, option.source.id)
        }
        if let playTarget { return .item(playTarget, option.source.id) }
        return .version(option.source.id)
    }

    /// One row label per option, same order. With copies, a row is the resolution and range, then
    /// where it is (the full file label does not fit beside it); rows that would read the same
    /// keep the full file label. Without copies, the full file label.
    static func labels(for options: [Option]) -> [String] {
        let full = labels(for: options.map(\.source))
        guard options.contains(where: { $0.server != nil }) else { return full }
        let short = options.map { option in
            let name = option.source.versionName.flatMap { isResolutionName($0) ? nil : $0 }
            return ([name, option.source.resolutionBadge, option.source.rangeBadge] + [option.server])
                .compactMap { $0 }
                .joined(separator: " · ")
        }
        return zip(options, zip(short, full)).map { option, labels in
            guard short.filter({ $0 == labels.0 }).count > 1 else { return labels.0 }
            return option.server.map { "\(labels.1) · \($0)" } ?? labels.1
        }
    }

    /// Jellyfin treats a name ending in p or i after digits as a resolution; "4K" too.
    static func isResolutionName(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard let last = lower.last, "pik".contains(last) else { return false }
        let digits = lower.dropLast()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    static func codecName(_ codec: String) -> String? {
        switch codec.lowercased() {
        case "hevc", "h265": "HEVC"
        case "h264", "avc": "H.264"
        case "av1": "AV1"
        case "vp9": "VP9"
        case "mpeg2video": "MPEG-2"
        case "mpeg4": "MPEG-4"
        case "vc1": "VC-1"
        case "", "unknown": nil
        default: codec.uppercased()
        }
    }

    private static func rowLabel(_ source: MediaSource) -> String {
        let name = source.versionName.flatMap { isResolutionName($0) ? nil : $0 }
        return [name, source.resolutionBadge, source.rangeBadge,
                source.videoTracks.first.flatMap { codecName($0.codec) },
                source.audioBadge, source.fileSize.map(fileSize)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private static func fileStem(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private static func fileSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}
