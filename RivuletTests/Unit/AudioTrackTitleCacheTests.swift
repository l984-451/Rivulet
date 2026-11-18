import XCTest
@testable import Rivulet

final class AudioTrackTitleCacheTests: XCTestCase {
    func test_repeatedLookupsAgree() {
        let first = AudioTrackTitle.description(of: "Commentary by Sam Mendes", language: "English", languageCode: "eng")
        let second = AudioTrackTitle.description(of: "Commentary by Sam Mendes", language: "English", languageCode: "eng")
        XCTAssertEqual(first, "Commentary by Sam Mendes")
        XCTAssertEqual(first, second)
    }

    func test_nilResultIsCached() {
        XCTAssertNil(AudioTrackTitle.description(of: "English DTS-HD MA 5.1", language: "English", languageCode: "eng"))
        XCTAssertNil(AudioTrackTitle.description(of: "English DTS-HD MA 5.1", language: "English", languageCode: "eng"))
    }
}
