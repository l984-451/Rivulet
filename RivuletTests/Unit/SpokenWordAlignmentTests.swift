// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  Word-level muting: where the dictionary finds a word in a line, how a line
//  is placed on the words the speech model heard, and how audio is cut into
//  windows for the model.
//

import XCTest
@testable import Rivulet

final class LanguageMatchTests: XCTestCase {

    func testMatchesReportTheWordPosition() {
        let text = "Well, you stupid son of a bitch."
        let tokens = ProfanityDictionary.tokens(of: text)
        XCTAssertEqual(tokens, ["well", "you", "stupid", "son", "of", "a", "bitch"])
        let ranges = Set(ProfanityDictionary.matches(in: text).map(\.tokens))
        XCTAssertEqual(ranges, [3..<7, 6..<7])
    }

    func testMaskedWordsKeepTheirPosition() {
        XCTAssertEqual(ProfanityDictionary.matches(in: "Oh, f*** this").map(\.tokens), [1..<2])
    }

    func testCustomWordsAreWholeWordsAndPhrases() {
        let custom = ["stupid", "shut up"]
        XCTAssertEqual(ProfanityDictionary.matches(in: "That's STUPID!", customTerms: custom).map(\.tokens), [1..<2])
        XCTAssertTrue(ProfanityDictionary.matches(in: "Stupidity is not a crime", customTerms: custom).isEmpty)
        XCTAssertEqual(ProfanityDictionary.matches(in: "You idiots!", customTerms: ["idiot"]).map(\.tokens), [1..<2])
        XCTAssertEqual(ProfanityDictionary.matches(in: "Just shut... up.", customTerms: custom).map(\.tokens), [1..<3])
        let match = ProfanityDictionary.matches(in: "stupid", customTerms: custom)[0]
        XCTAssertTrue(match.isCustom)
        XCTAssertTrue(match.mutes(enabledCategories: [], profanityThreshold: .strong))
    }
}

final class SpokenWordAlignmentTests: XCTestCase {

    private func heard(_ words: [(String, Double)]) -> [SpokenWord] {
        words.map { SpokenWord(text: $0.0, start: $0.1, end: $0.1 + 0.3, confidence: 0.9) }
    }

