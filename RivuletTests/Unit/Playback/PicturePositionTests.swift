// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
import CoreGraphics
@testable import Rivulet

final class PicturePositionTests: XCTestCase {

    private let screen = CGSize(width: 1920, height: 1080)

    /// A 320x180 still: grey picture between black bars `bar` rows tall top and bottom.
    private func still(bar: Int, bottomBar: Int? = nil, level: UInt8 = 120) -> [UInt8] {
        let width = 320, height = 180
        var luma = [UInt8](repeating: 0, count: width * height)
        for row in bar..<(height - (bottomBar ?? bar)) {
            for x in 0..<width { luma[row * width + x] = level }
        }
        return luma
    }

    // MARK: Detector

    func testMeasuresScopeBars() {
        // 2.39:1 in 16:9: bars are 12.8% of the height each, 23 of 180 rows.
        let sample = LetterboxDetector.sample(luma: still(bar: 23), width: 320, height: 180)
        XCTAssertEqual(sample?.bar ?? 0, 23.0 / 180, accuracy: 0.001)
        XCTAssertEqual(sample?.aspect ?? 0, 320.0 / 180, accuracy: 0.001)
    }

    func testAllBlackStillIsNoSample() {
        XCTAssertNil(LetterboxDetector.sample(luma: still(bar: 0, level: 0), width: 320, height: 180))
    }

    func testUnequalBarsTakeTheSmaller() {
        let sample = LetterboxDetector.sample(luma: still(bar: 40, bottomBar: 23), width: 320, height: 180)
        XCTAssertEqual(sample?.bar ?? 0, 23.0 / 180, accuracy: 0.001)
    }

    func testReadingSnapsToScope() {
        let aspect: CGFloat = 16.0 / 9
        let samples = [0.13, 0.125, 0.128, 0.2, 0.13].map { LetterboxDetector.Sample(bar: $0, aspect: aspect) }
        let reading = LetterboxDetector.reading(from: samples)
        let share = aspect / 2.39
        XCTAssertEqual(reading?.picture.lowerBound ?? 0, (1 - share) / 2, accuracy: 0.0001)
        XCTAssertEqual(reading?.picture.upperBound ?? 0, (1 + share) / 2, accuracy: 0.0001)
    }

    /// Dark scenes read as taller bars; they must not win.
    func testDarkScenesDoNotInflateTheBars() {
        let aspect: CGFloat = 16.0 / 9
        let samples = [0.128, 0.128, 0.128, 0.19, 0.21, 0.2].map { LetterboxDetector.Sample(bar: $0, aspect: aspect) }
        let reading = LetterboxDetector.reading(from: samples)
        XCTAssertEqual(reading?.picture.lowerBound ?? 0, (1 - aspect / 2.39) / 2, accuracy: 0.0001)
    }

    func testFullFrameHasNoReading() {
        let samples = [0, 0.005, 0, 0.3, 0].map { LetterboxDetector.Sample(bar: $0, aspect: 16.0 / 9) }
        XCTAssertNil(LetterboxDetector.reading(from: samples))
    }

    func testTooFewStillsHasNoReading() {
        let samples = [0.128, 0.128].map { LetterboxDetector.Sample(bar: $0, aspect: 16.0 / 9) }
        XCTAssertNil(LetterboxDetector.reading(from: samples))
    }

    /// A scope film with IMAX scenes: the full-frame scenes decide, however few.
    func testTallestScenesDecideAMixedFilm() {
        let aspect: CGFloat = 16.0 / 9
        let bars: [CGFloat] = Array(repeating: 0.128, count: 40) + [0, 0.003]
        XCTAssertNil(LetterboxDetector.reading(from: bars.map { LetterboxDetector.Sample(bar: $0, aspect: aspect) }))
        // 1.90:1 scenes in a scope film: placed as 1.90:1.
        let mixed: [CGFloat] = Array(repeating: 0.128, count: 40) + [0.032, 0.034, 0.033]
        let reading = LetterboxDetector.reading(from: mixed.map { LetterboxDetector.Sample(bar: $0, aspect: aspect) })
        XCTAssertEqual(reading?.picture.lowerBound ?? 0, (1 - aspect / 1.90) / 2, accuracy: 0.0001)
    }

