// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ContentFilterParsers.swift
//  Rivulet
//
//  Parsers for imported, time-coded filter lists:
//    - MCF  (Movie Content Filter, text/mcf+vtt): an open, WebVTT-based format
//           where each cue line is `category=severity[=channel][ # comment]`.
//           Spec: moviecontentfilter.com/specification
//    - EDL  (Edit Decision List): the simple `start end action` format written
//           by cleanvid, the Kodi mute-profanity add-on and MovieContentFilter's
//           own EDL export, and used by Kodi/Comskip/MythTV for skip + mute.
//
//  The MCF parser reuses the app's existing VTTParser to read cue timings, then
//  interprets each cue's text as a filter directive — so we get robust WebVTT
//  timestamp handling for free.
//
//  Everything here is nonisolated: lists are parsed off the main actor.
//

import Foundation

nonisolated enum ContentFilterParseError: Error {
    case empty
    case unrecognizedFormat
    /// An MCF list whose times are not on this release's timeline. See
    /// `MCFFilterParser.parse`.
    case unsynchronized
}

nonisolated enum ContentFilterFormat {
    case mcf
    case edl

    /// Best-effort format detection from a URL extension, then content.
    static func detect(url: URL?, content: String) -> ContentFilterFormat? {
        switch url?.pathExtension.lowercased() {
        case "mcf": return .mcf
        case "edl": return .edl
        default: break
        }
        let head = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("WEBVTT") { return .mcf }
        // EDL: the first data line (skipping blanks and # comments, which
        // tools like cleanvid emit as headers) is "time time number".
        let firstDataLine = head.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") }
        if let firstDataLine, EDLFilterParser.looksLikeEDLLine(firstDataLine) {
            return .edl
        }
        return nil
    }
}

/// Dispatches to the right parser and returns a normalized `ContentFilterList`.
nonisolated enum ContentFilterParser {
    /// - Parameter mediaDuration: the title's runtime in seconds, when known.
    ///   Lets the MCF parser reject a list that is not timed to this release.
    static func parse(content: String, url: URL?, mediaDuration: TimeInterval? = nil) throws -> ContentFilterList {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ContentFilterParseError.empty
        }
        switch ContentFilterFormat.detect(url: url, content: content) {
        case .mcf: return try MCFFilterParser.parse(content, mediaDuration: mediaDuration)
        case .edl: return try EDLFilterParser.parse(content)
        case nil: throw ContentFilterParseError.unrecognizedFormat
        }
    }
}

// MARK: - Timestamps

/// Seconds from a filter-list time field: plain seconds ("5025.3") or a clock
/// time ("01:23:45.300", "01:23:45,300", "23:45.3").
nonisolated enum FilterTimestamp {
    static func seconds<S: StringProtocol>(_ raw: S) -> TimeInterval? {
        let text = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total: TimeInterval = 0
        for (index, part) in parts.enumerated() {
            guard let value = Double(part), value >= 0 else { return nil }
            // Only the last field may carry a fraction.
            if index < parts.count - 1, part.contains(".") { return nil }
            total = total * 60 + value
        }
        return total.isFinite ? total : nil
    }
}

// MARK: - MCF

