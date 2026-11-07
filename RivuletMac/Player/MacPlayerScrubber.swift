// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit
import SwiftUI

/// The progress bar. Hovering previews the position under the pointer (the server's BIF still,
/// else a frame from the file); a click or drag seeks on release and the labels follow the pointer.
struct MacPlayerScrubber: View {
    let range: ClosedRange<Double>
    let value: Double
    @Binding var scrubValue: Double?
    var scrubStill: ((Double) async -> NSImage?)?
    let onCommit: (Double) -> Void
    let onStep: (Double) -> Void

    @State private var hover: Double?
    @State private var still: NSImage?
    @State private var stillTime: Double?
    @State private var stillLoad: Task<Void, Never>?

    private var span: Double { max(range.upperBound - range.lowerBound, 0.001) }
    private var previewTime: Double? { scrubValue ?? hover }
    private var active: Bool { previewTime != nil }

    private func fraction(_ time: Double) -> Double {
        min(max((time - range.lowerBound) / span, 0), 1)
    }

    private func time(at x: CGFloat, width: CGFloat) -> Double {
        range.lowerBound + span * Double(min(max(x / max(width, 1), 0), 1))
    }

    /// A fifth of the bar, 160 to 320 pt.
    private static func stillWidth(for barWidth: CGFloat) -> CGFloat { min(max(160, barWidth * 0.2), 320) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let shown = scrubValue ?? value
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.28)).frame(height: active ? 7 : 4)
                Capsule().fill(.white).frame(width: width * fraction(shown), height: active ? 7 : 4)
                if active {
                    Circle().fill(.white).frame(width: 13, height: 13)
                        .offset(x: width * fraction(shown) - 6.5)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) { preview(width: width) }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hover = time(at: point.x, width: width)
                case .ended: hover = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { scrubValue = time(at: $0.location.x, width: width) }
                    .onEnded { drag in
                        let target = time(at: drag.location.x, width: width)
                        scrubValue = nil
                        onCommit(target)
                    }
            )
            .animation(.easeOut(duration: 0.12), value: active)
        }
        .frame(height: 20)
        .onChange(of: previewTime) { _, time in
            stillTime = time
            if time == nil { still = nil } else { loadStill() }
        }
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onStep(1)
            case .decrement: onStep(-1)
            @unknown default: break
            }
        }
    }

    @ViewBuilder
    private func preview(width: CGFloat) -> some View {
        if let time = previewTime {
            let still = still
            let stillWidth = Self.stillWidth(for: width)
            let bubbleWidth = still == nil ? 64 : stillWidth
            let height = still.map { stillWidth * $0.size.height / max($0.size.width, 1) } ?? 0
            VStack(spacing: 4) {
                if let still {
                    Image(nsImage: still)
                        .resizable()
                        .frame(width: stillWidth, height: height)
                        .clipShape(.rect(cornerRadius: 8))
                        .shadow(radius: 8)
                }
                Text(MacPlayerView.format(time))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: Capsule())
            }
            .frame(width: bubbleWidth)
            .position(x: min(max(width * fraction(time), bubbleWidth / 2), max(bubbleWidth / 2, width - bubbleWidth / 2)),
                      y: -(height + 28) / 2 - 6)
            .allowsHitTesting(false)
        }
    }

    /// Latest wins: one load at a time, then the newest position the pointer reached.
    private func loadStill() {
        guard stillLoad == nil, let scrubStill else { return }
        stillLoad = Task {
            while let time = stillTime {
                stillTime = nil
                let image = await scrubStill(time)
                if previewTime != nil, let image { still = image }
            }
            stillLoad = nil
        }
    }
}
