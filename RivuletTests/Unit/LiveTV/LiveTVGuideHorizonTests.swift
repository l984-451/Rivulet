import XCTest
@testable import Rivulet

final class LiveTVGuideHorizonTests: XCTestCase {
    func test_horizonIsNearUntilLiveTVAppears() {
        XCTAssertEqual(LiveTVDataStore.fillHorizonHours(liveTVScreenSeen: false), 24)
        XCTAssertEqual(LiveTVDataStore.fillHorizonHours(liveTVScreenSeen: true), LiveTVDataStore.epgMaxHoursAhead)
    }

    /// The old `contains` and the new `prefixMatch` agree on every `^`-anchored marker.
    func test_prefixMatchAgreesWithContains() {
        let live = /^\s*(?:\[live\]|\(live\)|live\s*[:|]|live\s+[-–]\s)\s*/.ignoresCase()
        let upcoming = /^\s*upcoming\s*[:|]\s*/.ignoresCase()
        let empty = /^\s*(?:no (?:game|event|match)e?s?(?: scheduled)?|off[- ]?air)\s*$/.ignoresCase()
        let titles = ["News", "UPCOMING: Jets @ Bears", " upcoming | x", "No game scheduled", "off air", "Off-Air",
                      "Live: SportsCenter", "LiveNOW from FOX", "[LIVE] x", "Live PD", "Live - x", "", "  ",
                      "  No events  ", "x Live: y", "Replay of Live: x", "no games scheduled today"]
        for title in titles {
            XCTAssertEqual(title.contains(live), title.prefixMatch(of: live) != nil, title)
            XCTAssertEqual(title.contains(upcoming), title.prefixMatch(of: upcoming) != nil, title)
            XCTAssertEqual(title.contains(empty), title.prefixMatch(of: empty) != nil, title)
        }
    }
}
