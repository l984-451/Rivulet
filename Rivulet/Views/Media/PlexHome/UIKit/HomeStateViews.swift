// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomeStateViews.swift
//  Rivulet
//
//  Top-level home-state placeholder views — shown when there is no
//  content to render (no Plex connection, loading, error, empty), plus
//  the transient watchlist toast and the connection-error banner.
//
//  States: not-connected, loading, error, empty, the connection-error
//  banner, and the watchlist toast.
//

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
            case .notConnected: return "Not Connected"
            case .loading: return "Loading"
            case .error: return "Unable to Load"
            case .empty: return "No Content"
            }
        }

        var message: String? {
            switch self {
            case .notConnected: return "Connect to your Plex server in Settings."
            case .loading: return nil
            case .error(let message): return message
            case .empty(let message): return message
            }
        }

        var actionTitle: String? {
            switch self {
            case .error: return "Try Again"
            case .empty: return "Refresh"
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

/// Transient pill shown at the bottom of the home when a watchlist write
/// reverts. Mirror of `WatchlistToastModifier` — bottom-anchored,
/// rounded-pill background, ease-in-out fade in/out.
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

    /// Show the toast with `message`. If `message` is nil, hide. Visible
    /// for ~2.5s by default, then fades out (matches SwiftUI's
    /// auto-clear behaviour when `transientWriteError` resets to nil
    /// via the service's clearTransientError timer).
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

// MARK: - Connection error banner

/// Yellow warning banner shown at the top of the home when we're rendering
/// cached content but the Plex connection check failed.
@MainActor
final class ConnectionErrorBannerView: UIView {

    var onRetry: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let messageLabel = UILabel()
    private let retryButton = UIButton(type: .system)
    private let textStack = UIStackView()
    private let rowStack = UIStackView()
    private let backgroundView = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setUp()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setUp() {
        backgroundColor = .clear

        // Rounded yellow-tinted background w/ stroke (matches SwiftUI).
        backgroundView.translatesAutoresizingMaskIntoConstraints = false
        backgroundView.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.15)
        backgroundView.layer.cornerRadius = 16
        backgroundView.layer.cornerCurve = .continuous
        backgroundView.layer.borderWidth = 1
        backgroundView.layer.borderColor = UIColor.systemYellow.withAlphaComponent(0.3).cgColor
        addSubview(backgroundView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = UIImage(systemName: "wifi.exclamationmark")?
            .withConfiguration(UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold))
        iconView.tintColor = .systemYellow
        iconView.contentMode = .scaleAspectFit

        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.text = "Cannot Connect to Plex"

        messageLabel.font = .systemFont(ofSize: 16)
        messageLabel.textColor = UIColor.white.withAlphaComponent(0.7)
        messageLabel.numberOfLines = 0

        textStack.axis = .vertical
        textStack.spacing = 2
        textStack.alignment = .leading
        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(messageLabel)

        retryButton.setTitle("Retry", for: .normal)
        retryButton.titleLabel?.font = .systemFont(ofSize: 17, weight: .medium)
        retryButton.addTarget(self, action: #selector(retryTapped), for: .primaryActionTriggered)
        retryButton.setContentHuggingPriority(.required, for: .horizontal)

        rowStack.axis = .horizontal
        rowStack.alignment = .center
        rowStack.spacing = 14
        rowStack.translatesAutoresizingMaskIntoConstraints = false
        rowStack.addArrangedSubview(iconView)
        rowStack.addArrangedSubview(textStack)
        rowStack.addArrangedSubview(retryButton)
        backgroundView.addSubview(rowStack)

        NSLayoutConstraint.activate([
            backgroundView.topAnchor.constraint(equalTo: topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
            backgroundView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48),
            backgroundView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -48),

            rowStack.topAnchor.constraint(equalTo: backgroundView.topAnchor, constant: 16),
            rowStack.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor, constant: -16),
            rowStack.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor, constant: 24),
            rowStack.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor, constant: -24)
        ])
    }

    func setMessage(_ message: String?) {
        messageLabel.text = message ?? "Showing cached content"
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}
