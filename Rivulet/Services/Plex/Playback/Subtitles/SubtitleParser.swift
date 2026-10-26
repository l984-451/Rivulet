// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SubtitleParser.swift
//  Rivulet
//
//  Text subtitle parsers: WebVTT, SRT and ASS/SSA.
//
//  The content filter reads a title's whole external subtitle file with any
//  of the three so language muting works with subtitles hidden, and parses
//  `text/mcf+vtt` filter documents with VTTParser. See ContentFilterParsers
//  and ContentFilterSources.
//
//  WebVTT sidecars are also DRAWN from here. SRT and ASS sidecars reach the
//  caption overlay through AetherEngine with their styling intact, but
//  libavcodec's WebVTT decoder keeps only b/i/u, so a WebVTT sidecar's colour
//  classes, STYLE rules and line numbers are read here instead
//  (`VTTParser.captionCues`, swapped in by UniversalPlayerViewModel).
//
//  Nonisolated: the content filter parses off the main actor.
//

import UIKit

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

        // Read line by line, starting a cue at each timing line, rather than
        // splitting on blank lines: files in the wild separate cues with lines
        // of spaces, or with nothing at all, and a missed separator would fold
        // one cue's text into the one before it.
        let lines = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var cues: [SubtitleCue] = []
        var timing: (start: TimeInterval, end: TimeInterval)?
        var textLines: [String] = []

        func flush() {
            if let timing, !textLines.isEmpty {
                cues.append(SubtitleCue(
                    id: cues.count,
                    startTime: timing.start,
                    endTime: timing.end,
                    text: stripHTMLTags(textLines.joined(separator: "\n"))
                ))
            }
            timing = nil
            textLines = []
        }

        for (index, line) in lines.enumerated() {
            if line.contains("-->"), let (start, end) = parseTimingLine(line) {
                flush()
                timing = (start, end)
                continue
            }
            guard timing != nil, !line.isEmpty else { continue }
            // A bare number right before a timing line is the next cue's
            // sequence number, not dialogue.
            if Int(line) != nil, index + 1 < lines.count, lines[index + 1].contains("-->") { continue }
            textLines.append(line)
        }
        flush()

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
        ASSEventLine.clean(text)
    }
}

// MARK: - WebVTT Parser

/// Parser for WebVTT (.vtt) subtitle files. `parse` gives the content filter
/// plain text; `WebVTTDocument` keeps the styling for the caption overlay.
nonisolated struct VTTParser: SubtitleParser {

    func parse(_ content: String) throws -> ParsedSubtitleTrack {
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SubtitleParseError.emptyContent
        }
        guard let document = WebVTTDocument.parse(content) else {
            throw SubtitleParseError.invalidFormat("Missing WEBVTT header")
        }
        let cues = document.cues.enumerated().map { index, cue in
            SubtitleCue(id: index, startTime: cue.start, endTime: cue.end,
                        text: cue.runs.map(\.text).joined())
        }
        return ParsedSubtitleTrack(cues: cues)
    }
}

