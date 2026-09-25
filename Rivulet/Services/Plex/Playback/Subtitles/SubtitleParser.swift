// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SubtitleParser.swift
//  Rivulet
//
//  Text subtitle parsers: WebVTT, SRT and ASS/SSA.
//
//  The app does not render app-parsed subtitles (captions come from
//  AetherEngine, or from AVPlayer's legible output on Live TV's remote-HLS
//  path). The one caller is the content filter, which parses `text/mcf+vtt`
//  filter documents with VTTParser, and reads a title's whole external
//  subtitle file with any of the three so language muting works with
//  subtitles hidden. See ContentFilterParsers and ContentFilterSources.
//
//  Nonisolated: the content filter parses off the main actor.
//

import Foundation

// MARK: - Parser Protocol

protocol SubtitleParser {
    func parse(_ content: String) throws -> ParsedSubtitleTrack
}

nonisolated enum SubtitleParseError: Error, LocalizedError {
    case invalidFormat(String)
    case emptyContent

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let msg): return "Invalid subtitle format: \(msg)"
        case .emptyContent: return "Subtitle file is empty"
        }
    }
}

// MARK: - SRT Parser

/// Parser for SubRip (.srt) subtitle files
/// Format:
/// ```
/// 1
/// 00:00:01,000 --> 00:00:04,000
/// First subtitle line
///
/// 2
/// 00:00:05,000 --> 00:00:08,000
/// Next subtitle
/// ```
nonisolated struct SRTParser: SubtitleParser {

    func parse(_ content: String) throws -> ParsedSubtitleTrack {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw SubtitleParseError.emptyContent
        }

        var cues: [SubtitleCue] = []

        // Cues are separated by a blank line. Normalize line endings first.
        let normalizedContent = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalizedContent.components(separatedBy: "\n\n")

        for block in blocks {
            let lines = block.components(separatedBy: "\n").map {
                $0.trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }

            // The timing line follows an optional sequence number.
            guard let timingLineIndex = lines.firstIndex(where: { $0.contains("-->") }),
                  let (start, end) = parseTimingLine(lines[timingLineIndex]) else { continue }

            let text = lines[(timingLineIndex + 1)...].joined(separator: "\n")
            guard !text.isEmpty else { continue }

            cues.append(SubtitleCue(
                id: cues.count,
                startTime: start,
                endTime: end,
                text: stripHTMLTags(text)
            ))
        }

        return ParsedSubtitleTrack(cues: cues.sorted { $0.startTime < $1.startTime })
    }

    /// Parse SRT timing line: "00:00:01,000 --> 00:00:04,000"
    private func parseTimingLine(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }

        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        let endStr = parts[1].trimmingCharacters(in: .whitespaces)
            // Remove position metadata if present (e.g., "00:00:04,000 X1:0 Y1:0")
            .components(separatedBy: " ").first ?? ""

        guard let start = parseSRTTimestamp(startStr),
              let end = parseSRTTimestamp(endStr) else {
            return nil
        }

        return (start, end)
    }

    /// Parse SRT timestamp: "00:00:01,000" or "00:01,000"
    private func parseSRTTimestamp(_ timestamp: String) -> TimeInterval? {
        let parts = timestamp.replacingOccurrences(of: ",", with: ".").components(separatedBy: ":")

        switch parts.count {
        case 3:
            guard let hours = Double(parts[0]),
                  let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        case 2:
            guard let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { return nil }
            return minutes * 60 + seconds
        default:
            return nil
        }
    }

    private func stripHTMLTags(_ text: String) -> String {
        // <i>, <b>, <u>, <font …> and friends, then the common entities.
        var result = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        return result
    }
}

// MARK: - ASS/SSA Parser

