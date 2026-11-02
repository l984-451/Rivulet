// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

// Home placeholder states (not connected, loading, error, empty) and the watchlist toast.

import UIKit

// MARK: - Empty / loading / error / not-connected state view

/// Single-purpose view that swaps icon + title + message based on the
/// kind it's configured with. Lives full-screen behind the collection
/// view; `isHidden = true` when the home has content to show.
@MainActor
final class HomeStateView: UIView {

    enum Kind {
        case notConnected               // "Connect to your Plex server in Settings."
        case loading                    // "Loading" + spinner
        case error(message: String)     // "Unable to Load" + retry
        // "No Content" + refresh. Carries its message because the surfaces do
        // not share one: Discover is fed by TMDB and has nothing to do with the
        // Plex library.
        case empty(message: String)

        var iconSystemName: String? {
            switch self {
            case .notConnected: return "server.rack"
            case .loading: return nil  // spinner instead
            case .error: return "exclamationmark.triangle"
            case .empty: return "film.stack"
            }
        }

        var title: String {
            switch self {
            case .notConnected: return String(localized: "Not Connected")
            case .loading: return String(localized: "Loading")
            case .error: return String(localized: "Unable to Load")
            case .empty: return String(localized: "No Content")
            }
        }

        var message: String? {
            switch self {
            case .notConnected: return String(localized: "Connect to your Plex server in Settings.")
            case .loading: return nil
            case .error(let message): return message
            case .empty(let message): return message
            }
        }

        var actionTitle: String? {
            switch self {
            case .error: return String(localized: "Try Again")
            case .empty: return String(localized: "Refresh")
            default: return nil
            }
        }
    }

    var onAction: (() -> Void)?

    private let iconView = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .large)
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        backgroundColor = .black

        iconView.tintColor = UIColor.white.withAlphaComponent(0.6)
        iconView.contentMode = .scaleAspectFit
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 48, weight: .light)

        spinner.color = .white
        spinner.hidesWhenStopped = true

        titleLabel.font = .preferredFont(forTextStyle: .title2)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0

        messageLabel.font = .preferredFont(forTextStyle: .body)
        messageLabel.textColor = UIColor.white.withAlphaComponent(0.6)
        messageLabel.textAlignment = .center
        messageLabel.numberOfLines = 0

        actionButton.addTarget(self, action: #selector(actionTapped), for: .primaryActionTriggered)
        actionButton.titleLabel?.font = .preferredFont(forTextStyle: .headline)

        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        stack.addArrangedSubview(iconView)
        stack.addArrangedSubview(spinner)
        stack.addArrangedSubview(titleLabel)
        stack.addArrangedSubview(messageLabel)
        stack.addArrangedSubview(actionButton)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 48),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -48),

            iconView.heightAnchor.constraint(equalToConstant: 48),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 400)
        ])
    }

    func configure(kind: Kind) {
        if let iconName = kind.iconSystemName {
            iconView.image = UIImage(systemName: iconName)
            iconView.isHidden = false
            spinner.stopAnimating()
            spinner.isHidden = true
        } else {
            iconView.isHidden = true
            spinner.startAnimating()
            spinner.isHidden = false
        }
        titleLabel.text = kind.title
        if let msg = kind.message {
            messageLabel.text = msg
            messageLabel.isHidden = false
        } else {
            messageLabel.isHidden = true
        }
        if let action = kind.actionTitle {
            actionButton.setTitle(action, for: .normal)
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
    }

    @objc private func actionTapped() {
        onAction?()
    }
}

// MARK: - Watchlist toast

/// Bottom pill shown when a watchlist write reverts.
@MainActor
final class WatchlistToastView: UIView {

    private let label = UILabel()
    private let pillBackground = UIView()

    private var hideWorkItem: DispatchWorkItem?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        translatesAutoresizingMaskIntoConstraints = false
        alpha = 0

        pillBackground.translatesAutoresizingMaskIntoConstraints = false
        pillBackground.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        pillBackground.layer.cornerRadius = 28
        pillBackground.layer.cornerCurve = .continuous
        pillBackground.layer.borderWidth = 1
        pillBackground.layer.borderColor = UIColor.white.withAlphaComponent(0.15).cgColor
        addSubview(pillBackground)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 22, weight: .semibold)
        label.textColor = .white
        label.numberOfLines = 2
        label.textAlignment = .center
        pillBackground.addSubview(label)

        NSLayoutConstraint.activate([
            pillBackground.topAnchor.constraint(equalTo: topAnchor),
            pillBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            pillBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            pillBackground.trailingAnchor.constraint(equalTo: trailingAnchor),

            label.topAnchor.constraint(equalTo: pillBackground.topAnchor, constant: 16),
            label.bottomAnchor.constraint(equalTo: pillBackground.bottomAnchor, constant: -16),
            label.leadingAnchor.constraint(equalTo: pillBackground.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(equalTo: pillBackground.trailingAnchor, constant: -32)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Shows `message` for about 2.5s, or hides the toast when nil.
    func show(message: String?, autoHideAfter: TimeInterval = 2.5) {
        hideWorkItem?.cancel()
        guard let message else {
            hide()
            return
        }
        label.text = message
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.alpha = 1
            self.transform = .identity
        }
        if autoHideAfter > 0 {
            let workItem = DispatchWorkItem { [weak self] in self?.hide() }
            hideWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + autoHideAfter, execute: workItem)
        }
    }

    private func hide() {
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.alpha = 0
            self.transform = CGAffineTransform(translationX: 0, y: 30)
        }
    }
}

// No connection banner here: one in `contentInset.top` made every row jump. `ConnectionAlert` covers offline.
