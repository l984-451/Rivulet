// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  A cast or crew member: circular photo over name and role. The photo is a round bitmap in an
//  image view with the system focus effect masked to it, so focus gives the same tilting glass as
//  a poster. `MediaPerson.imageURL` is already absolute.

import UIKit

final class CastCell: UIView {

    static let circleSize: CGFloat = MediaRowMetrics.gridWidth(columns: 6)
    // Name white, role 0.5 at rest and white on focus (measured on device, tvOS 27).
    private static let nameFont = UIFont.systemFont(ofSize: 31, weight: .medium)
    private static let roleFont = UIFont.systemFont(ofSize: 25, weight: .medium)
    private static let roleRestColor = UIColor.white.withAlphaComponent(0.5)

    /// Round bitmap; the system focus effect (scale, tilt, specular) is masked to its alpha.
    private let photoView = UIImageView()
    private let nameLabel = UILabel()
    private let subtitleLabel = UILabel()

    private var imageToken: UInt64 = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        commonInit()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("CastCell is not Storyboard-backed") }

    private func commonInit() {
        translatesAutoresizingMaskIntoConstraints = false

        photoView.translatesAutoresizingMaskIntoConstraints = false
        photoView.adjustsImageWhenAncestorFocused = true
        photoView.masksFocusEffectToContents = true
        photoView.image = Self.placeholder
        addSubview(photoView)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = Self.nameFont
        nameLabel.textColor = .white
        nameLabel.numberOfLines = 1
        nameLabel.lineBreakMode = .byClipping
        nameLabel.textAlignment = .center
        addSubview(nameLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = Self.roleFont
        subtitleLabel.textColor = Self.roleRestColor
        subtitleLabel.numberOfLines = 1
        subtitleLabel.lineBreakMode = .byClipping
        subtitleLabel.textAlignment = .center
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            // Circle LEADING-aligned to the cell edge, like the episode and trailer thumbnails.
            photoView.topAnchor.constraint(equalTo: topAnchor),
            photoView.leadingAnchor.constraint(equalTo: leadingAnchor),
            photoView.widthAnchor.constraint(equalToConstant: Self.circleSize),
            photoView.heightAnchor.constraint(equalToConstant: Self.circleSize),

            // Labels fill the circle's column and clip there, fading out. Circle to name cap top
            // 13.5, name to role baseline 32 (measured on device, tvOS 27).
            nameLabel.topAnchor.constraint(
                equalTo: photoView.bottomAnchor,
                constant: 13.5 - (Self.nameFont.ascender - Self.nameFont.capHeight)),
            nameLabel.leadingAnchor.constraint(equalTo: photoView.leadingAnchor),
            nameLabel.trailingAnchor.constraint(equalTo: photoView.trailingAnchor),

            subtitleLabel.topAnchor.constraint(
                equalTo: nameLabel.bottomAnchor,
                constant: 32 + Self.nameFont.descender - Self.roleFont.ascender),
            subtitleLabel.leadingAnchor.constraint(equalTo: photoView.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: photoView.trailingAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func configure(person: MediaPerson, fallbackSubtitle: String? = nil) {
        configure(name: person.name, subtitle: person.role ?? fallbackSubtitle, imageURL: person.imageURL)
    }

    func configure(name: String, subtitle: String?, imageURL: URL?) {
        nameLabel.text = name
        subtitleLabel.text = subtitle
        subtitleLabel.isHidden = (subtitle ?? "").isEmpty

        imageToken &+= 1
        let token = imageToken
        let cached = imageURL.flatMap { ImageCacheManager.shared.cachedImage(for: $0) }
        photoView.image = cached.map(Self.circular) ?? Self.placeholder
        guard let imageURL, cached == nil else { return }
        Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: imageURL)
            await MainActor.run {
                guard let self, self.imageToken == token, let image else { return }
                self.photoView.image = Self.circular(image)
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fadeIfClipped(nameLabel)
        fadeIfClipped(subtitleLabel)
    }

    /// A label wider than its column starts at the leading edge and fades out at the trailing one.
    private func fadeIfClipped(_ label: UILabel) {
        let clipped = label.intrinsicContentSize.width > label.bounds.width && label.bounds.width > 0
        label.textAlignment = clipped ? .left : .center
        guard clipped else { label.layer.mask = nil; return }
        let mask = (label.layer.mask as? CAGradientLayer) ?? CAGradientLayer()
        mask.frame = label.bounds
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        mask.colors = [UIColor.black.cgColor, UIColor.black.cgColor, UIColor.clear.cgColor]
        mask.locations = [0, NSNumber(value: 1 - 40 / label.bounds.width), 1]
        label.layer.mask = mask
    }

    /// The photo's focus effect is the system's; the role whitens and the labels drop 20 with the circle.
    func setFocused(_ focused: Bool) {
        subtitleLabel.textColor = focused ? .white : Self.roleRestColor
        let drop = focused ? CGAffineTransform(translationX: 0, y: 20) : .identity
        nameLabel.transform = drop
        subtitleLabel.transform = drop
    }

    /// Aspect-fills `image` into the circle with transparent corners, so the focus effect is round.
    private static func circular(_ image: UIImage) -> UIImage {
        let side = circleSize
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: .layeredArtwork()).image { _ in
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).addClip()
            let scale = max(side / image.size.width, side / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2,
                                  width: size.width, height: size.height))
        }
    }

    /// Dark circle with a person glyph, for people with no photo.
    private static let placeholder: UIImage = {
        let side = circleSize
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: .layeredArtwork()).image { _ in
            UIColor(white: 0.15, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: 0, y: 0, width: side, height: side)).fill()
            let config = UIImage.SymbolConfiguration(pointSize: 60, weight: .light)
            if let glyph = UIImage(systemName: "person.fill", withConfiguration: config)?
                .withTintColor(UIColor.white.withAlphaComponent(0.3), renderingMode: .alwaysOriginal) {
                glyph.draw(at: CGPoint(x: (side - glyph.size.width) / 2, y: (side - glyph.size.height) / 2))
            }
        }
    }()
}
