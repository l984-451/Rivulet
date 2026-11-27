// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Picture Position is a tvOS feature, so its display text lives with the tvOS app
/// and its strings in the tvOS catalog only.
extension PicturePosition {
    var title: String {
        switch self {
        case .center: String(localized: "picturePosition.center", defaultValue: "Center")
        case .top: String(localized: "picturePosition.top", defaultValue: "Top")
        case .bottom: String(localized: "picturePosition.bottom", defaultValue: "Bottom")
        }
    }
}