nonisolated enum MCFFilterParser {

    /// Parse a `text/mcf+vtt` document. Cue timings come from the shared
    /// `VTTParser`; each line of a cue is one `category=severity[=channel]`
    /// span, optionally followed by ` # comment`.
    ///
    /// An MCF file's START/END header marks where the film material begins and
    /// ends, and every cue is timed on that scale. Hand-made files use real
    /// times. moviecontentfilter.com's own `.mcf` download does not: it rescales
    /// the title onto 00:00:00.000–99:59:59.999 and leaves the player to map it
    /// back using the release's own start and end, which Rivulet can't know.
    /// Applied as-is it would mute and skip at the wrong moments, so such a
    /// file throws `.unsynchronized`. That site's EDL export takes the release's
    /// start and end and is the precise route.
    static func parse(_ content: String, mediaDuration: TimeInterval? = nil) throws -> ContentFilterList {
        if let end = declaredEnd(in: content), !fitsRelease(end: end, mediaDuration: mediaDuration) {
            throw ContentFilterParseError.unsynchronized
        }

        let track = try VTTParser().parse(content)
        var regions: [FilterRegion] = []

        for cue in track.cues where cue.endTime > cue.startTime {
            // A bare `channel=…` token (older hand-written files) applies to
            // every span in the cue that doesn't name its own channel.
            var cueChannel: String?
            var spans: [[String]] = []
            for line in cue.text.split(whereSeparator: \.isNewline) {
                // Everything after "#" is a comment (the spec writes " # "), and
                // a comment can hold a URL whose query would read as a span.
                let directive = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? line
                for token in directive.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                    let parts = token.lowercased().split(separator: "=", omittingEmptySubsequences: false).map(String.init)
                    guard parts.count >= 2, !parts[0].isEmpty else { continue }
                    if parts[0] == "channel" {
                        cueChannel = parts[1]
                    } else {
                        spans.append(parts)
                    }
                }
            }

            for span in spans {
                guard let category = FilterCategory(mcfName: span[0]) else { continue }
                let channel = span.count >= 3 ? span[2] : cueChannel
                regions.append(FilterRegion(
                    id: regions.count,
                    start: cue.startTime,
                    end: cue.endTime,
                    category: category,
                    severity: FilterSeverity(mcf: span[1]),
                    action: actionFor(channel: channel, category: category)
                ))
            }
        }

        return ContentFilterList(regions: regions)
    }

    /// `channel=audio` → mute (only the sound is objectionable); `video` or
    /// `both` → skip. Absent channel falls back to the category default, so a
    /// bare `language=high` mutes rather than cutting the scene.
    private static func actionFor(channel: String?, category: FilterCategory) -> FilterAction {
        switch channel {
        case "audio": return .mute
        case "video", "audiovisual", "both": return .skip
        default: return category.defaultAction
        }
    }

    /// The END timestamp from the header, if the file has one.
    static func declaredEnd(in content: String) -> TimeInterval? {
        for line in content.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.contains("-->") { break }  // the header is over once cues start
            if trimmed.hasPrefix("END ") { return FilterTimestamp.seconds(trimmed.dropFirst(4)) }
        }
        return nil
    }

    /// Whether a list whose film material ends at `end` is timed to this
    /// release. A real-time list ends before the closing credits, so it cannot
    /// run past the runtime; a minute's allowance covers a slightly longer cut.
    static func fitsRelease(end: TimeInterval, mediaDuration: TimeInterval?) -> Bool {
        if let mediaDuration, mediaDuration > 0 { return end <= mediaDuration + 60 }
        // Runtime unknown: only the site's normalized scale is recognizable.
        return end < 99 * 3600
    }
}

// MARK: - EDL

nonisolated enum EDLFilterParser {

    /// Parse a whitespace-delimited EDL. Each line: `start end action [category]`,
    /// times in seconds or as clock times. action 0 = cut/skip, 1 = mute,
    /// 2 = scene marker (ignored), 3 = commercial (skip). An optional 4th token
    /// names a category for finer control.
    static func parse(_ content: String) throws -> ContentFilterList {
        var regions: [FilterRegion] = []

        for rawLine in content.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }

            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 3,
                  let start = FilterTimestamp.seconds(fields[0]),
                  let end = FilterTimestamp.seconds(fields[1]),
                  let action = Int(fields[2]),
                  end > start else {
                continue
            }

            let filterAction: FilterAction
            switch action {
            case 1: filterAction = .mute
            case 0, 3: filterAction = .skip
            default: continue  // 2 = scene marker, or unknown → ignore
            }

            // Optional 4th token: category name. Otherwise bucket as `.other`,
            // which the master toggle governs.
            let category: FilterCategory = fields.count >= 4
                ? FilterCategory.matching(fields[3])
                : .other

            regions.append(FilterRegion(
                id: regions.count,
                start: start,
                end: end,
                category: category,
                // An EDL carries no severity, and every line in one was written
                // to be acted on, so Profanity Strength must never drop it.
                severity: .strong,
                action: filterAction
            ))
        }

        return ContentFilterList(regions: regions)
    }

    /// True if a line looks like `time time number …` (EDL detection).
    static func looksLikeEDLLine(_ line: String) -> Bool {
        let fields = line.trimmingCharacters(in: .whitespaces)
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard fields.count >= 3 else { return false }
        return FilterTimestamp.seconds(fields[0]) != nil
            && FilterTimestamp.seconds(fields[1]) != nil
            && Int(fields[2]) != nil
    }
}
