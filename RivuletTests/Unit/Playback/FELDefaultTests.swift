import XCTest
@testable import Rivulet

@MainActor
final class FELDefaultTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        defaults = UserDefaults(suiteName: "FELDefaultTests")
        defaults.removePersistentDomain(forName: "FELDefaultTests")
    }

    func test_existingInstall_untouched_keepsFELOn() {
        AetherPlayer.settleFELDefault(existingInstall: true, defaults: defaults)
        XCTAssertTrue(defaults.bool(forKey: AetherPlayer.dolbyVisionFELKey))
    }

    func test_existingInstall_explicitOff_staysOff() {
        defaults.set(false, forKey: AetherPlayer.dolbyVisionFELKey)
        AetherPlayer.settleFELDefault(existingInstall: true, defaults: defaults)
        XCTAssertFalse(defaults.bool(forKey: AetherPlayer.dolbyVisionFELKey))
    }

    func test_newInstall_staysOff_evenAfterSigningIn() {
        AetherPlayer.settleFELDefault(existingInstall: false, defaults: defaults)
        AetherPlayer.settleFELDefault(existingInstall: true, defaults: defaults)
        XCTAssertNil(defaults.object(forKey: AetherPlayer.dolbyVisionFELKey))
    }
}
