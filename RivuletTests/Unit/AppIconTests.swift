// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import XCTest
import UIKit
@testable import Rivulet

@MainActor
final class AppIconTests: XCTestCase {

    /// tvOS reads `CFBundleAlternateIcons` as an array of image stack names; the iOS
    /// dictionary form is what App Store Connect rejected (ITMS-90471). Also catches a
    /// renamed asset or a dropped Info.plist entry.
    func testInfoPlistDeclaresEveryAlternateAsATVOSArray() throws {
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String],
                                       "CFBundleAlternateIcons must be an array of strings on tvOS")
        XCTAssertEqual(Set(alternates), Set(AppIcon.allCases.compactMap(\.assetName)))
        XCTAssertEqual(icons["CFBundlePrimaryIcon"] as? String, "App Icon")
    }
}
