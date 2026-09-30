import XCTest
@testable import Rivulet

final class LibassRendererTests: XCTestCase {

    /// The app links the LibassBuild release it pins. A mismatch means the
    /// package resolved to a different build than Package.resolved says.
    func test_linkedLibassIsTheV0175Release() {
        XCTAssertEqual(LibassRenderer.libraryVersion, 0x01705000)
    }
}
