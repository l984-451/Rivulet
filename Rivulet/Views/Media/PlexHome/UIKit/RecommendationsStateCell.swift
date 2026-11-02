// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Full-width loading and error state for the Personalized Recommendations row.

import UIKit

@MainActor
final class RecommendationsStateCell: UICollectionViewCell {
    static let reuseID = "RecommendationsStateCell"

    enum State {
        case loading
        case error(message: String)
    }

    var onRetry: (() -> Void)?

    private let iconView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let leadingStack = UIStackView()  // icon/spinner
    private let textStack = UIStackView()      // title + message
    private let rowStack = UIStackView()       // [leading, text, spacer, retry]

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        backgroundColor = .clear

        iconView.image = UIImage(systemName: "exclamationmark.triangle.fill")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
        iconView.tintColor = .systemYellow
        iconView.contentMode = .scaleAspectFit

        spinner.color = .white
        spinner.hidesWhenStopped = true

        titleLabel.font = .systemFont(ofSize: 22, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1

        messageLabel.font = .systemFont(ofSize: 16)
        messageLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        messageLabel.numberOfLines = 2

        retryButton.setTitle(String(localized: "Retry"), for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .primaryActionTriggered)
        retryButton.setContentHuggingPriority(.required, for: .horizontal)

        leadingStack.axis = .horizontal
        leadingStack.alignment = .center
        leadingStack.addArrangedSubview(iconView)
        leadingStack.addArrangedSubview(spinner)

        textStack.axis = .vertical
        textStack.spacing = 4
        textStack.alignment = .leading
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(messageLabel)

        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = 14
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.addArrangedSubview(leadingStack)
        rowStack.addArrangedSubview(textStack)
        rowStack.addArrangedSubview(retryButton)
        contentView.addSubview(rowStack)

        NSLayoutConstraint.activate([
            rowStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            rowStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
            rowStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            rowStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            iconView.widthAnchor.constraint(equalToConstant: 24),
            iconView.heightAnchor.constraint(equalToConstant: 24)
        ])
    }

    override var canBecomeFocused: Bool {
        // Only the retry button is focusable, and only in the error state.
        return retryButton.isHidden == false
    }

    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        if !retryButton.isHidden { return [retryButton] }
        return super.preferredFocusEnvironments
    }

    func configure(state: State) {
        switch state {
        case .loading:
            iconView.isHidden = true
            spinner.startAnimating()
            spinner.isHidden = false
            titleLabel.text = String(localized: "Building Personalized Recommendations")
            messageLabel.text = String(localized: "This may take a moment")
            retryButton.isHidden = true
        case .error(let message):
            iconView.isHidden = false
            spinner.stopAnimating()
            spinner.isHidden = true
            titleLabel.text = String(localized: "Personalized Recommendations Unavailable")
            messageLabel.text = message
            retryButton.isHidden = false
        }
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}
