// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SearchCells.swift
//  Rivulet
//
//  Full-width cells for the UIKit search surface (PlexHomeViewController
//  in `.search` mode):
//
//   - SearchPromptCell: the empty-query state — magnifier + "Search Your
//     Libraries" prompt with the recent-searches pill row beneath it.
//     Port of PlexSearchView.searchPromptView / recentSearchesView.
//   - SearchStateCell: inline searching / error / no-results states.
//     Port of PlexSearchView.loadingView / errorView / noResultsView.
//
//  Both cells are non-focusable containers (canFocusItemAt false in the
//  controller); their interactive content (recents pills, Try Again) are
//  FocusableActionButtons, which the engine focuses directly.
//

import UIKit

// MARK: - Prompt + recent searches

@MainActor
final class SearchPromptCell: UICollectionViewCell {
    static let reuseID = "SearchPromptCell"

    var onRecentSelected: ((String) -> Void)?
    var onClearRecents: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let recentHeaderLabel = UILabel()
    private let pillScroll = UIScrollView()
    private let pillStack = UIStackView()
    private let outerStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        backgroundColor = .clear

        iconView.image = UIImage(systemName: "magnifyingglass")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 48, weight: .light))
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit

        titleLabel.text = "Search Your Libraries"
        titleLabel.font = .systemFont(ofSize: 38, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center

        recentHeaderLabel.text = "RECENT"
        recentHeaderLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        recentHeaderLabel.textColor = .secondaryLabel
        recentHeaderLabel.textAlignment = .center

        pillStack.axis = .horizontal
        pillStack.spacing = 16
        pillStack.alignment = .center
        pillStack.translatesAutoresizingMaskIntoConstraints = false

        pillScroll.showsHorizontalScrollIndicator = false
        pillScroll.clipsToBounds = false
        pillScroll.addSubview(pillStack)
        pillScroll.translatesAutoresizingMaskIntoConstraints = false

        outerStack.axis = .vertical
        outerStack.alignment = .center
        outerStack.spacing = 16
        outerStack.translatesAutoresizingMaskIntoConstraints = false
        outerStack.addArrangedSubview(iconView)
        outerStack.addArrangedSubview(titleLabel)
        outerStack.setCustomSpacing(48, after: titleLabel)
        outerStack.addArrangedSubview(recentHeaderLabel)
        outerStack.addArrangedSubview(pillScroll)
        contentView.addSubview(outerStack)

        NSLayoutConstraint.activate([
            outerStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 120),
            outerStack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            outerStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -40),

            pillScroll.heightAnchor.constraint(equalToConstant: 96),
            pillScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 1400),

            pillStack.leadingAnchor.constraint(equalTo: pillScroll.contentLayoutGuide.leadingAnchor, constant: 8),
            pillStack.trailingAnchor.constraint(equalTo: pillScroll.contentLayoutGuide.trailingAnchor, constant: -8),
            pillStack.centerYAnchor.constraint(equalTo: pillScroll.frameLayoutGuide.centerYAnchor),
            pillScroll.contentLayoutGuide.heightAnchor.constraint(equalTo: pillScroll.frameLayoutGuide.heightAnchor)
        ])
    }

    /// The cell is the collection view's focus item, but it is a big empty area
    /// and should never hold focus itself — redirect straight into the pills.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        pillScroll.isHidden ? super.preferredFocusEnvironments : pillStack.arrangedSubviews
    }

    func configure(recentSearches: [String]) {
        pillStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let hasRecents = !recentSearches.isEmpty
        recentHeaderLabel.isHidden = !hasRecents
        pillScroll.isHidden = !hasRecents
        guard hasRecents else { return }

        let clear = Self.makePill(icon: "xmark", text: "Clear", dimmed: true)
        clear.onPrimaryAction = { [weak self] in self?.onClearRecents?() }
        pillStack.addArrangedSubview(clear)

        for search in recentSearches {
            let pill = Self.makePill(icon: "clock.arrow.circlepath", text: search, dimmed: false)
            pill.onPrimaryAction = { [weak self] in self?.onRecentSelected?(search) }
            pillStack.addArrangedSubview(pill)
        }
        // Shrink the scroll to its content when the pills don't fill the cap.
        pillScroll.layoutIfNeeded()
    }

    /// A recents pill: glass capsule + icon + label, white-fill inversion on
    /// focus via FocusableActionButton (matches the detail action pills).
    private static func makePill(icon: String, text: String, dimmed: Bool) -> FocusableActionButton {
        let button = FocusableActionButton()
        button.translatesAutoresizingMaskIntoConstraints = false
        button.layer.cornerRadius = 16

        let iconView = UIImageView(image: UIImage(systemName: icon)?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .medium)))
        iconView.tintColor = dimmed ? UIColor.white.withAlphaComponent(0.6) : .white
        iconView.contentMode = .scaleAspectFit

        let label = UILabel()
        label.text = text
        label.font = .systemFont(ofSize: 26, weight: .medium)
        label.textColor = dimmed ? UIColor.white.withAlphaComponent(0.6) : .white
        label.numberOfLines = 1

        let stack = UIStackView(arrangedSubviews: [iconView, label])
        stack.axis = .horizontal
        stack.spacing = 12
        stack.alignment = .center
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: button.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -28),
            stack.topAnchor.constraint(equalTo: button.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -18)
        ])

        button.invertOnFocus = [iconView, label]
        return button
    }
}

