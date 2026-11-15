import XCTest
@testable import Rivulet

final class SidecarSubtitleLabelTests: XCTestCase {
    private func label(_ lang: String? = nil, _ title: String? = nil, _ path: String? = nil, _ n: Int = 7) -> String {
        SidecarSubtitleLabel.make(language: lang, title: title, path: path, fallbackNumber: n)
    }

    func test_languageCodeBecomesName() {
        XCTAssertEqual(label("fra"), Locale.current.localizedString(forLanguageCode: "fra"))
    }

    func test_filenameTagUsedWhenNoLanguage() {
        XCTAssertEqual(label(nil, "1", "/lib/Movie (2020).fr.srt"), Locale.current.localizedString(forLanguageCode: "fr"))
        XCTAssertEqual(label(nil, nil, "/lib/Movie.de.forced.srt"), Locale.current.localizedString(forLanguageCode: "de"))
    }

    func test_numberedWhenNothingElse() {
        XCTAssertEqual(label(nil, "12", "/lib/Show - S03E01 (WEBRip-1080p).12.srt"), String(localized: "Subtitle 12"))
        XCTAssertEqual(label(), String(localized: "Subtitle 7"))
    }

    func test_distinctTitleKept() {
        XCTAssertEqual(label(nil, "Director's Cut"), "Director's Cut")
    }
}
