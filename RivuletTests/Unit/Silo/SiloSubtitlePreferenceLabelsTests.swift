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

    func testLanguageOptionsIncludeISOAndPreserveServerVariantsAndOverride() {
        let options = SiloSubtitlePreferenceLabels.languageOptions(
            additional: ["eng", "pt-BR", "pt_PT", "PT-br", "x-custom"], current: "fre"
        )
        XCTAssertTrue(options.contains("sw"))
        XCTAssertTrue(options.contains("eng"))
        XCTAssertFalse(options.contains("en"))
        XCTAssertTrue(options.contains("fre"))
        XCTAssertFalse(options.contains("fr"))
        XCTAssertTrue(options.contains("pt-BR"))
        XCTAssertTrue(options.contains("pt_PT"))
        XCTAssertFalse(options.contains("PT-br"))
        XCTAssertTrue(options.contains("x-custom"))
        XCTAssertEqual(Set(options.map(SiloSubtitlePreferenceLabels.languageKey)).count, options.count)
        let names = options.map(SiloSubtitlePreferenceLabels.languageName)
        for (left, right) in zip(names, names.dropFirst()) {
            XCTAssertNotEqual(left.localizedStandardCompare(right), .orderedDescending)
        }
    }

    func testLanguageOptionsDoNotDependOnServerOptions() {
        let options = SiloSubtitlePreferenceLabels.languageOptions(additional: [])
        XCTAssertTrue(options.contains("en"))
        XCTAssertTrue(options.contains("sw"))
        XCTAssertTrue(options.contains("zu"))
        XCTAssertEqual(SiloSubtitlePreferenceLabels.languageKey("eng_US"),
                       SiloSubtitlePreferenceLabels.languageKey("en-us"))
        XCTAssertNotEqual(SiloSubtitlePreferenceLabels.languageKey("pt-BR"),
                          SiloSubtitlePreferenceLabels.languageKey("pt-PT"))
    }
}