// MARK: - Searching / error / no-results states

@MainActor
final class SearchStateCell: UICollectionViewCell {
    static let reuseID = "SearchStateCell"

    enum State {
        case searching
        case error(message: String)
        case noResults

        /// Only the error state renders Try Again, so only it is worth making
        /// the cell focusable for.
        var hasFocusableAction: Bool {
            if case .error = self { return true }
            return false
        }
    }

    var onRetry: (() -> Void)?

    private let spinner = UIActivityIndicatorView(style: .large)
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let retryButton = FocusableActionButton()
    private let retryLabel = UILabel()
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        backgroundColor = .clear

        spinner.color = .white

        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleAspectFit

        titleLabel.font = .systemFont(ofSize: 38, weight: .medium)
        titleLabel.textColor = .label
        titleLabel.textAlignment = .center

        messageLabel.font = .systemFont(ofSize: 25, weight: .regular)
        messageLabel.textColor = .secondaryLabel
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0
        messageLabel.preferredMaxLayoutWidth = 520

        retryLabel.text = "Try Again"
        retryLabel.font = .systemFont(ofSize: 26, weight: .medium)
        retryLabel.textColor = .white
        retryLabel.translatesAutoresizingMaskIntoConstraints = false
        retryButton.layer.cornerRadius = 16
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.addSubview(retryLabel)
        retryButton.invertOnFocus = [retryLabel]
        retryButton.onPrimaryAction = { [weak self] in self?.onRetry?() }
        NSLayoutConstraint.activate([
            retryLabel.leadingAnchor.constraint(equalTo: retryButton.leadingAnchor, constant: 32),
            retryLabel.trailingAnchor.constraint(equalTo: retryButton.trailingAnchor, constant: -32),
            retryLabel.topAnchor.constraint(equalTo: retryButton.topAnchor, constant: 18),
            retryLabel.bottomAnchor.constraint(equalTo: retryButton.bottomAnchor, constant: -18)
        ])

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(retryButton)
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 140),
            stack.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -40)
        ])
    }

    /// Same redirect as `SearchPromptCell`: the cell is the focus item the
    /// collection view offers, Try Again is what should actually take focus.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        retryButton.isHidden ? super.preferredFocusEnvironments : [retryButton]
    }

    func configure(state: State) {
        switch state {
        case .searching:
            spinner.isHidden = false
            spinner.startAnimating()
            iconView.isHidden = true
            titleLabel.text = "Searching"
            messageLabel.isHidden = true
            retryButton.isHidden = true
        case .error(let message):
            spinner.stopAnimating()
            spinner.isHidden = true
            iconView.isHidden = false
            iconView.image = UIImage(systemName: "exclamationmark.triangle")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 48, weight: .light))
            titleLabel.text = "Search Failed"
            messageLabel.isHidden = false
            messageLabel.text = message
            retryButton.isHidden = false
        case .noResults:
            spinner.stopAnimating()
            spinner.isHidden = true
            iconView.isHidden = false
            iconView.image = UIImage(systemName: "sparkles")?
                .withConfiguration(UIImage.SymbolConfiguration(pointSize: 48, weight: .light))
            titleLabel.text = "No Results"
            messageLabel.isHidden = false
            messageLabel.text = "Try a different title or check your spelling."
            retryButton.isHidden = true
        }
    }
}
