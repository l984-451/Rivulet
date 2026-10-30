// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Home row section headers. `.swiftUIInfiniteRow`: 31pt semibold, white 0.55 (MediaRowMetrics).
// `.swiftUIWatchlist`: 30pt bold, full white. Neither shows a count.

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
    private var stackBottom: NSLayoutConstraint!
    private let seeAllButton = UIButton(type: .system)
    var onSeeAll: (() -> Void)? {
        didSet { seeAllButton.isHidden = onSeeAll == nil }
    }

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
        seeAllButton.setTitle("See All", for: .normal)
        seeAllButton.titleLabel?.font = .systemFont(ofSize: 23, weight: .semibold)
        seeAllButton.isHidden = true
        seeAllButton.addAction(UIAction { [weak self] _ in self?.onSeeAll?() }, for: .primaryActionTriggered)
        stack.addArrangedSubview(seeAllButton)
        addSubview(stack)

        stackBottom = stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        NSLayoutConstraint.activate([
            // Leading 0: the section's contentInsets.leading already insets the
            // header (supplementariesFollowContentInsets defaults to true), so 0
            // here makes the title align exactly with the row's first card. A
            // non-zero value double-insets the header to the right of the cards.
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -48),
            stackBottom
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
            titleLabel.font = MediaRowMetrics.headerFont
            titleLabel.textColor = MediaRowMetrics.headerColor
        case .swiftUIWatchlist:
            titleLabel.font = .systemFont(ofSize: MediaRowMetrics.sectionTitleSize, weight: .bold)
            titleLabel.textColor = .white
        }
        titleLabel.text = title
        // Rests the baseline `headerBaselineInset` above the header's bottom edge.
        stackBottom.constant = -titleLabel.font.descender - MediaRowMetrics.headerBaselineInset
        badge.text = sourceBadge

        countLabel.text = nil
        countLabel.isHidden = true
    }

    /// The badge's text while it shows (tests).
    var sourceBadgeText: String? { badge.isHidden ? nil : badge.text }
}
