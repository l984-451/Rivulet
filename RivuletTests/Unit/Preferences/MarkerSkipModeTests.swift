import XCTest
@testable import Rivulet

final class MarkerSkipModeTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "MarkerSkipModeTests")
        defaults.removePersistentDomain(forName: "MarkerSkipModeTests")
    }

    func testNothingStoredMeansButton() {
        XCTAssertEqual(MarkerSkipMode.current(for: "intro", defaults: defaults), .manual)
    }

    func testOldAutoSkipToggleReadsAsAutomatic() {
        defaults.set(true, forKey: "autoSkipAds")
        XCTAssertEqual(MarkerSkipMode.current(for: "commercial", defaults: defaults), .automatic)
    }

    func testRoundTripsEveryMode() {
        for mode in MarkerSkipMode.allCases {
            MarkerSkipMode.set(mode, for: "credits", defaults: defaults)
            XCTAssertEqual(MarkerSkipMode.current(for: "credits", defaults: defaults), mode)
        }
        XCTAssertEqual(MarkerSkipMode.current(for: "recap", defaults: defaults), .manual)
    }
}