    /// One odd still is not a scene.
    func testOneOddStillDoesNotDecide() {
        let aspect: CGFloat = 16.0 / 9
        let bars: [CGFloat] = [0] + Array(repeating: 0.128, count: 40)
        let reading = LetterboxDetector.reading(from: bars.map { LetterboxDetector.Sample(bar: $0, aspect: aspect) })
        XCTAssertEqual(reading?.picture.lowerBound ?? 0, (1 - aspect / 2.39) / 2, accuracy: 0.0001)
    }

    /// Soft edges scatter a still or two short; the shape is still the film's.
    func testSoftEdgesDoNotShrinkTheBars() {
        let aspect: CGFloat = 16.0 / 9
        let bars: [CGFloat] = [0.122, 0.122] + Array(repeating: 0.128, count: 40)
        let reading = LetterboxDetector.reading(from: bars.map { LetterboxDetector.Sample(bar: $0, aspect: aspect) })
        XCTAssertEqual(reading?.picture.lowerBound ?? 0, (1 - aspect / 2.39) / 2, accuracy: 0.0001)
    }

    func testSampleTimesCoverTheFilm() {
        let times = LetterboxDetector.sampleTimes(duration: 6_000)
        XCTAssertEqual(times.count, 16)
        XCTAssertEqual(times.first ?? 0, 180, accuracy: 0.01)
        XCTAssertEqual(times.last ?? 0, 5_520, accuracy: 0.01)
        XCTAssertTrue(LetterboxDetector.sampleTimes(duration: 30).isEmpty)
        XCTAssertEqual(LetterboxDetector.denseSampleCount(duration: 6_000), 200)
        XCTAssertEqual(LetterboxDetector.denseSampleCount(duration: 300), 16)
        XCTAssertEqual(LetterboxDetector.denseSampleCount(duration: 30_000), 400)
    }

    // MARK: Saved readings

