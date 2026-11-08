// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  Critic excerpts in a row for the ratings popup, one card per page with the next card's edge showing.
//  `page(by:)` is driven by the popup's Left/Right (InfoPopupViewController.onHorizontalMove).

import UIKit

final class ReviewStripView: UIView {
    private static let cardWidth: CGFloat = 500
    private static let gap: CGFloat = 20

    private let track = UIStackView()
    private var trackLeading: NSLayoutConstraint!
    private let count: Int
    private var index = 0

    init(_ reviews: [CriticReview]) {
        count = reviews.count
        super.init(frame: .zero)
        trackLeading = track.leadingAnchor.constraint(equalTo: leadingAnchor)
        clipsToBounds = true
        track.axis = .horizontal
        track.alignment = .fill
        track.spacing = Self.gap
        track.translatesAutoresizingMaskIntoConstraints = false
        addSubview(track)
        NSLayoutConstraint.activate([
            trackLeading,
            track.topAnchor.constraint(equalTo: topAnchor),
            track.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        reviews.forEach { track.addArrangedSubview(Self.card($0)) }
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func page(by step: Int) {
        let next = min(max(index + step, 0), count - 1)
        guard next != index else { return }
        index = next
        trackLeading.constant = -CGFloat(index) * (Self.cardWidth + Self.gap)
        UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseInOut) { self.layoutIfNeeded() }
    }

    private static func card(_ review: CriticReview) -> UIView {
        let header = UIStackView()
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 8
        if let verdict = review.verdict {
            let mark = UIImageView(image: UIImage(systemName: verdict.symbol))
            mark.tintColor = verdict == .fresh ? .systemGreen : .systemRed
            mark.contentMode = .scaleAspectFit
            mark.isAccessibilityElement = true
            mark.accessibilityLabel = verdict.label
            mark.setContentHuggingPriority(.required, for: .horizontal)
            header.addArrangedSubview(mark)
        }
        if let byline = review.byline {
            let name = UILabel()
            name.font = .systemFont(ofSize: 22, weight: .semibold)
            name.textColor = .white
            name.text = byline
            header.addArrangedSubview(name)
        }

        let excerpt = UILabel()
        excerpt.font = .systemFont(ofSize: 22, weight: .regular)
        excerpt.textColor = UIColor.white.withAlphaComponent(0.85)
        excerpt.numberOfLines = 4
        excerpt.text = review.excerpt

        let body = UIStackView(arrangedSubviews: [header, excerpt])
        body.axis = .vertical
        body.spacing = 10
        body.translatesAutoresizingMaskIntoConstraints = false

        let card = UIView()
        card.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        card.layer.cornerRadius = 20
        card.layer.cornerCurve = .continuous
        card.addSubview(body)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: cardWidth),
            body.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            body.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            body.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            body.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -18),
        ])
        return card
    }
}