    func testAMatchedWordIsMutedAlone() throws {
        let spans = try XCTUnwrap(SpokenWordAlignment.muteSpans(
            cueStart: 0, cueEnd: 3, tokens: ["what", "the", "fuck", "is", "this"], flagged: [2],
            words: heard([("what", 0.2), ("the", 0.6), ("fuck", 1.0), ("is", 1.4), ("this", 1.8)])))
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].lowerBound, 0.9, accuracy: 0.001)
        XCTAssertEqual(spans[0].upperBound, 1.45, accuracy: 0.001)
    }

    func testAMisheardWordIsPlacedBetweenItsNeighbours() throws {
        let spans = try XCTUnwrap(SpokenWordAlignment.muteSpans(
            cueStart: 0, cueEnd: 3, tokens: ["what", "the", "f", "is", "this"], flagged: [2],
            words: heard([("what", 0.2), ("the", 0.6), ("muck", 1.0), ("is", 1.4), ("this", 1.8)])))
        XCTAssertEqual(spans[0].lowerBound, 0.8, accuracy: 0.001)   // "the" ends at 0.9
        XCTAssertEqual(spans[0].upperBound, 1.55, accuracy: 0.001)  // "is" starts at 1.4
    }

    func testALineThatWasNotHeardFallsBack() {
        XCTAssertNil(SpokenWordAlignment.muteSpans(
            cueStart: 0, cueEnd: 3, tokens: ["what", "the", "fuck", "is", "this"], flagged: [2],
            words: heard([("music", 0.5), ("plays", 1.0)])))
        XCTAssertNil(SpokenWordAlignment.muteSpans(
            cueStart: 0, cueEnd: 3, tokens: ["shit"], flagged: [0], words: []))
    }

    // Cases recorded from 21 Jump Street in the simulator (source seconds).

    private func timed(_ words: [(String, Double, Double)]) -> [SpokenWord] {
        words.map { SpokenWord(text: $0.0, start: $0.1, end: $0.2, confidence: 0.9) }
    }

    func testHeardSwearIsPlacedEvenWhenTheRestOfTheLineIsMisheard() throws {
        let spans = try XCTUnwrap(SpokenWordAlignment.muteSpans(
            cueStart: 4441.81, cueEnd: 4443.44,
            tokens: ["it's", "going", "to", "explode!", "oh", "my", "god!", "roll", "up", "the", "windows!"],
            flagged: [5, 6],
            words: timed([("Let's", 4441.59, 4441.82), ("go", 4441.82, 4441.90), ("explode.", 4441.98, 4442.39),
                          ("Oh", 4442.39, 4442.47), ("my", 4442.55, 4442.62), ("god,", 4442.62, 4442.78)])))
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].lowerBound, 4442.45, accuracy: 0.001)
        XCTAssertEqual(spans[0].upperBound, 4442.93, accuracy: 0.001)
    }

    func testAMissedWordAtTheEndRunsFromItsAnchorToTheCueEnd() throws {
        let spans = try XCTUnwrap(SpokenWordAlignment.muteSpans(
            cueStart: 10, cueEnd: 13,
            tokens: ["damn", "it", "i", "told", "you", "so", "oh", "god"], flagged: [0, 6, 7],
            words: timed([("damn", 10.1, 10.4), ("it", 10.4, 10.5), ("i", 10.6, 10.7),
                          ("told", 10.7, 10.9), ("you", 10.9, 11.0), ("so", 11.0, 11.2)])))
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].upperBound, 10.55, accuracy: 0.001)   // "damn" alone
        XCTAssertEqual(spans[1].lowerBound, 11.1, accuracy: 0.001)    // "oh god", after "so"
        XCTAssertEqual(spans[1].upperBound, 12.45, accuracy: 0.001)   // 2 words + slack, before the cue end
    }

    func testAnAnchorFromTheNextLineFallsBack() {
        XCTAssertNil(SpokenWordAlignment.muteSpans(
            cueStart: 4477.39, cueEnd: 4479.23,
            tokens: ["shoot", "oh", "my", "god", "okay!", "okay!"], flagged: [2, 3],
            words: timed([("Shoot", 4479.48, 4479.81), ("the", 4479.89, 4479.97), ("gun.", 4479.97, 4480.20)])))
    }

    func testAMisspelledOrJoinedSwearIsStillFound() throws {
        let spans = try XCTUnwrap(SpokenWordAlignment.muteSpans(
            cueStart: 4444.77, cueEnd: 4445.90,
            tokens: ["i", "don't", "fucking", "care!", "just", "do", "it!", "oh", "god!"], flagged: [2],
            words: timed([("holding", 4444.24, 4444.40), ("up?", 4444.48, 4444.56), ("Fucket", 4444.96, 4445.28),
                          ("characters", 4445.28, 4445.68)])))
        XCTAssertEqual(spans[0].lowerBound, 4444.86, accuracy: 0.001)
        XCTAssertEqual(spans[0].upperBound, 4445.43, accuracy: 0.001)

        let joined = try XCTUnwrap(SpokenWordAlignment.muteSpans(
            cueStart: 10, cueEnd: 12, tokens: ["hi", "god", "damn", "you", "are", "beautiful"], flagged: [1, 2],
            words: timed([("Hi", 10.1, 10.3), ("goddamn", 10.4, 10.9), ("you're", 11.0, 11.2), ("beautiful", 11.3, 11.8)])))
        XCTAssertEqual(joined.map(\.lowerBound), [10.3])
        XCTAssertEqual(joined[0].upperBound, 11.05, accuracy: 0.001)
    }

    func testAnAnchorFromThePreviousLineIsPassedOver() throws {
        // "the" at 4230.84 belongs to the line before; "door" bounds "fuck" instead.
        let spans = try XCTUnwrap(SpokenWordAlignment.muteSpans(
            cueStart: 4231.35, cueEnd: 4233.94,
            tokens: ["oh", "fuck", "lock", "the", "door!", "lock", "the", "door!"], flagged: [1],
            words: timed([("the", 4230.84, 4230.92), ("car.", 4231.24, 4231.32), ("door.", 4233.42, 4233.58)])))
        XCTAssertGreaterThanOrEqual(spans[0].lowerBound, 4231.35 - 0.1 - 0.001)
        XCTAssertEqual(spans[0].upperBound, 4233.57, accuracy: 0.001)
    }

    func testAHeardHalfOfAPhraseAnchorsTheOtherHalf() throws {
        let spans = try XCTUnwrap(SpokenWordAlignment.muteSpans(
            cueStart: 511.83, cueEnd: 513.47, tokens: ["oh", "god"], flagged: [0, 1],
            words: timed([("Oh", 512.05, 512.13), ("yeah.", 512.29, 512.45)])))
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans[0].lowerBound, 511.95, accuracy: 0.001)
        XCTAssertEqual(spans[0].upperBound, 512.98, accuracy: 0.001)   // "oh" + one word + slack, padded
    }

    func testSpellingDifferencesStillAlign() {
        XCTAssertEqual(SpokenWordAlignment.align(["gonna", "kill", "you"], ["gona", "kill", "ya"]), [0: 0, 1: 1])
        XCTAssertEqual(SpokenWordAlignment.key("Don't!"), "dont")
    }

    func testNearSpansJoin() {
        let merged = SpokenWordAlignment.merged([2...3, 0...1, 1.2...1.5])
        XCTAssertEqual(merged, [0...1.5, 2...3])
    }

    func testStoreReplacesWhatItHearsAgain() {
        var store = SpokenWordStore()
        store.add(heard([("one", 1), ("two", 2)]), covering: 0...3)
        store.add(heard([("deux", 2)]), covering: 1.5...6)
        XCTAssertEqual(store.words.map(\.text), ["one", "deux"])
        XCTAssertTrue(store.covers(0.5...5))
        XCTAssertFalse(store.covers(0.5...7))
    }
}

final class WindowBufferTests: XCTestCase {

    func testWindowsOverlapAndReportEachStretchOnce() throws {
        var buffer = WindowBuffer(sampleRate: 10)
        let second = [Float](repeating: 0, count: 10)
        var cuts: [WindowBuffer.Cut] = []
        for index in 0..<14 {
            second.withUnsafeBufferPointer { buffer.append($0, at: 100 + Double(index), restart: index == 0) }
            while let cut = buffer.nextWindow(length: 6, context: 1) { cuts.append(cut) }
        }
        XCTAssertEqual(cuts.map(\.start), [100, 104, 108])
        XCTAssertEqual(cuts.map(\.keeps), [100...105, 105...109, 109...113])
        let rest = try XCTUnwrap(buffer.flush())
        XCTAssertEqual(rest.keeps, 113...114)
    }
}