/// A WebVTT file read with its styling: cue spans and classes, the spec's
/// default colour classes, STYLE-block `::cue` rules and the cue settings.
/// Times are the file's own, the axis the engine's sidecar cues use too.
nonisolated struct WebVTTDocument: Equatable, Sendable {

    var cues: [Cue]

    struct Cue: Equatable, Sendable {
        var start: Double
        var end: Double
        var runs: [Run]
        var settings: Settings
    }

    /// One span of cue text with its resolved style. nil and false mean the
    /// file said nothing, so the viewer's caption setting applies.
    struct Run: Equatable, Sendable {
        var text: String
        var color: RGBA?
        var backgroundColor: RGBA?
        var isBold = false
        var isItalic = false
        var isUnderlined = false
        var isStruckThrough = false
        var fontFamily: String?

        var hasStyling: Bool {
            color != nil || backgroundColor != nil || isBold || isItalic
                || isUnderlined || isStruckThrough || fontFamily != nil
        }
    }

    struct RGBA: Equatable, Hashable, Sendable {
        var r: Double, g: Double, b: Double, a: Double
    }

    /// Cue settings as written. `vertical` text is kept as a flag so a host can
    /// leave the cue in its default band rather than lay it out sideways.
    struct Settings: Equatable, Sendable {
        enum Align: Equatable, Sendable { case start, center, end }
        enum LineAlign: Equatable, Sendable { case start, center, end }

        var align: Align?
        /// `line:NN%` as a [0, 1] fraction.
        var lineFraction: Double?
        /// `line:N`, a snap-to-lines line number.
        var lineNumber: Int?
        var lineAlign: LineAlign?
        /// `position:NN%` as a [0, 1] fraction.
        var position: Double?
        var isVertical = false

        var isEmpty: Bool {
            align == nil && lineFraction == nil && lineNumber == nil && position == nil
        }
    }

    // MARK: - Parsing

    /// nil when the text is not WebVTT (no `WEBVTT` signature).
    static func parse(_ content: String) -> WebVTTDocument? {
        var text = content
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        guard let first = lines.first, first.hasPrefix("WEBVTT") else { return nil }

        // Blocks are separated by blank lines; the first is the header.
        var blocks: [[String]] = []
        var current: [String] = []
        for line in lines.dropFirst() {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { blocks.append(current) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current) }

        var sheet = StyleSheet()
        var cues: [Cue] = []
        for block in blocks {
            let head = block[0].trimmingCharacters(in: .whitespaces)
            if head == "STYLE" || head.hasPrefix("STYLE ") {
                // The spec allows STYLE only before the first cue.
                if cues.isEmpty { sheet.add(css: block.dropFirst().joined(separator: "\n")) }
                continue
            }
            if head.hasPrefix("NOTE") || head == "REGION" || head.hasPrefix("REGION ") { continue }
            guard let timingIndex = block.firstIndex(where: { $0.contains("-->") }), timingIndex <= 1,
                  let timing = parseTiming(block[timingIndex]) else { continue }
            let payload = block[(timingIndex + 1)...].joined(separator: "\n")
            let runs = CueText.runs(from: payload, sheet: sheet)
            guard !runs.isEmpty else { continue }
            cues.append(Cue(start: timing.start, end: timing.end, runs: runs, settings: timing.settings))
        }
        cues.sort { $0.start < $1.start }
        return WebVTTDocument(cues: cues)
    }

    private static func parseTiming(_ line: String) -> (start: Double, end: Double, settings: Settings)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count == 2,
              let start = timestamp(parts[0].trimmingCharacters(in: .whitespaces)) else { return nil }
        let rest = parts[1].trimmingCharacters(in: .whitespaces)
        let fields = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let endField = fields.first, let end = timestamp(endField) else { return nil }
        return (start, end, settings(Array(fields.dropFirst())))
    }

    /// `hh:mm:ss.ttt` or `mm:ss.ttt`.
    static func timestamp(_ value: String) -> Double? {
        let parts = value.split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        let secondsPart = parts[parts.count - 1].replacingOccurrences(of: ",", with: ".")
        guard let seconds = Double(secondsPart) else { return nil }
        var total = seconds
        guard let minutes = Double(parts[parts.count - 2]) else { return nil }
        total += minutes * 60
        if parts.count == 3 {
            guard let hours = Double(parts[0]) else { return nil }
            total += hours * 3600
        }
        return total
    }

    static func settings(_ fields: [String]) -> Settings {
        var settings = Settings()
        for field in fields {
            let pair = field.split(separator: ":", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let value = pair[1]
            switch pair[0].lowercased() {
            case "vertical":
                settings.isVertical = value == "rl" || value == "lr"
            case "align":
                switch value.lowercased() {
                case "start", "left": settings.align = .start
                case "center", "centre", "middle": settings.align = .center
                case "end", "right": settings.align = .end
                default: break
                }
            case "line":
                let parts = value.split(separator: ",", maxSplits: 1).map(String.init)
                if let first = parts.first {
                    if let fraction = percent(first) {
                        settings.lineFraction = fraction
                    } else if let number = Int(first) {
                        settings.lineNumber = number
                    }
                }
                if parts.count == 2 {
                    switch parts[1].lowercased() {
                    case "start": settings.lineAlign = .start
                    case "center", "centre", "middle": settings.lineAlign = .center
                    case "end": settings.lineAlign = .end
                    default: break
                    }
                }
            case "position":
                let head = value.split(separator: ",", maxSplits: 1).first.map(String.init) ?? value
                settings.position = percent(head)
            default:
                continue  // size, region: nothing the overlay models
            }
        }
        return settings
    }

    private static func percent(_ value: String) -> Double? {
        guard value.hasSuffix("%"), let number = Double(value.dropLast()) else { return nil }
        return min(max(number / 100, 0), 1)
    }
}

