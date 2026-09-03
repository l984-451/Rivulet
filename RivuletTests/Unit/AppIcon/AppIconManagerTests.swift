// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class AppIconManagerTests: XCTestCase {

    private let key = AppIconManager.storageKey
    private var savedValue: Any?

    override func setUp() {
        super.setUp()
        savedValue = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    override func tearDown() {
        if let savedValue {
            UserDefaults.standard.set(savedValue, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testAppIconOptionCases() {
        XCTAssertEqual(AppIconOption.allCases.map(\.rawValue), ["default", "simple-dark", "simple-light", "pixel"])
        XCTAssertEqual(AppIconOption.defaultIcon.title, "Default")
        XCTAssertEqual(AppIconOption.simpleDark.title, "Simple (Dark)")
        XCTAssertEqual(AppIconOption.simpleLight.title, "Simple (Light)")
        XCTAssertEqual(AppIconOption.pixel.title, "Pixel")
    }

    func testAppIconOptionAlternateNames() {
        XCTAssertNil(AppIconOption.defaultIcon.alternateIconName)
        XCTAssertEqual(AppIconOption.simpleDark.alternateIconName, "AppIconSimpleDark")
        XCTAssertEqual(AppIconOption.simpleLight.alternateIconName, "AppIconSimpleLight")
        XCTAssertEqual(AppIconOption.pixel.alternateIconName, "AppIconPixel")
    }

    func testAppIconSettingAndNotification() {
        var received: AppIconOption?
        let observer = NotificationCenter.default.addObserver(
            forName: AppIconManager.didChangeNotification,
            object: nil,
            queue: .main
        ) { notification in
            received = notification.object as? AppIconOption
        }

        AppIconManager.shared.setIcon(.pixel)

        XCTAssertEqual(AppIconManager.shared.currentIcon, .pixel)
        XCTAssertEqual(UserDefaults.standard.string(forKey: key), "pixel")
        XCTAssertEqual(received, .pixel)

        NotificationCenter.default.removeObserver(observer)
    }
}
