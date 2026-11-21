// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The loading pill for iPhone, iPad and Mac, laid over the main window's top edge while
//  a large load runs. Follows `LoadingActivity.text`. tvOS: `LoadingPillView` (UIKit).

import SwiftUI

@available(iOS 26, macOS 26, tvOS 26, *)
struct LoadingPill: View {
    @ObservedObject private var activity = LoadingActivity.shared

    var body: some View {
        ZStack {
            if let text = activity.text {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: text)
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
                .transition(.opacity.combined(with: .move(edge: .top)))
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.3), value: activity.text == nil)
        .allowsHitTesting(false)
    }
}
