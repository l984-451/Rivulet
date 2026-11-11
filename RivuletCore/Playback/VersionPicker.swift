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