// MARK: - Cue text

private nonisolated enum CueText {

    /// One open element: its tag name, classes and (for `v`) voice.
    struct Element {
        var tag: String
        var classes: [String]
        var voice: String?
    }

    static func runs(from payload: String, sheet: StyleSheet) -> [WebVTTDocument.Run] {
        var runs: [WebVTTDocument.Run] = []
        var stack: [Element] = []
        var buffer = ""
        var insideRubyText = 0

        func flush() {
            guard !buffer.isEmpty else { return }
            let text = decodeEntities(buffer)
            buffer = ""
            guard insideRubyText == 0 else { return }  // ruby annotations are not drawn inline
            let style = sheet.resolve(stack)
            if var last = runs.last, last.styleMatches(style) {
                last.text += text
                runs[runs.count - 1] = last
            } else {
                var run = style
                run.text = text
                runs.append(run)
            }
        }

        var index = payload.startIndex
        while index < payload.endIndex {
            let character = payload[index]
            guard character == "<", let close = payload[index...].firstIndex(of: ">") else {
                buffer.append(character)
                index = payload.index(after: index)
                continue
            }
            let tag = String(payload[payload.index(after: index)..<close])
            index = payload.index(after: close)
            flush()

            if tag.hasPrefix("/") {
                let name = tag.dropFirst().trimmingCharacters(in: .whitespaces).lowercased()
                if name == "rt" { insideRubyText = max(0, insideRubyText - 1) }
                // Close the nearest matching element; a stray close tag is ignored.
                if let match = stack.lastIndex(where: { $0.tag == name }) {
                    stack.removeSubrange(match...)
                }
                continue
            }
            // Karaoke timestamps (`<00:01.000>`) carry no style.
            if let first = tag.first, first.isNumber { continue }

            let head = tag.split(separator: " ", maxSplits: 1).map(String.init)
            let nameAndClasses = (head.first ?? "").split(separator: ".").map(String.init)
            guard let name = nameAndClasses.first?.lowercased(), !name.isEmpty else { continue }
            let voice = name == "v" && head.count == 2 ? head[1].trimmingCharacters(in: .whitespaces) : nil
            if name == "rt" { insideRubyText += 1 }
            stack.append(Element(tag: name, classes: nameAndClasses.dropFirst().map { $0.lowercased() },
                                 voice: voice))
        }
        flush()

        // Trim the cue's outer whitespace, as a caption box does.
        if var first = runs.first {
            first.text = String(first.text.drop(while: { $0.isWhitespace }))
            runs[0] = first
        }
        if var last = runs.last {
            while let c = last.text.last, c.isWhitespace { last.text.removeLast() }
            runs[runs.count - 1] = last
        }
        return runs.filter { !$0.text.isEmpty }
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index] == "&", let semi = text[index...].prefix(12).firstIndex(of: ";") else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            let name = String(text[text.index(after: index)..<semi])
            if let decoded = entity(name) {
                result += decoded
                index = text.index(after: semi)
            } else {
                result.append(text[index])
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func entity(_ name: String) -> String? {
        switch name {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "nbsp": return "\u{00A0}"
        case "lrm": return "\u{200E}"
        case "rlm": return "\u{200F}"
        case "quot": return "\""
        case "apos": return "'"
        default:
            guard name.hasPrefix("#") else { return nil }
            let digits = name.dropFirst()
            let value = digits.lowercased().hasPrefix("x")
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits)
            return value.flatMap(Unicode.Scalar.init).map { String(Character($0)) }
        }
    }
}

