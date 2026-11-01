// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  Generated subtitles: how heard words are grouped into caption lines, and
//  how words heard twice at a window seam are dropped.
//

import XCTest
@testable import Rivulet

final class SpeechCaptionsTests: XCTestCase {

    /// Words spoken back to back from `start`, 0.3 s each.
    private func words(_ text: String, from start: Double) -> [SpokenWord] {
        text.split(separator: " ").enumerated().map { index, word in
            let at = start + Double(index) * 0.3
            return SpokenWord(text: String(word), start: at, end: at + 0.25, confidence: 1)
        }
    }

    func testAPauseStartsANewLine() {
        let lines = SpeechCaptions.lines(from: words("Come here.", from: 10) + words("No.", from: 12))
        XCTAssertEqual(lines.map(\.text), ["Come here.", "No."])
        XCTAssertEqual(lines[0].start, 10)
        // Held past the last word, but off before the next line.
        XCTAssertEqual(lines[0].end, 10.3 + 0.25 + SpeechCaptions.hold, accuracy: 0.001)
    }

    func testAShortPauseMidSentenceKeepsTheLine() {
        let lines = SpeechCaptions.lines(from: words("Whoa, this", from: 0) + words("is a rejection letter.", from: 1.4))
        XCTAssertEqual(lines.map(\.text), ["Whoa, this is a rejection letter."])
    }

    func testTitlesDoNotEndASentence() {
        let lines = SpeechCaptions.lines(from: words("I'm gonna be a serious writer, Mr. Blackley.", from: 0))
        XCTAssertEqual(lines.count, 1)
    }

    func testShortSentencesShareALine() {
        let lines = SpeechCaptions.lines(from: words("Yeah. No worries, man.", from: 0))
        XCTAssertEqual(lines.map(\.text), ["Yeah. No worries, man."])
    }

    func testAFinishedSentenceEndsALongLine() {
        let lines = SpeechCaptions.lines(from: words("I read her articles all the time. Articles, Miss Phelan?", from: 0))
        XCTAssertEqual(lines.map(\.text), ["I read her articles all the time.", "Articles, Miss Phelan?"])
    }

    func testAFullLineCarriesItsUnfinishedClause() {
        let text = "Then read these letters and answer them just like she would, nobody is going to know the difference"
        let lines = SpeechCaptions.lines(from: words(text, from: 0))
        XCTAssertGreaterThan(lines.count, 1)
        XCTAssertTrue(lines[0].text.hasSuffix("would,"), lines[0].text)
        XCTAssertTrue(lines[1].text.hasPrefix("nobody"), lines[1].text)
        XCTAssertTrue(lines.allSatisfy { $0.text.count <= SpeechCaptions.maxChars + 1 })
    }

    func testLongLinesWrapInTheMiddle() {
        let text = SpeechCaptions.wrapped("I guarantee you one day they're going to figure out cigarettes")
        XCTAssertEqual(text, "I guarantee you one day they're\ngoing to figure out cigarettes")
        XCTAssertEqual(SpeechCaptions.wrapped("Shut the door."), "Shut the door.")
    }

    func testASeamRepeatIsDropped() {
        let previous = words("answer them just like she would.", from: 0)
        let next = words("like she would. Nobody", from: 1.6)
        XCTAssertEqual(SpokenWordAlignment.droppingSeamRepeat(next, after: previous).map(\.text), ["Nobody"])
        // The same words said again later are speech, not a seam.
        let later = words("like she would.", from: 4)
        XCTAssertEqual(SpokenWordAlignment.droppingSeamRepeat(later, after: previous).count, 3)
    }
}
