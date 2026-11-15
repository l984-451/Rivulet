import XCTest
@testable import Rivulet

final class SubtitleDelayTests: XCTestCase {
    func test_roundedDelay_roundsAndClampsToMax() {
        XCTAssertEqual(SubtitleAdjustments.roundedDelay(0.1 + 0.2), 0.3)
        XCTAssertEqual(SubtitleAdjustments.roundedDelay(15.1), SubtitleAdjustments.maxDelay)
        XCTAssertEqual(SubtitleAdjustments.roundedDelay(-40), -SubtitleAdjustments.maxDelay)
    }

    func test_storedDelayBeyondMax_readsClamped() {
        let key = "test:subtitle-delay-clamp"
        defer { SubtitleAdjustments.setDelay(0, forKey: key) }
        SubtitleAdjustments.setDelay(42, forKey: key)
        XCTAssertEqual(SubtitleAdjustments.delay(forKey: key), SubtitleAdjustments.maxDelay)
    }
}
