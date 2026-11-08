import XCTest
@testable import Rivulet

final class ShortEditionTests: XCTestCase {
    func test_trimsFillerAfterStandaloneWord() {
        XCTAssertEqual(MediaItem.shortEdition("Extended Edition"), "Extended")
        XCTAssertEqual(MediaItem.shortEdition("Theatrical Cut"), "Theatrical")
        XCTAssertEqual(MediaItem.shortEdition("ultimate version"), "ultimate")
    }

    func test_keepsNamesWhereTheLastWordMatters() {
        XCTAssertEqual(MediaItem.shortEdition("Director's Cut"), "Director's Cut")
        XCTAssertEqual(MediaItem.shortEdition("Final Cut"), "Final Cut")
        XCTAssertEqual(MediaItem.shortEdition("Special Edition"), "Special Edition")
        XCTAssertEqual(MediaItem.shortEdition("25th Anniversary Edition"), "25th Anniversary Edition")
    }

    func test_emptyIsNil() {
        XCTAssertNil(MediaItem.shortEdition(nil))
        XCTAssertNil(MediaItem.shortEdition("  "))
    }
}
