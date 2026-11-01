// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Groups heard words into subtitle lines: a pause, a sentence end or the
/// length of two caption lines starts a new one.
nonisolated enum SpeechCaptions {

    struct Line: Equatable, Sendable {
        let start: Double
        let end: Double
        let text: String
    }

    /// Silence that ends a line after a sentence or clause, and silence that ends one anywhere.
    static let pause = 0.7
    static let longPause = 1.5
    /// Two lines' worth of characters, and one line's.
    static let maxChars = 84
    static let lineChars = 42
    static let maxDuration = 5.0
    /// How long a line stays up after its last word, and its shortest life.
    static let hold = 0.7
    static let minDuration = 1.2

    static func lines(from words: [SpokenWord]) -> [Line] {
        var groups: [[SpokenWord]] = []
        for word in words where !word.text.isEmpty {
            guard let group = groups.last else {
                groups.append([word])
                continue
            }
            guard let ending = ending(group, before: word) else {
                groups[groups.count - 1].append(word)
                continue
            }
            // A full line carries its unfinished clause over to the next.
            let carry = ending == .full ? group.indices.dropFirst(group.count / 2).last { ends(group[$0 - 1], in: ".?!,;") } : nil
            if let carry {
                groups[groups.count - 1].removeSubrange(carry...)
                groups.append(Array(group[carry...]) + [word])
            } else {
                groups.append([word])
            }
        }
        return groups.indices.map { index in
            let group = groups[index]
            let start = group[0].start
            let spoken = group[group.count - 1].end
            let next = index + 1 < groups.count ? groups[index + 1][0].start - 0.05 : .infinity
            let end = max(spoken, min(max(spoken + hold, start + minDuration), next))
            return Line(start: start, end: end, text: wrapped(group.map(\.text).joined(separator: " ")))
        }
    }

    private enum Ending { case clean, full }

    /// Why `word` can't join `group`'s line, or nil when it can.
    private static func ending(_ group: [SpokenWord], before word: SpokenWord) -> Ending? {
        let last = group[group.count - 1]
        let chars = group.reduce(-1) { $0 + $1.text.count + 1 }
        let gap = word.start - last.end
        if gap > longPause || gap > pause && ends(last, in: ".?!,;") { return .clean }
        // A finished sentence ends the line once the line has some length.
        if endsSentence(last) && chars >= lineChars / 2 { return .clean }
        if chars + 1 + word.text.count > maxChars || word.end - group[0].start > maxDuration { return .full }
        return nil
    }

    private static func ends(_ word: SpokenWord, in marks: String) -> Bool {
        word.text.last.map(marks.contains) ?? false
    }

    private static func endsSentence(_ word: SpokenWord) -> Bool {
        ends(word, in: ".?!") && !["mr", "mrs", "ms", "dr", "st", "jr", "sr"].contains(SpokenWordAlignment.key(word.text))
    }

    /// Two balanced lines when the text is longer than one.
    static func wrapped(_ text: String) -> String {
        guard text.count > lineChars else { return text }
        let middle = text.count / 2
        let spaces = text.indices.filter { text[$0] == " " }
        guard let split = spaces.min(by: {
            abs(text.distance(from: text.startIndex, to: $0) - middle)
                < abs(text.distance(from: text.startIndex, to: $1) - middle)
        }) else { return text }
        return String(text[..<split]) + "\n" + String(text[text.index(after: split)...])
    }
}
