// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Testing
import UIKit
@testable import Rivulet

@Suite("PlayerProgressBarView marker coloring")
struct PlayerProgressBarViewTests {
    private func color(_ type: String) -> UIColor {
        PlayerProgressBarView.color(for: PlexMarker(type: type, startTimeOffset: 0, endTimeOffset: 30000))
    }

    @Test("intro, credits and ads each get their own tint")
    func markerKindsAreDistinct() {
        let colors = ["intro", "credits", "commercial"].map(color)
        #expect(Set(colors).count == 3)
    }

    @Test("marker tints are translucent, not solid system colors")
    func markerTintsAreSoft() {
        for type in ["intro", "credits", "commercial"] {
            var alpha: CGFloat = 0
            color(type).getRed(nil, green: nil, blue: nil, alpha: &alpha)
            #expect(alpha < 1)
        }
    }
}
