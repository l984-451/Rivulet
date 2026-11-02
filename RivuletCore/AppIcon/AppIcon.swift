// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import UIKit

/// The home screen icons. The system remembers the chosen one, so nothing is stored here.
@MainActor
enum AppIcon: String, CaseIterable, Identifiable {
    case standard, simpleColour, simpleWhite, pixel

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: return String(localized: "Default")
        case .simpleColour: return String(localized: "Simple Colour")
        case .simpleWhite: return String(localized: "Simple White")
        case .pixel: return String(localized: "Pixel")
        }
    }

    /// The asset catalog set; nil is the primary icon. iOS declares these in
    /// `ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES`, tvOS in its Info.plist's `CFBundleAlternateIcons`.
    var assetName: String? {
        switch self {
        case .standard: return nil
        case .simpleColour: return "AppIconSimpleColor"
        case .simpleWhite: return "AppIconSimpleWhite"
        case .pixel: return "AppIconPixel"
        }
    }

    static var current: AppIcon {
        allCases.first { $0.assetName == UIApplication.shared.alternateIconName } ?? .standard
    }

    func apply() {
        guard UIApplication.shared.alternateIconName != assetName else { return }
        UIApplication.shared.setAlternateIconName(assetName)
    }
}