private extension WebVTTDocument.Run {
    func styleMatches(_ other: WebVTTDocument.Run) -> Bool {
        color == other.color && backgroundColor == other.backgroundColor && isBold == other.isBold
            && isItalic == other.isItalic && isUnderlined == other.isUnderlined
            && isStruckThrough == other.isStruckThrough && fontFamily == other.fontFamily
    }
}

// MARK: - Style sheet

/// The `::cue` rules of a file's STYLE blocks, plus the spec's default classes.
///
/// Rules apply in source order, after the defaults, outer element first, so an
/// author rule overrides a default class and an inner span overrides its parent.
/// That is cascade by order alone, which is how real files are written.
private nonisolated struct StyleSheet {

    struct Selector {
        var tag: String?
        var classes: [String]
        var voice: String?

        /// True for the bare `::cue`.
        var isRoot: Bool { tag == nil && classes.isEmpty && voice == nil }

        func matches(_ element: CueText.Element) -> Bool {
            if let tag, tag != element.tag { return false }
            if !classes.allSatisfy(element.classes.contains) { return false }
            if let voice, voice != element.voice { return false }
            return true
        }
    }

    struct Declarations {
        var color: WebVTTDocument.RGBA?
        var backgroundColor: WebVTTDocument.RGBA?
        var bold: Bool?
        var italic: Bool?
        var underline: Bool?
        var strike: Bool?
        var fontFamily: String?

        func apply(to run: inout WebVTTDocument.Run) {
            if let color { run.color = color }
            if let backgroundColor { run.backgroundColor = backgroundColor }
            if let bold { run.isBold = bold }
            if let italic { run.isItalic = italic }
            if let underline { run.isUnderlined = underline }
            if let strike { run.isStruckThrough = strike }
            if let fontFamily { run.fontFamily = fontFamily }
        }
    }

    private var rules: [(selector: Selector, declarations: Declarations)] = []

    mutating func add(css: String) {
        // Comments out, then `selectors { declarations }` blocks.
        var source = css
        while let open = source.range(of: "/*") {
            let close = source.range(of: "*/", range: open.upperBound..<source.endIndex)
            source.removeSubrange(open.lowerBound..<(close?.upperBound ?? source.endIndex))
        }
        for block in source.components(separatedBy: "}") {
            let parts = block.components(separatedBy: "{")
            guard parts.count == 2 else { continue }
            let declarations = Self.declarations(parts[1])
            for selectorText in parts[0].components(separatedBy: ",") {
                guard let selector = Self.selector(selectorText) else { continue }
                rules.append((selector, declarations))
            }
        }
    }

    func resolve(_ stack: [CueText.Element]) -> WebVTTDocument.Run {
        var run = WebVTTDocument.Run(text: "")
        for (selector, declarations) in rules where selector.isRoot {
            declarations.apply(to: &run)
        }
        for element in stack {
            switch element.tag {
            case "b": run.isBold = true
            case "i": run.isItalic = true
            case "u": run.isUnderlined = true
            default: break
            }
            for name in element.classes {
                if let color = Self.defaultClassColors[name] { run.color = color }
                if name.hasPrefix("bg_"), let color = Self.defaultClassColors[String(name.dropFirst(3))] {
                    run.backgroundColor = color
                }
            }
            for (selector, declarations) in rules where !selector.isRoot && selector.matches(element) {
                declarations.apply(to: &run)
            }
        }
        return run
    }

    /// `::cue`, `::cue(.loud)`, `::cue(c.loud)`, `::cue(v[voice="Bob"])`. Anything
    /// else (pseudo-classes, `::cue-region`, combinators) is skipped.
    private static func selector(_ text: String) -> Selector? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("::cue") else { return nil }
        let rest = trimmed.dropFirst("::cue".count)
        if rest.isEmpty { return Selector(tag: nil, classes: [], voice: nil) }
        guard rest.hasPrefix("("), rest.hasSuffix(")") else { return nil }
        var inner = String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)

        var voice: String?
        if let open = inner.firstIndex(of: "["), let close = inner.lastIndex(of: "]"), open < close {
            let attribute = inner[inner.index(after: open)..<close]
            let pair = attribute.split(separator: "=", maxSplits: 1)
            guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces) == "voice" else { return nil }
            voice = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            inner.removeSubrange(open...close)
        }
        guard !inner.contains(where: { " :>+~#*".contains($0) }) else { return nil }
        let parts = inner.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        let tag = parts.first.flatMap { $0.isEmpty ? nil : $0.lowercased() }
        let classes = parts.dropFirst().filter { !$0.isEmpty }.map { $0.lowercased() }
        return Selector(tag: tag, classes: classes, voice: voice)
    }

    private static func declarations(_ text: String) -> Declarations {
        var result = Declarations()
        for declaration in text.components(separatedBy: ";") {
            let pair = declaration.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let property = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = pair[1].replacingOccurrences(of: "!important", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = value.lowercased()
            switch property {
            case "color":
                result.color = color(lower)
            case "background-color", "background":
                result.backgroundColor = color(lower)
            case "font-weight":
                result.bold = lower == "bold" || lower == "bolder" || (Int(lower) ?? 400) >= 600
            case "font-style":
                result.italic = lower == "italic" || lower == "oblique"
            case "text-decoration", "text-decoration-line":
                result.underline = lower.contains("underline")
                result.strike = lower.contains("line-through")
            case "font-family":
                let first = value.split(separator: ",").first.map(String.init) ?? value
                let family = first.trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                if !family.isEmpty { result.fontFamily = family }
            default:
                continue
            }
        }
        return result
    }

    /// CSS named colours, `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()` and `rgba()`.
    static func color(_ value: String) -> WebVTTDocument.RGBA? {
        if let named = namedColors[value] { return named }
        if value.hasPrefix("#") {
            var hex = String(value.dropFirst())
            if hex.count == 3 || hex.count == 4 { hex = hex.map { "\($0)\($0)" }.joined() }
            guard hex.count == 6 || hex.count == 8, let number = UInt64(hex, radix: 16) else { return nil }
            let hasAlpha = hex.count == 8
            let shift: UInt64 = hasAlpha ? 8 : 0
            func channel(_ offset: UInt64) -> Double { Double((number >> (offset + shift)) & 0xFF) / 255 }
            return WebVTTDocument.RGBA(r: channel(16), g: channel(8), b: channel(0),
                                       a: hasAlpha ? Double(number & 0xFF) / 255 : 1)
        }
        if value.hasPrefix("rgb"), let open = value.firstIndex(of: "("), let close = value.lastIndex(of: ")") {
            let numbers = value[value.index(after: open)..<close]
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" })
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard numbers.count >= 3 else { return nil }
            func component(_ text: String, scale: Double) -> Double? {
                if text.hasSuffix("%") { return Double(text.dropLast()).map { $0 / 100 } }
                return Double(text).map { $0 / scale }
            }
            guard let r = component(numbers[0], scale: 255), let g = component(numbers[1], scale: 255),
                  let b = component(numbers[2], scale: 255) else { return nil }
            let a = numbers.count > 3 ? component(numbers[3], scale: 1) ?? 1 : 1
            return WebVTTDocument.RGBA(r: min(r, 1), g: min(g, 1), b: min(b, 1), a: min(a, 1))
        }
        return nil
    }

    /// The colour classes every WebVTT renderer must support (WebVTT §5.1),
    /// plus `green`: broadcaster files converted from CEA-608 name its green
    /// that way (7plus), where the spec's name is `lime`.
    static let defaultClassColors: [String: WebVTTDocument.RGBA] = rgbTable([
        ("white", 255, 255, 255), ("lime", 0, 255, 0), ("green", 0, 255, 0), ("cyan", 0, 255, 255),
        ("red", 255, 0, 0), ("yellow", 255, 255, 0), ("magenta", 255, 0, 255), ("blue", 0, 0, 255),
        ("black", 0, 0, 0)
    ])

    private static let namedColors: [String: WebVTTDocument.RGBA] = {
        var table = defaultClassColors.merging(rgbTable([
            ("green", 0, 128, 0), ("gray", 128, 128, 128), ("grey", 128, 128, 128),
            ("silver", 192, 192, 192), ("orange", 255, 165, 0), ("purple", 128, 0, 128),
            ("pink", 255, 192, 203), ("aqua", 0, 255, 255), ("fuchsia", 255, 0, 255)
        ])) { _, css in css }  // `color: green` is CSS's green, not the class's
        table["transparent"] = WebVTTDocument.RGBA(r: 0, g: 0, b: 0, a: 0)
        return table
    }()

    private static func rgbTable(_ entries: [(String, Double, Double, Double)]) -> [String: WebVTTDocument.RGBA] {
        var table: [String: WebVTTDocument.RGBA] = [:]
        for (name, r, g, b) in entries {
            table[name] = WebVTTDocument.RGBA(r: r / 255, g: g / 255, b: b / 255, a: 1)
        }
        return table
    }
}

