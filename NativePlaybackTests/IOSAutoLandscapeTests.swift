// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

#if os(iOS) || os(Linux)
import Foundation
import Testing
@testable import Rivulet_iOS

@MainActor
struct IOSAutoLandscapeTests {
    @Test(arguments: [nil, false, true] as [Bool?], [false, true])
    func onlyAnOptedInEligibleBuildRequestsLandscape(savedPreference: Bool?, isAvailable: Bool) throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if let savedPreference { defaults.set(savedPreference, forKey: IOSAutoLandscapePreference.key) }

        let shouldRotate = IOSAutoLandscapePreference.isEnabled(isAvailable: isAvailable, defaults: defaults)
        #expect(shouldRotate == (isAvailable && savedPreference == true))
    }
}
#endif
