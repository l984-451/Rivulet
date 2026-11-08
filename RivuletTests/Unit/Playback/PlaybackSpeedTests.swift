import XCTest
@testable import Rivulet

final class PlaybackSpeedTests: XCTestCase {

    func testOffersAVKitSetUpToTheVideoCap() {
        XCTAssertEqual(PlaybackSpeed.choices(maxRate: 2), [0.5, 1, 1.25, 1.5, 2])
        XCTAssertEqual(PlaybackSpeed.choices(maxRate: 3), [0.5, 1, 1.25, 1.5, 2])
    }

    func testDropsSpeedsAboveTheCap() {
        XCTAssertEqual(PlaybackSpeed.choices(maxRate: 1.5), [0.5, 1, 1.25, 1.5])
        XCTAssertEqual(PlaybackSpeed.choices(maxRate: 1.3), [0.5, 1, 1.25])
    }

    func testHidesWhenOnlyNormalSpeedIsLeft() {
        XCTAssertEqual(PlaybackSpeed.choices(maxRate: 1), [])
        XCTAssertEqual(PlaybackSpeed.choices(maxRate: 0), [])
    }

    func testLabelUsesTheLocaleNumberFormat() {
        XCTAssertEqual(PlaybackSpeed.label(1.25, locale: Locale(identifier: "en_US")), "1.25×")
        XCTAssertEqual(PlaybackSpeed.label(1, locale: Locale(identifier: "en_US")), "1×")
        XCTAssertEqual(PlaybackSpeed.label(0.5, locale: Locale(identifier: "en_US")), "0.5×")
        XCTAssertEqual(PlaybackSpeed.label(1.5, locale: Locale(identifier: "de_DE")), "1,5×")
    }

    func testConvertsBetweenMediaAndWallTime() {
        XCTAssertEqual(PlaybackSpeed.wallSeconds(forMedia: 10, at: 2), 5, accuracy: 1e-9)
        XCTAssertEqual(PlaybackSpeed.wallSeconds(forMedia: 10, at: 0.5), 20, accuracy: 1e-9)
        XCTAssertEqual(PlaybackSpeed.mediaSeconds(forWall: 10, at: 1.5), 15, accuracy: 1e-9)
        // A paused rate never divides by zero.
        XCTAssertEqual(PlaybackSpeed.wallSeconds(forMedia: 10, at: 0), 10, accuracy: 1e-9)
    }
}
