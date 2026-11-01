import XCTest
@testable import Rivulet

final class AudioSyncTests: XCTestCase {

    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "AudioSyncTests")
        defaults.removePersistentDomain(forName: "AudioSyncTests")
    }

    func testStepsBothWaysAndClampsAtEngineLimit() {
        XCTAssertEqual(AudioSync.offsetMs(defaults: defaults), 0)
        AudioSync.step(by: -5, defaults: defaults)
        XCTAssertEqual(AudioSync.offsetMs(defaults: defaults), -50)
        XCTAssertEqual(AudioSync.seconds(defaults: defaults), -0.05, accuracy: 1e-9)
        AudioSync.step(by: 1000, defaults: defaults)
        XCTAssertEqual(AudioSync.offsetMs(defaults: defaults), AudioSync.maxMs)
    }

    func testFormatting() {
        XCTAssertEqual(AudioSync.formatted(0), "0 ms")
        XCTAssertEqual(AudioSync.formatted(50), "+50 ms")
        XCTAssertEqual(AudioSync.formatted(-50), "-50 ms")
    }
}
