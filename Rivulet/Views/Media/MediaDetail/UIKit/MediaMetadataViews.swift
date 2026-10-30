// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// Content-sized, leading-aligned rows. Unlike a horizontal stack, this view
/// measures each item at the available width and grows vertically when it wraps.
class MediaMetadataFlowView: UIView {
    var itemSpacing: CGFloat = 10
    var rowSpacing: CGFloat = 10
    private var items: [UIView] = []
    private var measuredWidth: CGFloat = 0

    func setItems(_ views: [UIView]) {
        items.forEach { $0.removeFromSuperview() }
        items = views
        views.forEach { addSubview($0) }
        isHidden = views.isEmpty
        invalidateIntrinsicContentSize()
        setNeedsLayout()
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: arrangement(width: bounds.width > 0 ? bounds.width : 860).height)
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        arrangement(width: size.width > 0 && size.width.isFinite ? size.width : 860)
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize,
        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        sizeThatFits(targetSize)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if measuredWidth != bounds.width {
            measuredWidth = bounds.width
            invalidateIntrinsicContentSize()
        }
        _ = arrangement(width: bounds.width, place: true)
    }

    private func arrangement(width: CGFloat, place: Bool = false) -> CGSize {
        guard width > 0, !items.isEmpty else { return .zero }
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var usedWidth: CGFloat = 0
        for item in items where !item.isHidden {
            let natural = item.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            let itemWidth = min(width, ceil(natural.width))
            let fitted = item.systemLayoutSizeFitting(
                CGSize(width: itemWidth, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            let itemHeight = ceil(fitted.height)
            if x > 0, x + itemWidth > width {
                y += rowHeight + rowSpacing
                x = 0
                rowHeight = 0
            }
            if place {
                let originX = effectiveUserInterfaceLayoutDirection == .rightToLeft ? width - x - itemWidth : x
                item.frame = CGRect(x: originX, y: y, width: itemWidth, height: itemHeight)
            }
            usedWidth = max(usedWidth, x + itemWidth)
            rowHeight = max(rowHeight, itemHeight)
            x += itemWidth + itemSpacing
        }
        return CGSize(width: usedWidth, height: y + rowHeight)
    }
}

/// One source, one score. Native names and display values remain authoritative;
/// unknown plugins get a neutral review symbol and their actual name, not a logo.
final class MediaRatingChipView: UIView {
    init(rating: MediaRating) {
        super.init(frame: .zero)
        backgroundColor = UIColor.white.withAlphaComponent(0.075)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous

        let mark = UIImageView()
        mark.contentMode = .scaleAspectFit
        mark.translatesAutoresizingMaskIntoConstraints = false
        var needsInlineName = false
        switch rating.source {
        case .imdb:
            mark.image = UIImage(named: "RatingIMDb")
            mark.tintColor = UIColor(red: 0.96, green: 0.78, blue: 0.25, alpha: 1)
        case .rottenTomatoes, .rottenTomatoesAudience:
            if let status = rating.rottenTomatoesStatus {
                mark.image = UIImage(named: status.imageName)?.withRenderingMode(.alwaysOriginal)
                accessibilityValue = status.name
            }
        case .letterboxd:
            mark.image = UIImage(named: "RatingLetterboxd")
            mark.tintColor = UIColor(red: 0.25, green: 0.83, blue: 0.53, alpha: 1)
        case .metacritic:
            mark.image = UIImage(named: "RatingMetacritic")
            mark.tintColor = UIColor(red: 0.56, green: 0.82, blue: 0.31, alpha: 1)
        case .tmdb:
            mark.image = UIImage(named: "RatingTMDB")
            mark.tintColor = UIColor(red: 0.12, green: 0.8, blue: 0.7, alpha: 1)
        case .unknown:
            switch rating.nativeDisplay?.sourceID.lowercased() {
            case "trakt":
                mark.image = UIImage(named: "RatingTrakt")
                mark.tintColor = .systemRed
            case "kinopoisk":
                mark.image = UIImage(named: "RatingKinopoisk")
                mark.tintColor = .systemOrange
            case "tvdb", "thetvdb":
                needsInlineName = true
                mark.image = UIImage(systemName: "tv.fill")
                mark.tintColor = .systemGreen
            default:
                needsInlineName = true
                mark.image = UIImage(systemName: "star.bubble.fill")
                mark.tintColor = UIColor.white.withAlphaComponent(0.65)
            }
        }
        let score = UILabel()
        score.font = .systemFont(ofSize: 20, weight: .bold)
        score.textColor = .white
        score.numberOfLines = 1
        let value = NSMutableAttributedString(string: rating.badgeText)
        if let scale = rating.scale {
            value.append(NSAttributedString(string: scale, attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: UIColor.white.withAlphaComponent(0.6),
            ]))
        }
        score.attributedText = value
        let row = UIStackView(arrangedSubviews: [mark])
        if needsInlineName {
            let source = UILabel()
            source.text = rating.name
            source.font = .systemFont(ofSize: 14, weight: .semibold)
            source.textColor = UIColor.white.withAlphaComponent(0.65)
            source.widthAnchor.constraint(lessThanOrEqualToConstant: 122).isActive = true
            row.addArrangedSubview(source)
        }
        row.addArrangedSubview(score)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.alignment = .center
        row.spacing = 7
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            row.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            mark.widthAnchor.constraint(equalToConstant: 28),
            mark.heightAnchor.constraint(equalToConstant: 24),
            score.widthAnchor.constraint(lessThanOrEqualToConstant: 178),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "\(rating.name), \(rating.badgeText)\(rating.scale ?? "")"
        accessibilityIdentifier = "rating.\(rating.nativeDisplay?.sourceID ?? String(rating.source.rawValue))"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Source capabilities, not negotiated output. Details are attached to their
/// owning format (DV | P7 MEL, TrueHD | 7.1), never inferred from another label.
final class MediaCapabilityBadgesView: UIStackView {
    enum Style {
        case summary
        case standard
        case technical
    }

    private let heading = UILabel()
    private let flow = MediaMetadataFlowView()

    init() {
        super.init(frame: .zero)
        axis = .vertical
        alignment = .fill
        spacing = 7
        heading.text = "SOURCE FILE"
        heading.font = .systemFont(ofSize: 13, weight: .bold)
        heading.textColor = UIColor.white.withAlphaComponent(0.5)
        addArrangedSubview(heading)
        addArrangedSubview(flow)
        isHidden = true
        accessibilityIdentifier = "media.sourceCapabilities"
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    func configure(source: MediaSource?, style: Style, includesAccessibility: Bool = false) {
        var badges: [UIView] = []
        func append(_ title: String, detail: String? = nil, filled: Bool = false, spoken: String? = nil) {
            badges.append(MediaCapabilityBadgeView(title: title, detail: detail, filled: filled, spoken: spoken))
        }
        let detailed = style == .technical
        heading.isHidden = !detailed
        if let source {
            if let resolution = source.resolutionBadge, style != .summary || resolution == "4K" {
                append(resolution, filled: true)
            }
            if let video = source.videoTracks.first {
                if detailed, !video.codec.isEmpty, video.codec.lowercased() != "unknown" {
                    append(video.codec.uppercased())
                }
                switch video.videoRange {
                case .dolbyVision(let profile):
                    var detail = detailed && profile > 0 ? "P\(profile)" : nil
                    if detailed, let layer = video.dolbyVisionEnhancementLayer?.uppercased(), ["FEL", "MEL"].contains(layer) {
                        detail = [detail, layer].compactMap { $0 }.joined(separator: " ")
                    }
                    append("DV", detail: detail, spoken: "Dolby Vision\(detail.map { " \($0)" } ?? "")")
                case .hdr10Plus: append("HDR10+")
                case .hdr10: append("HDR10")
                case .hdr: append("HDR")
                case .hlg: append("HLG")
                case .sdr: if detailed { append("SDR") }
                case .unknown: break
                }
                if video.hasHDR10Plus, video.videoRange != .hdr10Plus { append("HDR10+") }
            }
            let audio = source.audioTracks.first(where: { $0.isSelected })
                ?? source.audioTracks.first(where: { $0.isDefault }) ?? source.audioTracks.first
            if let audio {
                if style != .summary {
                    if !audio.codec.isEmpty, audio.codec.lowercased() != "unknown" {
                        append(audio.codecLabel, detail: audio.channelLayoutLabel)
                    } else if let channels = audio.channelLayoutLabel {
                        append(channels, spoken: "\(channels) channels")
                    }
                }
                if audio.isAtmos { append("Atmos", spoken: "Dolby Atmos") }
                if style == .summary, audio.codecLabel == "DTS-X" { append("DTS:X") }
            }
            if includesAccessibility {
                if source.subtitleTracks.contains(where: { $0.isHearingImpaired }) { append("SDH") }
                if source.audioTracks.contains(where: {
                    ($0.title ?? $0.extendedTitle ?? "").localizedCaseInsensitiveContains("descri")
                }) { append("AD") }
            }
        }
        flow.setItems(badges)
        isHidden = badges.isEmpty
    }
}

private final class MediaCapabilityBadgeView: UIView {
    init(title: String, detail: String?, filled: Bool, spoken: String?) {
        super.init(frame: .zero)
        layer.cornerRadius = 6
        layer.cornerCurve = .continuous
        layer.borderWidth = filled ? 0 : 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.32).cgColor
        backgroundColor = filled ? UIColor.white.withAlphaComponent(0.88) : UIColor.white.withAlphaComponent(0.035)
        let row = UIStackView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.alignment = .fill
        row.spacing = 0
        func segment(_ text: String, primary: Bool) -> UIView {
            let label = UILabel()
            label.text = text
            label.font = .systemFont(ofSize: 18, weight: primary ? .bold : .medium)
            label.textColor = filled ? UIColor.black.withAlphaComponent(0.85) : UIColor.white.withAlphaComponent(primary ? 0.9 : 0.7)
            label.numberOfLines = 1
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            let inset = UIView()
            inset.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: 9),
                label.trailingAnchor.constraint(equalTo: inset.trailingAnchor, constant: -9),
                label.topAnchor.constraint(equalTo: inset.topAnchor, constant: 5),
                label.bottomAnchor.constraint(equalTo: inset.bottomAnchor, constant: -5),
            ])
            return inset
        }
        row.addArrangedSubview(segment(title, primary: true))
        if let detail, !detail.isEmpty {
            let divider = UIView()
            divider.backgroundColor = UIColor.white.withAlphaComponent(0.23)
            divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
            row.addArrangedSubview(divider)
            row.addArrangedSubview(segment(detail, primary: false))
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityLabel = "Source file: \(spoken ?? ([title, detail].compactMap { $0 }.joined(separator: ", ")))"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
