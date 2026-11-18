import XCTest
@testable import Rivulet

final class IPTVErrorCaptureTests: XCTestCase {
    func test_dispatcharrServerRefusals_areNotCaptured() {
        XCTAssertFalse(IPTVProvider.shouldCaptureEPGError(DispatcharrError.unauthorized))
        XCTAssertFalse(IPTVProvider.shouldCaptureEPGError(DispatcharrError.notFound))
        XCTAssertFalse(IPTVProvider.shouldCaptureEPGError(DispatcharrError.serverError(502)))
    }

    func test_unexpectedError_isStillCaptured() {
        struct Boom: Error {}
        XCTAssertTrue(IPTVProvider.shouldCaptureEPGError(Boom()))
    }
}
