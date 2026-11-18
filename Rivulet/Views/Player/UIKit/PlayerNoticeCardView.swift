// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlayerNoticeCardView.swift
//  Rivulet
//
//  A passing note in the player's top right, in the Up Next card's glass and type.
//  Not focusable, and hidden whenever it shows nothing, so it never occludes a focus item.
//

import UIKit

final class PlayerNoticeCardView: UIView {

    private enum Metrics {
        static let width: CGFloat = 560
        static let padding: CGFloat = 28
        static let cornerRadius: CGFloat = 32
        static let iconSize: CGFloat = 34
        /// How far right of its resting place the card starts and ends.
        static let slide: CGFloat = 48
    }

    private let glass = makePaneGlass(cornerRadius: Metrics.cornerRadius)
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private var isShown = false

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isHidden = true
        alpha = 0

        iconView.tintColor = UIColor.white.withAlphaComponent(0.9)
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: Metrics.iconSize, weight: .semibold)
        iconView.contentMode = .center
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .systemFont(ofSize: 28, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 2
        detailLabel.font = .systemFont(ofSize: 22)
        detailLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        detailLabel.numberOfLines = 3
        applyChromeTextShadow([titleLabel, detailLabel])

        let text = UIStackView(arrangedSubviews: [titleLabel, detailLabel])
        text.axis = .vertical
        text.spacing = 6
        let row = UIStackView(arrangedSubviews: [iconView, text])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 20

        [glass, row].forEach {
            addSubview($0)
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Metrics.width),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.padding),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Metrics.padding),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.padding),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Metrics.padding),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.iconSize + 8),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Slides in with `notice`, swaps the text in place while shown, slides out on nil.
    func show(_ notice: PlaybackNotice?) {
        guard let notice else { return hide() }
        iconView.image = UIImage(systemName: notice.symbol)
        titleLabel.text = notice.title
        detailLabel.text = notice.detail
        detailLabel.isHidden = notice.detail == nil
        guard !isShown else { return }
        isShown = true
        // Mid-fade it turns back from where it is; from hidden it starts off to the right.
        if isHidden {
            isHidden = false
            transform = CGAffineTransform(translationX: Metrics.slide, y: 0)
        }
        UIView.animate(withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0,
                       options: .beginFromCurrentState) {
            self.alpha = 1
            self.transform = .identity
        }
    }

    private func hide() {
        guard isShown else { return }
        isShown = false
        UIView.animate(withDuration: 0.35, delay: 0, options: [.curveEaseIn, .beginFromCurrentState], animations: {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: Metrics.slide, y: 0)
        }, completion: { _ in
            if !self.isShown { self.isHidden = true }
        })
    }
}