/// Reads the dialogue of an Advanced SubStation Alpha (.ass) or SubStation
/// Alpha (.ssa) script: timings and plain text only. Styling, positioning and
/// karaoke are dropped, since nothing here renders them.
/// ```
/// [Events]
/// Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
/// Dialogue: 0,0:00:01.00,0:00:04.00,Default,,0,0,0,,{\i1}First{\i0} line\NSecond line
/// ```
nonisolated struct ASSParser: SubtitleParser {

    func parse(_ content: String) throws -> ParsedSubtitleTrack {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SubtitleParseError.emptyContent
        }

        // The default ASS event format, used until the script declares its own.
        var fieldCount = 10
        var startIndex = 1
        var endIndex = 2
        var textIndex = 9
        var inEvents = false
        var cues: [SubtitleCue] = []

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents, let colon = line.firstIndex(of: ":") else { continue }
            let kind = line[..<colon].lowercased()
            let body = line[line.index(after: colon)...]

            if kind == "format" {
                let names = body.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                if let start = names.firstIndex(of: "start"),
                   let end = names.firstIndex(of: "end"),
                   let text = names.firstIndex(of: "text") {
                    fieldCount = names.count
                    startIndex = start
                    endIndex = end
                    textIndex = text
                }
                continue
            }
            guard kind == "dialogue" else { continue }

            // Text is the last field and may itself contain commas.
            let fields = body.split(separator: ",", maxSplits: fieldCount - 1, omittingEmptySubsequences: false)
            guard fields.count == fieldCount,
                  let start = parseASSTimestamp(fields[startIndex]),
                  let end = parseASSTimestamp(fields[endIndex]),
                  end > start else { continue }

            let text = cleanText(String(fields[textIndex]))
            guard !text.isEmpty else { continue }
            cues.append(SubtitleCue(id: cues.count, startTime: start, endTime: end, text: text))
        }

        return ParsedSubtitleTrack(cues: cues.sorted { $0.startTime < $1.startTime })
    }

    /// Parse an ASS timestamp: "0:00:01.00" (centiseconds).
    private func parseASSTimestamp(_ raw: Substring) -> TimeInterval? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3,
              let hours = Double(parts[0]),
              let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }

    /// Drop `{…}` override blocks and turn the line-break escapes into text.
    private func cleanText(_ text: String) -> String {
        text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - WebVTT Parser

/// Parser for WebVTT (.vtt) subtitle files
/// Format:
/// ```
/// WEBVTT
///
/// 00:00:01.000 --> 00:00:04.000
/// First subtitle line
///
/// NOTE This is a comment
///
/// 00:00:05.000 --> 00:00:08.000
/// Next subtitle
/// ```
nonisolated struct VTTParser: SubtitleParser {

    func parse(_ content: String) throws -> ParsedSubtitleTrack {
        let content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            throw SubtitleParseError.emptyContent
        }

        // Normalize line endings
        let normalizedContent = content.replacingOccurrences(of: "\r\n", with: "\n")

        // VTT must start with "WEBVTT" (with optional BOM)
        let lines = normalizedContent.components(separatedBy: "\n")
        guard let firstLine = lines.first,
              firstLine.trimmingCharacters(in: .whitespaces).hasPrefix("WEBVTT") else {
            throw SubtitleParseError.invalidFormat("Missing WEBVTT header")
        }

        var cues: [SubtitleCue] = []
        var currentIndex = 1  // Skip WEBVTT line

        while currentIndex < lines.count {
            // Skip empty lines and metadata blocks
            let line = lines[currentIndex].trimmingCharacters(in: .whitespaces)
            currentIndex += 1

            if line.isEmpty || line.hasPrefix("NOTE") || line.hasPrefix("STYLE") || line.hasPrefix("REGION") {
                // Skip until next empty line for multi-line metadata
                if line.hasPrefix("NOTE") || line.hasPrefix("STYLE") || line.hasPrefix("REGION") {
                    while currentIndex < lines.count && !lines[currentIndex].trimmingCharacters(in: .whitespaces).isEmpty {
                        currentIndex += 1
                    }
                }
                continue
            }

            // Check if this is a timing line
            var timingLine = line
            if !line.contains("-->") {
                // This might be a cue identifier, next line should be timing
                guard currentIndex < lines.count else { continue }
                timingLine = lines[currentIndex].trimmingCharacters(in: .whitespaces)
                currentIndex += 1
            }

            guard timingLine.contains("-->"),
                  let (start, end) = parseTimingLine(timingLine) else {
                continue
            }

            // Collect text lines until empty line
            var textLines: [String] = []
            while currentIndex < lines.count {
                let textLine = lines[currentIndex]
                if textLine.trimmingCharacters(in: .whitespaces).isEmpty {
                    currentIndex += 1
                    break
                }
                textLines.append(textLine)
                currentIndex += 1
            }

            let text = textLines.joined(separator: "\n")
            guard !text.isEmpty else { continue }

            // Strip VTT formatting tags
            let cleanText = stripVTTTags(text)

            cues.append(SubtitleCue(
                id: cues.count,
                startTime: start,
                endTime: end,
                text: cleanText
            ))
        }

        return ParsedSubtitleTrack(cues: cues.sorted { $0.startTime < $1.startTime })
    }

    /// Parse VTT timing line: "00:00:01.000 --> 00:00:04.000" with optional settings
    private func parseTimingLine(_ line: String) -> (TimeInterval, TimeInterval)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2 else { return nil }

        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        // End timestamp might have cue settings appended
        let endPart = parts[1].trimmingCharacters(in: .whitespaces)
        let endStr = endPart.components(separatedBy: " ").first ?? endPart

        guard let start = parseVTTTimestamp(startStr),
              let end = parseVTTTimestamp(endStr) else {
            return nil
        }

        return (start, end)
    }

    /// Parse VTT timestamp: "00:00:01.000" or "00:01.000"
    private func parseVTTTimestamp(_ timestamp: String) -> TimeInterval? {
        let parts = timestamp.components(separatedBy: ":")

        switch parts.count {
        case 3:
            // HH:MM:SS.mmm
            guard let hours = Double(parts[0]),
                  let minutes = Double(parts[1]),
                  let seconds = Double(parts[2]) else { return nil }
            return hours * 3600 + minutes * 60 + seconds
        case 2:
            // MM:SS.mmm
            guard let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]) else { return nil }
            return minutes * 60 + seconds
        default:
            return nil
        }
    }

    private func stripVTTTags(_ text: String) -> String {
        var result = text
        // Remove VTT voice tags: <v Speaker>
        result = result.replacingOccurrences(of: #"<v[^>]*>"#, with: "", options: .regularExpression)
        // Remove other tags: <c>, <i>, <b>, <u>, <ruby>, <rt>, <lang>
        result = result.replacingOccurrences(of: #"</?[a-z][^>]*>"#, with: "", options: .regularExpression)
        // Remove timestamps within cue: <00:00:01.000>
        result = result.replacingOccurrences(of: #"<\d{2}:\d{2}[:\.\d]*>"#, with: "", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
