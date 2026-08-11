// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CastCell.swift
//  Rivulet
//
//  A cast/crew member: circular photo over a name + subtitle (role /
//  "Director"). Replaced the SwiftUI `PersonCard`, since deleted.
//
//  Focus treatment is ENLARGE-ONLY: the avatar scales up on focus, nothing else
//  (no ring, no glow — a TVCardView's rectangular card can't be round, and the
//  ring/glow read as clutter). `MediaPerson.imageURL` is already fully-qualified
//  by the mapper, so no server/token threading.
//

import UIKit

final class CastCell: UIView {

    static let circleSize: CGFloat = 263

    /// Scale host for the focus enlarge.
    private let glowView = UIView()
    /// Circular, clips the image to the circle.
    private let imageContainer = UIView()
    private let imageView = UIImageView()
    private let fallbackIcon = UIImageView()
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

        // Scale host for the focus enlarge.
        glowView.translatesAutoresizingMaskIntoConstraints = false
        glowView.clipsToBounds = false
        addSubview(glowView)

        imageContainer.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.clipsToBounds = true
        imageContainer.backgroundColor = UIColor(white: 0.15, alpha: 1)
        imageContainer.layer.cornerRadius = Self.circleSize / 2
        imageContainer.layer.borderWidth = 1
        imageContainer.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        glowView.addSubview(imageContainer)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageContainer.addSubview(imageView)

        fallbackIcon.translatesAutoresizingMaskIntoConstraints = false
        fallbackIcon.image = UIImage(systemName: "person.fill")
        fallbackIcon.tintColor = UIColor.white.withAlphaComponent(0.3)
        fallbackIcon.contentMode = .center
        fallbackIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 60, weight: .light)
        imageContainer.addSubview(fallbackIcon)

        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.font = .systemFont(ofSize: 27, weight: .semibold)
        nameLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        nameLabel.numberOfLines = 1
        nameLabel.textAlignment = .center
        addSubview(nameLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 22, weight: .medium)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        subtitleLabel.numberOfLines = 1
        subtitleLabel.textAlignment = .center
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            glowView.topAnchor.constraint(equalTo: topAnchor),
            // Circle LEADING-aligned to the cell edge (= the shared content edge),
            // like the episode/trailer thumbnails — NOT centered in the cell.
            glowView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glowView.widthAnchor.constraint(equalToConstant: Self.circleSize),
            glowView.heightAnchor.constraint(equalToConstant: Self.circleSize),

            imageContainer.topAnchor.constraint(equalTo: glowView.topAnchor),
            imageContainer.leadingAnchor.constraint(equalTo: glowView.leadingAnchor),
            imageContainer.trailingAnchor.constraint(equalTo: glowView.trailingAnchor),
            imageContainer.bottomAnchor.constraint(equalTo: glowView.bottomAnchor),

            imageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            imageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            imageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),

            fallbackIcon.centerXAnchor.constraint(equalTo: imageContainer.centerXAnchor),
            fallbackIcon.centerYAnchor.constraint(equalTo: imageContainer.centerYAnchor),

            // Names centered UNDER the circle (the circle is leading-aligned, so
            // labels can overflow into the inter-item gap — that's intended).
            nameLabel.topAnchor.constraint(equalTo: glowView.bottomAnchor, constant: 14),
            nameLabel.centerXAnchor.constraint(equalTo: glowView.centerXAnchor),
            nameLabel.widthAnchor.constraint(equalToConstant: Self.circleSize + 56),

            subtitleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 4),
            subtitleLabel.centerXAnchor.constraint(equalTo: glowView.centerXAnchor),
            subtitleLabel.widthAnchor.constraint(equalToConstant: Self.circleSize + 56),
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
        imageView.image = nil
        fallbackIcon.isHidden = false
        guard let imageURL else { return }
        Task { [weak self] in
            let image = await ImageCacheManager.shared.image(for: imageURL)
            await MainActor.run {
                guard let self, self.imageToken == token, let image else { return }
                self.imageView.image = image
                self.fallbackIcon.isHidden = true
            }
        }
    }

    /// Focus = ENLARGE only (no ring, no glow).
    func setFocused(_ focused: Bool) {
        glowView.transform = focused ? CGAffineTransform(scaleX: 1.14, y: 1.14) : .identity
    }
}
