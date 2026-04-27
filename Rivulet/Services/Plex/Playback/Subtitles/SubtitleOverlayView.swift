//
//  SubtitleOverlayView.swift
//  Rivulet
//
//  SwiftUI overlay view for rendering subtitles.
//

import SwiftUI
import CoreGraphics

/// Overlay view that displays current subtitle cues
struct SubtitleOverlayView: View {
    @ObservedObject var subtitleManager: SubtitleManager

    /// Vertical offset from bottom (for player controls)
    var bottomOffset: CGFloat = 100

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Bitmap subtitle cues (PGS, DVB-SUB) — positioned absolutely
                ForEach(subtitleManager.currentBitmapCues) { cue in
                    ForEach(Array(cue.rects.enumerated()), id: \.offset) { _, rect in
                        BitmapSubtitleRectView(
                            rect: rect,
                            viewSize: geometry.size,
                            referenceWidth: cue.referenceWidth,
                            referenceHeight: cue.referenceHeight
                        )
                    }
                }

                // Text subtitle cues — anchored to bottom
                VStack {
                    Spacer()

                    if !subtitleManager.currentCues.isEmpty {
                        VStack(spacing: 4) {
                            ForEach(subtitleManager.currentCues) { cue in
                                SubtitleTextView(text: cue.text)
                            }
                        }
                        .padding(.horizontal, 60)
                        .padding(.bottom, bottomOffset)
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
        }
        .allowsHitTesting(false)  // Don't interfere with player controls
    }
}

/// Individual subtitle text with styling
private struct SubtitleTextView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: subtitleFontSize, weight: .medium))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineLimit(4)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.75))
            )
            .shadow(color: .black.opacity(0.5), radius: 4, x: 0, y: 2)
    }

    private var subtitleFontSize: CGFloat {
        return 42
    }
}

/// Renders a single bitmap subtitle rect as a CGImage, positioned in video coordinates
private struct BitmapSubtitleRectView: View {
    let rect: BitmapSubtitleRect
    let viewSize: CGSize
    /// Codec-reported reference resolution that the rect coordinates are authored
    /// against. 0 means the codec didn't report it; fall back to the HD spec
    /// (1920×1080), which matches Blu-ray PGS authoring.
    let referenceWidth: Int
    let referenceHeight: Int

    var body: some View {
        if let image = createImage() {
            let refW: CGFloat = referenceWidth > 0 ? CGFloat(referenceWidth) : 1920
            let refH: CGFloat = referenceHeight > 0 ? CGFloat(referenceHeight) : 1080
            let scaleX = viewSize.width / refW
            let scaleY = viewSize.height / refH
            let scaledWidth = CGFloat(rect.width) * scaleX
            let scaledHeight = CGFloat(rect.height) * scaleY
            let scaledX = CGFloat(rect.x) * scaleX
            let scaledY = CGFloat(rect.y) * scaleY

            Image(decorative: image, scale: 1.0)
                .resizable()
                .frame(width: scaledWidth, height: scaledHeight)
                .position(x: scaledX + scaledWidth / 2, y: scaledY + scaledHeight / 2)
        }
    }

    private func createImage() -> CGImage? {
        let width = rect.width
        let height = rect.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        let expectedSize = height * bytesPerRow
        guard rect.imageData.count >= expectedSize else { return nil }

        return rect.imageData.withUnsafeBytes { rawBuf -> CGImage? in
            guard let baseAddress = rawBuf.baseAddress else { return nil }

            guard let provider = CGDataProvider(data: rect.imageData as CFData) else { return nil }

            return CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        }
    }
}

// MARK: - Preview

#Preview {
    ZStack {
        Color.gray

        SubtitleOverlayView(
            subtitleManager: {
                let manager = SubtitleManager()
                // Note: In real usage, cues come from parsed subtitle file
                return manager
            }()
        )
    }
}
