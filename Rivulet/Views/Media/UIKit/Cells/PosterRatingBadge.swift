// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// The focused poster's score (Settings > Appearance > Rating > Show on Focused Poster),
// set straight onto the artwork with no shape of its own. It lives on `PosterCell`'s art overlay,
// so it tilts, shifts and catches the sheen with the poster. A soft corner shade keeps white type
// readable on bright art. Metrics measured on an Apple TV 4K (tvOS 27.2) against 4K screenshots.

import UIKit

@MainActor
final class PosterRatingBadge: UIView {
    private static let valueFont = UIFont.monospacedDigitSystemFont(ofSize: 18, weight: .semibold)
    /// Same size and weight as the value, dimmed: a lighter weight read as smaller and floating.
    private static let sourceFont = UIFont.systemFont(ofSize: 18, weight: .semibold)
    /// Visible artwork edge to the type's ink, top and side alike: the poster's corner radius,
    /// so the type starts where the corner's curve ends.
    static let inset: CGFloat = 20
    /// Each emoji gets the ink area of an SF Symbol circle at small scale beside this text
    /// (1.088 cap heights across), so the narrow popcorn and the round tomato weigh the same.
    private static let emojiArea = pow(1.088 * valueFont.capHeight, 2) * .pi / 4
    /// Round art (about as wide as tall: the tomato, the nauseated face) still reads smaller than
    /// the popcorn at the same ink area, so it grows by this much.
    private static let roundGrow: CGFloat = 3
    /// Ink-to-ink gap between the emoji and the first digit.
    private static let emojiGap: CGFloat = 6.25
    /// The first digit's left side bearing, part of the emoji gap.
    private static let leadingBearing: CGFloat = 1.22

    /// Top trailing by default; top leading when the watched pill holds the trailing corner.
    enum Corner { case topTrailing, topLeading }
    private(set) var corner = Corner.topTrailing

    private let shade = CAGradientLayer()
    private let label = UILabel()
    private var topInset: NSLayoutConstraint?
    private var trailingPin: NSLayoutConstraint!
    private var leadingPin: NSLayoutConstraint!
    private var fadeAnimator: UIViewPropertyAnimator?

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        isHidden = true
        alpha = 0

        shade.type = .radial
        // Eased falloff: no visible edge on flat art.
        let stops: [CGFloat] = [0.52, 0.45, 0.33, 0.19, 0.08, 0.02, 0]
        shade.colors = stops.map { UIColor(white: 0, alpha: $0).cgColor }
        shade.locations = [0, 0.18, 0.36, 0.54, 0.72, 0.88, 1]
        layer.addSublayer(shade)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 1
        // The watched glyph's shadow (`WatchedGlyphView`): on near-white art it is what carries the
        // type's edge, with the shade doing the rest.
        label.layer.shadowColor = UIColor.black.cgColor
        label.layer.shadowOpacity = 0.5
        label.layer.shadowRadius = 3
        label.layer.shadowOffset = CGSize(width: 0, height: 1)
        addSubview(label)

