// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// Stock app background: neutral charcoal vignette softly illuminated in the
/// centre and darker at every edge. Used in Settings, Guide, and programme detail.
public struct GuideDefaultBackdrop: View {
    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.045)
                RadialGradient(
                    stops: [
                        .init(color: Color(white: 0.145), location: 0),
                        .init(color: Color(white: 0.105), location: 0.52),
                        .init(color: Color(white: 0.055), location: 1)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: hypot(geometry.size.width, geometry.size.height) * 0.62
                )
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.12), location: 0),
                        .init(color: .clear, location: 0.38),
                        .init(color: .black.opacity(0.18), location: 1)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}
