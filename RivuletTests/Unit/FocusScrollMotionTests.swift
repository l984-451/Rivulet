import XCTest
@testable import Rivulet

final class FocusScrollMotionTests: XCTestCase {
    func test_minimalOffset_keepsEdgeInsetAndOnlyMovesWhenNeeded() {
        let row = CGRect(x: 0, y: 1500, width: 260, height: 430)
        XCTAssertEqual(FocusScrollMotion.minimalOffset(revealing: row, from: 0, height: 1080), 1500 + 430 - 1080 + 180)
        XCTAssertEqual(FocusScrollMotion.minimalOffset(revealing: row, from: 1100, height: 1080), 1100)
        XCTAssertEqual(FocusScrollMotion.minimalOffset(revealing: row, from: 2000, height: 1080), 1500 - 180)
    }
}