    @MainActor
    func testReadingsAreKeptBetweenLaunches() {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("letterbox-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let scope = LetterboxReading(frameAspect: 16.0 / 9, picture: 0.128...0.872)
        let store = LetterboxReadingStore(file: file)
        XCTAssertNil(store.reading(for: "plex:1|10"))
        store.save(scope, for: "plex:1|10")
        store.save(nil, for: "plex:2|20")

        // A new launch reads the file.
        let relaunched = LetterboxReadingStore(file: file)
        XCTAssertEqual(relaunched.reading(for: "plex:1|10"), .some(scope))
        // Measured, and no bars: known, so not measured again.
        XCTAssertEqual(relaunched.reading(for: "plex:2|20"), .some(nil))
        // Another version of the same film is its own entry.
        XCTAssertNil(relaunched.reading(for: "plex:1|11"))

        relaunched.clear()
        XCTAssertNil(LetterboxReadingStore(file: file).reading(for: "plex:1|10"))
    }

    // MARK: Layout

    /// A cropped 2.40:1 file (3840x1600): its own size says where the picture is.
    func testCroppedFileMovesToTheBottom() {
        let layout = PictureLayout.make(container: screen, videoSize: CGSize(width: 3840, height: 1600),
                                        fillsScreen: false, position: .bottom, letterbox: nil)
        XCTAssertEqual(layout.frame.height, 800, accuracy: 0.5)
        XCTAssertEqual(layout.shift, 140)
        XCTAssertEqual(layout.picture.maxY, 1080, accuracy: 0.5)
    }

    func testCroppedFileMovesToTheTop() {
        let layout = PictureLayout.make(container: screen, videoSize: CGSize(width: 3840, height: 1600),
                                        fillsScreen: false, position: .top, letterbox: nil)
        XCTAssertEqual(layout.shift, -140)
        XCTAssertEqual(layout.picture.minY, 0, accuracy: 0.5)
    }

    /// A UHD remux codes the bars: the frame fills the screen and moves by one bar,
    /// its bottom bar going off screen.
    func testRemuxMovesByItsReading() {
        let share = (16.0 / 9) / 2.39
        let reading = LetterboxReading(frameAspect: 16.0 / 9, picture: ((1 - share) / 2)...((1 + share) / 2))
        let layout = PictureLayout.make(container: screen, videoSize: CGSize(width: 3840, height: 2160),
                                        fillsScreen: false, position: .bottom, letterbox: reading)
        XCTAssertEqual(layout.shift, ((1080 - 1080 * share) / 2).rounded())
        XCTAssertEqual(layout.picture.maxY, 1080, accuracy: 1)
        XCTAssertEqual(layout.frame.maxY, 1080 + layout.shift, accuracy: 1)
    }

    func testCenterAndFullFrameDoNotMove() {
        let cropped = CGSize(width: 3840, height: 1600)
        XCTAssertEqual(PictureLayout.make(container: screen, videoSize: cropped, fillsScreen: false,
                                          position: .center, letterbox: nil).shift, 0)
        XCTAssertEqual(PictureLayout.make(container: screen, videoSize: CGSize(width: 1920, height: 1080),
                                          fillsScreen: false, position: .bottom, letterbox: nil).shift, 0)
        // Zoomed to fill, nothing is left to move into.
        XCTAssertEqual(PictureLayout.make(container: screen, videoSize: cropped, fillsScreen: true,
                                          position: .bottom, letterbox: nil).shift, 0)
    }

    /// A reading from stills of another shape (an anamorphic file's coded frame) is ignored.
    func testMismatchedReadingIsIgnored() {
        let reading = LetterboxReading(frameAspect: 16.0 / 9, picture: 0.128...0.872)
        let layout = PictureLayout.make(container: screen, videoSize: CGSize(width: 1440, height: 1080),
                                        fillsScreen: false, position: .bottom, letterbox: reading)
        XCTAssertEqual(layout.shift, 0)
    }

    func testUnknownSizeUsesTheStillsShape() {
        let layout = PictureLayout.make(container: screen, videoSize: .zero, fillsScreen: false,
                                        position: .bottom,
                                        letterbox: LetterboxReading(frameAspect: 16.0 / 9, picture: 0.128...0.872))
        XCTAssertEqual(layout.picture.maxY, 1080, accuracy: 1)
    }

    // MARK: Nudge

    /// A step is 3 points of 1080, up for positive, on top of the position's shift.
    func testNudgeMovesOnTopOfThePosition() {
        let cropped = CGSize(width: 3840, height: 1600)
        XCTAssertEqual(PictureLayout.make(container: screen, videoSize: cropped, fillsScreen: false,
                                          position: .bottom, letterbox: nil, nudge: 4).shift, 128)
        XCTAssertEqual(PictureLayout.make(container: screen, videoSize: cropped, fillsScreen: false,
                                          position: .center, letterbox: nil, nudge: -2).shift, 6)
        // A frame that was never measured still moves: that is what the nudge is for.
        XCTAssertEqual(PictureLayout.make(container: screen, videoSize: CGSize(width: 3840, height: 2160),
                                          fillsScreen: false, position: .bottom, letterbox: nil, nudge: -10).shift, 30)
    }

    func testNudgeIsLimitedAndNotAppliedWhenZoomed() {
        let cropped = CGSize(width: 3840, height: 1600)
        XCTAssertEqual(PictureLayout.make(container: screen, videoSize: cropped, fillsScreen: false,
                                          position: .center, letterbox: nil, nudge: 500).shift, -192)
        XCTAssertEqual(PictureLayout.make(container: screen, videoSize: cropped, fillsScreen: true,
                                          position: .center, letterbox: nil, nudge: 10).shift, 0)
    }

    func testNudgeIsKeptPerTitle() {
        let key = "test:nudge-\(UUID().uuidString)"
        XCTAssertEqual(PictureNudge.steps(forKey: key), 0)
        PictureNudge.setSteps(7, forKey: key)
        XCTAssertEqual(PictureNudge.steps(forKey: key), 7)
        XCTAssertEqual(PictureNudge.steps(forKey: key + "x"), 0)
        PictureNudge.setSteps(0, forKey: key)
        XCTAssertEqual(PictureNudge.steps(forKey: key), 0)
        XCTAssertEqual(PictureNudge.formatted(0), "0")
        XCTAssertEqual(PictureNudge.formatted(12), "+12")
        XCTAssertEqual(PictureNudge.formatted(-3), "-3")
    }

    func testPositionCycles() {
        XCTAssertEqual(PicturePosition.center.next, .top)
        XCTAssertEqual(PicturePosition.top.next, .bottom)
        XCTAssertEqual(PicturePosition.bottom.next, .center)
    }
}
