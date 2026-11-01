// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  Places a subtitle line's words on the audio, from the words an on-device
//  speech model heard, so the content filter can mute one word instead of the
//  whole cue. Pure; the filter falls back to the whole cue whenever this
//  cannot place a word with confidence.
//

import Foundation

/// A word the speech model heard, on the source time axis.
nonisolated struct SpokenWord: Sendable, Equatable {
    let text: String
    let start: Double
    let end: Double
    let confidence: Float
}

nonisolated enum SpokenWordAlignment {

    /// How far outside its cue a line's speech is searched for: cue timing is loose.
    static let searchMargin = 0.75
    /// Silence added before and after a placed word.
    static let leadPad = 0.1
    static let tailPad = 0.15
    /// Spans closer than this become one, so a run of words doesn't flicker.
    static let joinGap = 0.3
    /// Typical spoken word, for a word placed from one side only.
    static let wordDuration = 0.4
    /// Extra room for a word placed from one side, in case it was spoken slowly.
    static let edgeSlack = 0.3

    /// The stretch of audio a cue's words are searched in.
    static func searchRange(cueStart: Double, cueEnd: Double) -> ClosedRange<Double> {
        (cueStart - searchMargin)...(cueEnd + searchMargin)
    }

    /// Spans to mute for the `flagged` tokens of a cue, or nil when the words
    /// heard don't place them, in which case the caller mutes the whole cue.
    ///
    /// A flagged word that was heard is muted where it was heard. One that
    /// wasn't (misheard, masked, drowned out) is muted across the gap between
    /// the placed words either side of it, or from one of them to the cue's
    /// edge: never wider than the cue, so a miss costs precision, not a leak.
    static func muteSpans(cueStart: Double, cueEnd: Double, tokens: [String],
                          flagged: Set<Int>, words: [SpokenWord]) -> [ClosedRange<Double>]? {
        let range = searchRange(cueStart: cueStart, cueEnd: cueEnd)
        let heard = words.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
        guard !heard.isEmpty, !flagged.isEmpty else { return nil }
        let keys = tokens.map(key)
        let pairs = align(keys, heard.map { key($0.text) })
        // An anchor for a missed word must be unlikely to be a chance match:
        // a real word, one with a matched neighbour ("oh my", "the hell"), or
        // part of the flagged phrase itself ("oh" of "oh god").
        let anchors = pairs.filter { index, _ in
            keys[index].count >= 3 || flagged.contains(index) || pairs[index - 1] != nil || pairs[index + 1] != nil
        }

        // Anchors either side of a token that can bound it: a left anchor must
        // end inside the line, a right one start inside it. One that doesn't
        // belongs to a neighbouring line, so the next one out is tried.
        func leftAnchor(of index: Int) -> (distance: Int, word: SpokenWord)? {
            anchors.keys.filter { $0 < index }.sorted(by: >)
                .first { heard[anchors[$0]!].end < cueEnd }
                .map { (index - $0, heard[anchors[$0]!]) }
        }
        func rightAnchor(of index: Int) -> (distance: Int, word: SpokenWord)? {
            anchors.keys.filter { $0 > index }.sorted()
                .first { heard[anchors[$0]!].start > cueStart }
                .map { ($0 - index, heard[anchors[$0]!]) }
        }

        var placed: [Int: ClosedRange<Double>] = [:]
        for index in flagged { if let word = pairs[index] { placed[index] = heard[word].start...heard[word].end } }

        // A missed run of flagged words may still be in what was heard, spelled
        // differently ("Fucket" for "fucking") or joined ("goddamn" for "god damn").
        let paired = Set(pairs.values)
        for run in runs(flagged.filter { placed[$0] == nil }.sorted()) {
            let from = leftAnchor(of: run[0])?.word.end ?? range.lowerBound
            let to = rightAnchor(of: run[run.count - 1])?.word.start ?? range.upperBound
            let parts = run.map { keys[$0] }
            let found = heard.indices.first { index in
                !paired.contains(index) && heard[index].start >= from - 0.1 && heard[index].end <= to + 0.1
                    && resembles(key(heard[index].text), parts)
            }
            if let found { for index in run { placed[index] = heard[found].start...heard[found].end } }
        }

        var spans: [ClosedRange<Double>] = []
        for index in flagged.sorted() {
            if let span = placed[index] {
                spans.append(span)
                continue
            }
            switch (leftAnchor(of: index), rightAnchor(of: index)) {
            case let (l?, r?):
                spans.append(min(l.word.end, r.word.start)...max(l.word.end, r.word.start))
            case let (l?, nil):
                let end = min(cueEnd, l.word.end + wordDuration * Double(l.distance) + edgeSlack)
                spans.append(l.word.end...max(end, l.word.end + wordDuration))
            case let (nil, r?):
                let start = max(cueStart, r.word.start - wordDuration * Double(r.distance) - edgeSlack)
                spans.append(min(start, r.word.start - wordDuration)...r.word.start)
            case (nil, nil):
                return nil
            }
        }
        return merged(spans.map(padded))
    }

    /// Consecutive indices grouped: [2, 3, 7] -> [[2, 3], [7]].
    private static func runs(_ indices: [Int]) -> [[Int]] {
        var out: [[Int]] = []
        for index in indices {
            if let last = out.last?.last, last == index - 1 { out[out.count - 1].append(index) } else { out.append([index]) }
        }
        return out
    }

    /// Whether a heard word is a run of flagged words, said or spelled differently.
    static func resembles(_ heard: String, _ parts: [String]) -> Bool {
        let joined = parts.joined()
        if similar(heard, joined) || parts.contains(where: { similar(heard, $0) }) { return true }
        // Same stem: "fucket", "fuckin", "fucking" share "fuck".
        return heard.count >= 4 && parts.contains { $0.count >= 4 && $0.prefix(4) == heard.prefix(4) }
    }

    /// A heard word's mute span, padded.
    static func padded(_ span: ClosedRange<Double>) -> ClosedRange<Double> {
        (span.lowerBound - leadPad)...(span.upperBound + tailPad)
    }

    /// Sorted spans with near neighbours joined.
    static func merged(_ spans: [ClosedRange<Double>]) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        for span in spans.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, span.lowerBound - last.upperBound < joinGap {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                out.append(span)
            }
        }
        return out
    }

    /// Letters and digits only, lowercased: "Don't!" and "dont" compare equal.
    static func key(_ word: String) -> String {
        String(word.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// `words` without a run at its start that repeats the end of `previous`:
    /// neighbouring windows can both hear the words at their seam.
    static func droppingSeamRepeat(_ words: [SpokenWord], after previous: [SpokenWord]) -> [SpokenWord] {
        guard let first = words.first, let last = previous.last, first.start < last.end + 0.5 else { return words }
        let repeated = (1...min(4, words.count, previous.count)).last { count in
            zip(previous.suffix(count), words.prefix(count)).allSatisfy { key($0.text) == key($1.text) }
        } ?? 0
        return Array(words.dropFirst(repeated))
    }

    /// Token index to heard-word index, by longest common subsequence with a
    /// one-letter tolerance for longer words (subtitles and speech disagree on
    /// spelling, contractions and fillers).
    static func align(_ a: [String], _ b: [String]) -> [Int: Int] {
        guard !a.isEmpty, !b.isEmpty else { return [:] }
        var table = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                table[i][j] = similar(a[i], b[j])
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var pairs: [Int: Int] = [:]
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if similar(a[i], b[j]), table[i][j] == table[i + 1][j + 1] + 1 {
                pairs[i] = j
                i += 1; j += 1
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return pairs
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        guard min(a.count, b.count) >= 4, abs(a.count - b.count) <= 1 else { return false }
        return editDistance(Array(a), Array(b)) <= 1
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        var row = Array(0...b.count)
        for i in 1...a.count {
            var previous = row[0]
            row[0] = i
            for j in 1...b.count {
                let current = row[j]
                row[j] = a[i - 1] == b[j - 1] ? previous : min(previous, row[j], row[j - 1]) + 1
                previous = current
            }
        }
        return row[b.count]
    }
}

/// The words heard so far in one title, and which stretches of audio they cover.
nonisolated struct SpokenWordStore: Sendable {
    private(set) var words: [SpokenWord] = []
    /// Transcribed stretches, sorted and merged.
    private(set) var heard: [ClosedRange<Double>] = []

    /// Replace whatever was heard in `range` with `newWords`.
    mutating func add(_ newWords: [SpokenWord], covering range: ClosedRange<Double>) {
        words.removeAll { range.contains(($0.start + $0.end) / 2) }
        words.append(contentsOf: newWords)
        words.sort { $0.start < $1.start }
        var spans = heard + [range]
        spans.sort { $0.lowerBound < $1.lowerBound }
        heard = spans.reduce(into: []) { out, span in
            if let last = out.last, span.lowerBound <= last.upperBound + 0.05 {
                out[out.count - 1] = last.lowerBound...max(last.upperBound, span.upperBound)
            } else {
                out.append(span)
            }
        }
    }

    func covers(_ range: ClosedRange<Double>) -> Bool {
        heardUntil(from: range.lowerBound).map { $0 >= range.upperBound } ?? false
    }

    /// How far transcription runs on, unbroken, from `time`; nil when `time` isn't heard yet.
    func heardUntil(from time: Double) -> Double? {
        heard.first { $0.contains(time) }?.upperBound
    }

    func words(in range: ClosedRange<Double>) -> [SpokenWord] {
        words.filter { $0.end > range.lowerBound && $0.start < range.upperBound }
    }
}