// MARK: - WebVTT caption cues

/// A WebVTT sidecar's cues for the caption overlay. The engine still owns the
/// track selection; the view model swaps these in for the engine's cues.
@MainActor extension VTTParser {

    /// True for a sidecar the overlay should read itself.
    static func isWebVTT(formatHint: String?, url: URL) -> Bool {
        let format = (formatHint ?? url.pathExtension).lowercased()
        return format == "vtt" || format == "webvtt"
    }

    static func captionCues(from document: WebVTTDocument) -> [AetherSubtitleCue] {
        document.cues.enumerated().map { index, cue in
            AetherSubtitleCue(id: index, startTime: cue.start, endTime: cue.end,
                              body: body(for: cue.runs), placement: placement(for: cue.settings))
        }
    }

    static func body(for runs: [WebVTTDocument.Run]) -> AetherSubtitleCue.Body {
        if runs.count == 1, let run = runs.first, !run.hasStyling { return .text(run.text) }
        return .styledText(runs.map { run in
            AetherSubtitleCue.StyledRun(
                text: run.text,
                color: run.color.map(uiColor),
                backgroundColor: run.backgroundColor.map(uiColor),
                isBold: run.isBold,
                isItalic: run.isItalic,
                isUnderlined: run.isUnderlined,
                isStruckThrough: run.isStruckThrough,
                fontName: run.fontFamily
            )
        })
    }

