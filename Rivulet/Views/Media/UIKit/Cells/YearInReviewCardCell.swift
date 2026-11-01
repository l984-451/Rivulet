// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  YearInReviewCardCell.swift
//  Rivulet
//
//  Home's Year in Review banner: "Your 2026" on the welcome R, blurred into
//  moving color. The color moves only while the card is focused.
//

import UIKit
import TVUIKit

@MainActor
final class YearInReviewCardCell: UICollectionViewCell {
    static let reuseID = "YearInReviewCardCell"

    private static let tile = MediaRowMetrics.yearInReview
    private static let restingRim = UIColor(white: 1, alpha: 0.03).cgColor

    private let card = TVCardView()
    private let glow = WelcomeGlowView(style: .blurred)
    /// Darkens the leading side under the text.
    private let scrim = GradientView(.axial, from: CGPoint(x: 0, y: 0.5), to: CGPoint(x: 0.7, y: 0.5),
                                     alphas: [0.45, 0], locations: nil)
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    // Matches ContinueWatchingCell: TVCardView resets its platter to the system radius on focus.
    private let cornerRadius: CGFloat = {
        if #available(tvOS 27, *) { return 20 }
        return 12
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = false
        clipsToBounds = false

        let host = Self.tile.hostSize
        card.translatesAutoresizingMaskIntoConstraints = false
        card.contentSize = host
        contentView.addSubview(card)

        glow.isAnimating = false

        titleLabel.font = .systemFont(ofSize: 120, weight: .heavy)
        titleLabel.textColor = .white
        subtitleLabel.font = .systemFont(ofSize: 36, weight: .semibold)
        subtitleLabel.textColor = UIColor(white: 1, alpha: 0.85)
        subtitleLabel.text = "See what you watched this year"
        let text = UIStackView(arrangedSubviews: [titleLabel, subtitleLabel])
        text.axis = .vertical
        text.spacing = 10

        for view in [glow, scrim, text] as [UIView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            card.contentView.addSubview(view)
        }
        card.contentView.layer.borderColor = Self.restingRim

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: host.width),
            card.heightAnchor.constraint(equalToConstant: host.height),
            glow.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            glow.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            glow.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            glow.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            scrim.topAnchor.constraint(equalTo: card.contentView.topAnchor),
            scrim.bottomAnchor.constraint(equalTo: card.contentView.bottomAnchor),
            scrim.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: card.contentView.trailingAnchor),
            text.leadingAnchor.constraint(equalTo: card.contentView.leadingAnchor, constant: 80),
            text.centerYAnchor.constraint(equalTo: card.contentView.centerYAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(year: Int) {
        titleLabel.text = "Your \(year)"
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext,
                                 with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self || context.nextFocusedView?.isDescendant(of: self) == true
        coordinator.addCoordinatedAnimations({
            self.card.transform = focused ? Self.tile.focusScale : .identity
        }, completion: nil)
        card.contentView.layer.borderColor = focused ? UIColor.clear.cgColor : Self.restingRim
        glow.isAnimating = focused
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        card.contentView.layer.cornerRadius = cornerRadius
        card.contentView.layer.cornerCurve = .continuous
        card.contentView.clipsToBounds = true
        card.contentView.layer.borderWidth = 1
        CATransaction.commit()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        glow.isAnimating = false
    }
}
