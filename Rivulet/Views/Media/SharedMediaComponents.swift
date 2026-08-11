// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SharedMediaComponents.swift
//  Rivulet
//
//  Small shared SwiftUI helpers used across the surviving SwiftUI surfaces
//  (Music, post-video overlays). Extracted from the retired
//  MediaPosterCard.swift when the SwiftUI poster/row/grid views were removed
//  in favor of their UIKit equivalents.
//

import SwiftUI

// MARK: - Card Button Style (tvOS - minimal, no focus ring)

/// A minimal button style that removes the default tvOS focus ring.
/// Hover effect is applied directly to the artwork inside the card.
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .brightness(configuration.isPressed ? -0.05 : 0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}