        // Cap height on the top inset; the outer glyph's ink, not its advance, on the side one.
        let top = label.firstBaselineAnchor.constraint(equalTo: topAnchor)
        topInset = top
        setTopClearance(0)
        // Aligned to the pinned side: the label rounds its width up, and the slack goes inward.
        label.textAlignment = .right
        trailingPin = label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Self.inset)
        leadingPin = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.inset)
        NSLayoutConstraint.activate([top, trailingPin])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ rating: MediaRating) {
        let text = Self.text(rating)
        label.attributedText = text
        // The outer glyphs' own side bearings ("I" and "1" have wide ones, an emoji has none), so
        // the ink lands on the inset exactly.
        let bounds = CGSize(width: CGFloat.greatestFiniteMagnitude, height: 100)
        let ink = text.boundingRect(with: bounds, options: [.usesLineFragmentOrigin, .usesDeviceMetrics], context: nil)
        let advance = text.boundingRect(with: bounds, options: .usesLineFragmentOrigin, context: nil)
        leadingPin.constant = Self.inset - max(0, ink.minX)
        trailingPin.constant = -(Self.inset - max(0, advance.maxX - ink.maxX))
        setNeedsLayout()
    }

    /// The type's width, so the caller can tell whether it clears the server and edition badges.
    var typeWidth: CGFloat { label.intrinsicContentSize.width }

    func setCorner(_ corner: Corner) {
        self.corner = corner
        trailingPin.isActive = corner == .topTrailing
        leadingPin.isActive = corner == .topLeading
        label.textAlignment = corner == .topTrailing ? .right : .left
        setNeedsLayout()
    }

    /// Room above the type, so it clears the watched pill or the server badges when they show.
    func setTopClearance(_ clearance: CGFloat) {
        topInset?.constant = max(Self.inset, clearance) + Self.valueFont.capHeight
    }

    /// The badge's text (tests); equals `MediaRating.posterLine`.
    var text: String? {
        guard let text = label.attributedText else { return nil }
        var out = ""
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attrs, range, _ in
            if let emoji = attrs[Self.emojiKey] as? String { out += emoji } else {
                out += (text.string as NSString).substring(with: range)
            }
        }
        return out
    }

    // MARK: - Fade

    /// Fade lengths, judged on device. In uses a slow start: white type on dark art reads fully
    /// at a third of its opacity, so a curve that front-loads the change looks like a pop.
    private static let fadeIn: TimeInterval = 0.4
    private static let fadeInCurve = (CGPoint(x: 0.42, y: 0), CGPoint(x: 0.58, y: 1))
    private static let fadeOut: TimeInterval = 0.12

    /// A fade is running (the unfocus clean-up lets it finish).
    var isFading: Bool { fadeAnimator?.isRunning == true }

    /// On: shown at once. Off: gone at once (reuse, settings change, stale focus).
    func setMaterialized(_ on: Bool) {
        fadeAnimator?.stopAnimation(true)
        fadeAnimator = nil
        alpha = on ? 1 : 0
        if !on { isHidden = true }
    }

    /// Fades with the focus change. The system's focus moves run 60 to 80 ms here, far shorter
    /// than either fade, so the fades run on their own clock from the same moment. The next move
    /// picks up from wherever the last one got to.
    func fade(in on: Bool) {
        fadeAnimator?.stopAnimation(true)
        if on { isHidden = false }
        let animator = on
            ? UIViewPropertyAnimator(duration: Self.fadeIn, controlPoint1: Self.fadeInCurve.0,
                                     controlPoint2: Self.fadeInCurve.1) { self.alpha = 1 }
            : UIViewPropertyAnimator(duration: Self.fadeOut, curve: .easeIn) { self.alpha = 0 }
        animator.addCompletion { [weak self] position in
            if position == .end, !on { self?.isHidden = true }
        }
        animator.startAnimation()
        fadeAnimator = animator
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // An ellipse centred on the type's corner, reaching well past the type.
        let text = label.frame.insetBy(dx: -Self.inset, dy: -Self.inset)
        let ry = text.maxY + 34
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        switch corner {
        case .topTrailing:
            let rx = bounds.maxX - text.minX + 44
            shade.frame = CGRect(x: bounds.maxX - rx, y: -ry, width: rx * 2, height: ry * 2)
        case .topLeading:
            let rx = text.maxX + 44
            shade.frame = CGRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2)
        }
        shade.startPoint = CGPoint(x: 0.5, y: 0.5)
        shade.endPoint = CGPoint(x: 1, y: 1)
        CATransaction.commit()
    }

    // MARK: - Text

    private static let emojiKey = NSAttributedString.Key("rivulet.posterRating.emoji")

    /// Lead (the RT emoji, or the source name dimmed), then the value in full white.
    private static func text(_ rating: MediaRating) -> NSAttributedString {
        let text = NSMutableAttributedString()
        if let emoji = rating.glyph, let glyph = emojiGlyph(emoji) {
            let attachment = NSTextAttachment(image: glyph.image)
            // The ink's centre of mass on the digits' cap midline: the popcorn's narrow base and the
            // tomato's thin leaf would throw a box-centred glyph off by most of a point.
            let size = glyph.image.size
            attachment.bounds = CGRect(x: 0, y: valueFont.capHeight / 2 - glyph.centroid * size.height,
                                       width: size.width, height: size.height)
            let lead = NSMutableAttributedString(attachment: attachment)
            lead.addAttribute(emojiKey, value: emoji, range: NSRange(location: 0, length: lead.length))
            text.append(lead)
            // A label ignores kern on an attachment, so the gap is a space tightened to size.
            let space = (" " as NSString).size(withAttributes: [.font: valueFont]).width
            text.append(NSAttributedString(string: " ", attributes: [
                .font: valueFont, .kern: emojiGap - space - leadingBearing
            ]))
        } else {
            text.append(NSAttributedString(string: rating.posterLead + " ", attributes: [
                .font: sourceFont, .foregroundColor: UIColor(white: 1, alpha: 0.75)
            ]))
        }
        text.append(NSAttributedString(string: rating.badgeText, attributes: [
            .font: valueFont, .foregroundColor: UIColor.white
        ]))
        return text
    }

    private static var glyphCache: [String: (image: UIImage, centroid: CGFloat)] = [:]

    /// The emoji's art trimmed to its visible ink, sized to `emojiArea` square points of ink (plus
    /// `roundGrow` for round art), with its ink centroid as a fraction of the height from the
    /// bottom. The font pads and shapes each emoji differently, so its font size alone leaves them
    /// uneven against the number.
    static func emojiGlyph(_ emoji: String) -> (image: UIImage, centroid: CGFloat)? {
        if let cached = glyphCache[emoji] { return cached }
        let font = UIFont.systemFont(ofSize: 64)
        let glyph = emoji as NSString
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let drawn = UIGraphicsImageRenderer(size: glyph.size(withAttributes: [.font: font]), format: format).image { _ in
            glyph.draw(at: .zero, withAttributes: [.font: font])
        }
        guard let cg = drawn.cgImage, let ink = inkBounds(cg), let trimmed = cg.cropping(to: ink.rect) else { return nil }
        // Coverage in drawn points squared, then the scale that brings it to `emojiArea`.
        let scale = (emojiArea / (ink.coverage / (format.scale * format.scale))).squareRoot()
        var size = CGSize(width: ink.rect.width / format.scale * scale, height: ink.rect.height / format.scale * scale)
        if size.width >= size.height * 0.9 {
            size = CGSize(width: size.width * (size.height + roundGrow) / size.height, height: size.height + roundGrow)
        }
        // Drawn at its final size, sharp on a 4K panel at the focus zoom.
        let out = UIGraphicsImageRendererFormat()
        out.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: out).image { _ in
            UIImage(cgImage: trimmed).draw(in: CGRect(origin: .zero, size: size))
        }
        let result = (image, 1 - (ink.centroidY - ink.rect.minY) / ink.rect.height)
        glyphCache[emoji] = result
        return result
    }

    /// Pixel bounds of everything not (nearly) transparent, the summed alpha in pixels, and the
    /// alpha-weighted centre row (top-down, like the bounds).
    private static func inkBounds(_ image: CGImage) -> (rect: CGRect, coverage: CGFloat, centroidY: CGFloat)? {
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        var minX = w, minY = h, maxX = -1, maxY = -1, coverage = 0, weightedY = 0
        for y in 0..<h {
            for x in 0..<w {
                let alpha = Int(pixels[(y * w + x) * 4 + 3])
                coverage += alpha
                weightedY += alpha * y
                if alpha > 20 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return (CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), CGFloat(coverage) / 255,
                CGFloat(weightedY) / CGFloat(max(coverage, 1)) + 0.5)
    }
}