    /// The same reading the engine gives WebVTT cue settings on its own path
    /// (`WebVTTCueSettings`), plus the line number it has nowhere to put.
    static func placement(for settings: WebVTTDocument.Settings) -> AetherSubtitleCue.TextPlacement? {
        // Sideways text laid out horizontally reads worse than the default band.
        guard !settings.isVertical, !settings.isEmpty else { return nil }

        let column: Int
        switch settings.align {
        case .start: column = 0
        case .end: column = 2
        case .center, nil: column = 1
        }

        var row = 0
        if let fraction = settings.lineFraction {
            // Anchored to the nearer edge, so a two-line cue at line:90% stays on screen.
            row = fraction >= 0.5 ? 0 : 2
        } else if let number = settings.lineNumber {
            row = number < 0 ? 0 : 2
        }
        switch settings.lineAlign {
        case .start: row = 2
        case .center: row = 1
        case .end: row = 0
        case nil: break
        }

        var position: CGPoint?
        if let y = settings.lineFraction {
            position = CGPoint(x: settings.position ?? [0.0, 0.5, 1.0][column], y: y)
        }
        return AetherSubtitleCue.TextPlacement(alignment: row * 3 + column + 1,
                                               position: position,
                                               lineNumber: settings.lineNumber)
    }

    private static func uiColor(_ rgba: WebVTTDocument.RGBA) -> UIColor {
        UIColor(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }
}
