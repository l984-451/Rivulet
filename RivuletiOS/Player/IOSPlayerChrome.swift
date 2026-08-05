// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI
import UIKit

/// Touch adaptation of tvOS `PlayerRailView`. The assets, glass treatment,
/// metadata hierarchy and progress colours stay shared visually; only the
/// focus-only transport interactions are replaced with explicit touch targets.
struct IOSPlayerGlassRail<Controls: View>: View {
    let eyebrow: String?
    let title: String
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isSeekable: Bool
    var centerControl: AnyView? = nil
    var progressLeadingLabel: String? = nil
    var progressTrailingLabel: String? = nil
    let compact: Bool
    let onSeek: (TimeInterval) -> Void
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 17) {
            if compact {
                GeometryReader { geometry in
                    ZStack {
                        HStack(alignment: .center, spacing: 8) {
                            metadataBlock
                                .frame(
                                    width: max(0, geometry.size.width / 2 - 30),
                                    alignment: .leading
                                )
                                .layoutPriority(0)
                            Spacer(minLength: 0)
                            controls()
                                .fixedSize(horizontal: true, vertical: false)
                                .layoutPriority(1)
                        }
                        if let centerControl {
                            centerControl
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .frame(height: 44)
            } else {
                HStack(alignment: .center, spacing: 28) {
                    metadataBlock
                    Spacer(minLength: 12)
                    HStack(spacing: 14) {
                        controls()
                    }
                }
            }

            if duration > 0 {
                IOSPlayerProgressScrubber(
                    currentTime: currentTime,
                    duration: duration,
                    isSeekable: isSeekable,
                    leadingLabel: progressLeadingLabel,
                    trailingLabel: progressTrailingLabel,
                    onSeek: onSeek
                )
            }
        }
        .padding(.horizontal, compact ? 8 : 28)
        .padding(.vertical, compact ? 14 : 22)
        .background {
            ZStack {
                railShape.fill(.ultraThinMaterial)
                railShape.fill(
                    Color(red: 18 / 255, green: 20 / 255, blue: 26 / 255)
                        .opacity(0.50)
                )
            }
        }
        .overlay { railShape.stroke(.white.opacity(0.10), lineWidth: 1) }
        .shadow(color: .black.opacity(0.60), radius: compact ? 22 : 35, y: compact ? 10 : 15)
    }

    private var railShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: compact ? 24 : 32, style: .continuous)
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 5) {
            if let eyebrow, !eyebrow.isEmpty {
                Text(eyebrow)
                    .font(.system(size: compact ? 13 : 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
            }

            Text(title)
                .font(.system(size: compact ? 20 : 28, weight: .bold))
                .foregroundStyle(.white)
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(compact ? 0.62 : 0.8)
                .allowsTightening(true)

        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct IOSPlayerControlButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    var compact = true
    var dense = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: dense ? 16 : (compact ? 18 : 22), weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .frame(width: diameter, height: diameter)
                .foregroundStyle(prominent ? Color.black : Color.white)
                .background(
                    prominent ? Color.white : Color.white.opacity(0.10),
                    in: Circle()
                )
                .overlay {
                    if !prominent {
                        Circle().stroke(.white.opacity(0.10), lineWidth: 1)
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.42 : 1)
        .accessibilityLabel(title)
    }

    private var diameter: CGFloat { dense ? 36 : (compact ? 44 : 58) }
}

private struct IOSPlayerProgressScrubber: View {
    let currentTime: TimeInterval
    let duration: TimeInterval
    let isSeekable: Bool
    let leadingLabel: String?
    let trailingLabel: String?
    let onSeek: (TimeInterval) -> Void

    @State private var dragFraction: CGFloat?

    private var progress: CGFloat {
        if let dragFraction { return dragFraction }
        guard duration > 0 else { return 0 }
        return min(max(currentTime / duration, 0), 1)
    }

    var body: some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                let width = max(0, geometry.size.width * progress)

                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16))
                    Capsule()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: Color(red: 0x7f / 255, green: 0xb8 / 255, blue: 0xff / 255), location: 0),
                                    .init(color: Color(red: 0xb9 / 255, green: 0xa3 / 255, blue: 0xff / 255), location: 0.45),
                                    .init(color: Color(red: 0xff / 255, green: 0xce / 255, blue: 0x93 / 255), location: 0.80),
                                    .init(color: Color(red: 0x8f / 255, green: 0xe9 / 255, blue: 0xd4 / 255), location: 1)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: width)

                    Circle()
                        .fill(.white)
                        .frame(width: isSeekable ? 12 : 8, height: isSeekable ? 12 : 8)
                        .overlay { Circle().stroke(.white.opacity(0.14), lineWidth: 4) }
                        .offset(x: min(max(0, width - (isSeekable ? 6 : 4)), max(0, geometry.size.width - (isSeekable ? 12 : 8))))
                }
                .frame(height: isSeekable ? 8 : 6)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard isSeekable, geometry.size.width > 0 else { return }
                            dragFraction = min(max(value.location.x / geometry.size.width, 0), 1)
                        }
                        .onEnded { value in
                            guard isSeekable, geometry.size.width > 0 else { return }
                            let fraction = min(max(value.location.x / geometry.size.width, 0), 1)
                            dragFraction = nil
                            onSeek(duration * fraction)
                        }
                )
                .accessibilityElement()
                .accessibilityLabel("Playback position")
                .accessibilityValue("\(Self.format(currentTime)) of \(Self.format(duration))")
            }
            .frame(height: 18)

            HStack {
                Text(leadingLabel ?? Self.format(currentTime))
                Spacer()
                Text(trailingLabel ?? "−\(Self.format(max(0, duration - currentTime)))")
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.68))
        }
    }

    private static func format(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

enum IOSPlayerChromeCoordinateSpace {
    static let name = "ios-player-chrome"
}

struct IOSPlayerRailTopPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat? = nil

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        guard let next = nextValue() else { return }
        value = min(value ?? next, next)
    }
}

/// UIKit recognizers provide reliable single-vs-double-tap arbitration and
/// retain the touch location, which SwiftUI's simple `onTapGesture(count:)`
/// does not expose. The player controls are layered above this surface.
struct IOSPlayerTapSurface: UIViewRepresentable {
    let onSingleTap: () -> Void
    let onDoubleTapLeft: () -> Void
    let onDoubleTapRight: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onSingleTap: onSingleTap,
            onDoubleTapLeft: onDoubleTapLeft,
            onDoubleTapRight: onDoubleTapRight
        )
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let singleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.singleTap)
        )
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.doubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        singleTap.require(toFail: doubleTap)
        view.addGestureRecognizer(singleTap)
        view.addGestureRecognizer(doubleTap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onDoubleTapLeft = onDoubleTapLeft
        context.coordinator.onDoubleTapRight = onDoubleTapRight
    }

    final class Coordinator: NSObject {
        var onSingleTap: () -> Void
        var onDoubleTapLeft: () -> Void
        var onDoubleTapRight: () -> Void

        init(
            onSingleTap: @escaping () -> Void,
            onDoubleTapLeft: @escaping () -> Void,
            onDoubleTapRight: @escaping () -> Void
        ) {
            self.onSingleTap = onSingleTap
            self.onDoubleTapLeft = onDoubleTapLeft
            self.onDoubleTapRight = onDoubleTapRight
        }

        @objc func singleTap() {
            onSingleTap()
        }

        @objc func doubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            let location = recognizer.location(in: view)
            if location.x < view.bounds.midX {
                onDoubleTapLeft()
            } else {
                onDoubleTapRight()
            }
        }
    }
}
