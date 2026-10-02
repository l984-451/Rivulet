// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HubHeaderView.swift
//  Rivulet
//
//  Section headers above each home row. Two distinct styles in SwiftUI
//  that must both be supported here:
//
//   - InfiniteContentRow / ContentRow (Continue Watching, Recently Added,
//     Personalized Recommendations): 30pt semibold, foreground white-0.6,
//     with no inline count indicator.
//
//   - WatchlistHubRow: ScaledDimensions.sectionTitleSize (30pt) bold,
//     full white. No count.
//
//  Style is set per-configure via `Style.swiftUIInfiniteRow` or
//  `.swiftUIWatchlist` — the dataSource picks the right one per section.
//

import UIKit

@MainActor
final class HubHeaderView: UICollectionReusableView {
    static let reuseID = "HubHeaderView"

    enum Style {
        case swiftUIInfiniteRow
        case swiftUIWatchlist
    }

    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let badge = SourceBadgeView(style: .inline)
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        backgroundColor = .clear

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.isHidden = true

        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .lastBaseline
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(badge)
        // A long row title must squeeze the title, never the badge.
        badge.setContentCompressionResistancePriority(.required, for: .horizontal)
        badge.setContentHuggingPriority(.required, for: .horizontal)
        stack.addArrangedSubview(countLabel)
        addSubview(stack)

        NSLayoutConstraint.activate([
            // Leading 0: the section's contentInsets.leading already insets the
            // header (supplementariesFollowContentInsets defaults to true), so 0
            // here makes the title align exactly with the row's first card. A
            // non-zero value double-insets the header to the right of the cards.
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -48),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// Configure with `title`. Count parameters are accepted for call-site
    /// compatibility but row headers intentionally do not display amounts.
    /// `sourceBadge` names the row's server; nil (always set, so a reused
    /// header drops the last row's) hides it.
    func configure(title: String,
                   style: Style,
                   loadedCount: Int? = nil,
                   totalCount: Int? = nil,
                   pageSize: Int = 24,
                   sourceBadge: String? = nil) {
        switch style {
        case .swiftUIInfiniteRow:
            titleLabel.font = .systemFont(ofSize: 34, weight: .semibold)
            titleLabel.textColor = UIColor.white.withAlphaComponent(0.9)
        case .swiftUIWatchlist:
            titleLabel.font = .systemFont(ofSize: ScaledDimensions.sectionTitleSize, weight: .bold)
            titleLabel.textColor = .white
        }
        titleLabel.text = title
        badge.text = sourceBadge

        countLabel.text = nil
        countLabel.isHidden = true
    }

    /// The badge's text while it shows (tests).
    var sourceBadgeText: String? { badge.isHidden ? nil : badge.text }
}
