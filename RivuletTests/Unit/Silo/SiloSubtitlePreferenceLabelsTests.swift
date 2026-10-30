import XCTest
@testable import Rivulet

/// The Silo settings rows must read like Silo's own: the profile's resolved
/// value is what "Follow Silo" means, and the local options keep Silo's names.
final class SiloSubtitlePreferenceLabelsTests: XCTestCase {
    func testModeRowNamesSiloBehaviorAndItsResolvedValue() {
        XCTAssertEqual(SiloSubtitlePreferenceLabels.modeOptions(resolved: .always).map(\.1),
                       ["Follow Silo · Always on", "Auto", "Always on", "Off", "Clear"])
        XCTAssertEqual(SiloSubtitlePreferenceLabels.modeOptions(resolved: nil).map(\.1),
                       ["Follow Silo", "Auto", "Always on", "Off", "Clear"])
        XCTAssertEqual(SiloSubtitlePreferenceLabels.modeOptions(resolved: .always).map(\.0),
                       [.inherit, .value(.auto), .value(.always), .value(.off), .clear])
    }

    func testForcedRowFollowsTheProfileAndKeepsOnOffClear() {
        XCTAssertEqual(SiloSubtitlePreferenceLabels.forcedOptions(resolved: true).map(\.1),
                       ["Follow Silo · On", "On", "Off", "Clear"])
        XCTAssertEqual(SiloSubtitlePreferenceLabels.forcedOptions(resolved: false).map(\.1),
                       ["Follow Silo · Off", "On", "Off", "Clear"])
        XCTAssertEqual(SiloSubtitlePreferenceLabels.forcedOptions(resolved: nil).map(\.0),
                       [.inherit, .value(true), .value(false), .clear])
    }

    func testLanguageRowPrefersTheProfileUntilOverridden() {
        XCTAssertEqual(SiloSubtitlePreferenceLabels.languageValue(override: .inherit, resolved: nil), "Follow Silo")
        XCTAssertEqual(SiloSubtitlePreferenceLabels.languageValue(override: .clear, resolved: "nl"), "None")
        XCTAssertEqual(SiloSubtitlePreferenceLabels.languageValue(override: .value("nl"), resolved: "en"),
                       SiloSubtitlePreferenceLabels.languageName("nl"))
        // A contract tag becomes a localized name; an unknown tag stays itself.
        XCTAssertNotEqual(SiloSubtitlePreferenceLabels.languageName("nl"), "nl")
        XCTAssertEqual(SiloSubtitlePreferenceLabels.languageName("qqq"), "qqq")
    }
}
