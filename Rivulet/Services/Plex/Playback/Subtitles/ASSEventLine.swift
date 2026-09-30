// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  ASSEventLine.swift
//  Rivulet
//
//  One raw ASS event line as libavcodec hands it over under the engine's
//  `preserveASSMarkup`: `ReadOrder,Layer,Style,Name,MarginL,MarginR,MarginV,Effect,Text`,
//  no timestamps, override tags intact. libass renders these lines directly.
//  This type serves the readers that need text instead: the content filter,
//  and the caption overlay when the system Video Override settings pin the
//  user's own caption style.
//

import CoreGraphics
import Foundation

nonisolated struct ASSEventLine: Equatable {

    /// The Text field, override blocks and escapes intact.
    let rawText: String

    /// nil when `line` is not a nine-field event line with a numeric ReadOrder.
    init?(_ line: String) {
        var body = Substring(line)
        if body.hasPrefix("Dialogue: ") { body = body.dropFirst("Dialogue: ".count) }
        let fields = body.split(separator: ",", maxSplits: 8, omittingEmptySubsequences: false)
        guard fields.count == 9,
              Int(fields[0].trimmingCharacters(in: .whitespaces)) != nil,
              Int(fields[1].trimmingCharacters(in: .whitespaces)) != nil else { return nil }
        rawText = String(fields[8])
    }

    /// Every event line in one cue body. The engine joins the rects of one
    /// packet with newlines, and an event line itself never contains one
    /// (ASS spells a line break `\N`).
    static func lines(in body: String) -> [ASSEventLine] {
        body.split(separator: "\n").compactMap { ASSEventLine(String($0)) }
    }

    /// A vector drawing (`\p1` and up) carries path commands, not words.
    var isDrawing: Bool {
        Self.overrideTags(in: rawText).contains(#/\\p[1-9]/#)
    }

    /// Displayable text: override blocks dropped, `\N` and `\n` as newlines,
    /// `\h` as a space.
    var plainText: String { Self.clean(rawText) }

    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\h", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The line's `\an` and `\pos`, with `\pos` normalized against the
    /// script's PlayRes (y from the top), or nil when it asks for neither.
    /// The same two things the engine lifts out when it parses a line itself.
    func placement(playRes: CGSize) -> (alignment: Int?, position: CGPoint?)? {
        let tags = Self.overrideTags(in: rawText)
        let alignment = tags.firstMatch(of: #/\\an([1-9])/#).flatMap { Int($0.1) }
        var position: CGPoint?
        if let match = tags.firstMatch(of: #/\\pos\(\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)\s*\)/#),
           let x = Double(match.1), let y = Double(match.2),
           playRes.width > 0, playRes.height > 0 {
            position = CGPoint(x: x / playRes.width, y: y / playRes.height)
        }
        guard alignment != nil || position != nil else { return nil }
        return (alignment, position)
    }

    /// PlayResX / PlayResY from a script header, or libass's 384x288 default.
    static func playRes(fromHeader header: String?) -> CGSize {
        func value(_ key: String) -> Double? {
            header?.split(whereSeparator: \.isNewline)
                .first { $0.hasPrefix(key + ":") }
                .flatMap { Double($0.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)) }
        }
        guard let x = value("PlayResX"), let y = value("PlayResY"), x > 0, y > 0 else {
            return CGSize(width: 384, height: 288)
        }
        return CGSize(width: x, height: y)
    }

    /// The contents of every `{...}` block, joined.
    private static func overrideTags(in text: String) -> String {
        text.matches(of: #/\{([^}]*)\}/#).map { String($0.1) }.joined()
    }
}
