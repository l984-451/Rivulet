// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveMiniPlayerView.swift
//  Rivulet
//
//  The channel that keeps playing in the guide's corner after Back (#318), on a
//  session handed over by the full-screen player; nothing here tunes. Focusable
//  only with `isFocusable`, and it never sits over a focus target.
//

import UIKit

final class LiveMiniPlayerView: UIView {

    private let surface = AetherPlayer.makeRenderSurface()
    private let channelLabel = UILabel()
    private let liveDot = UIView()
    private weak var boundPlayer: AetherPlayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .black
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.borderColor = UIColor.white.withAlphaComponent(0.18).cgColor

        surface.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)

        let caption = UIView()
        caption.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)

        liveDot.backgroundColor = .systemRed
        liveDot.layer.cornerRadius = 5
        liveDot.translatesAutoresizingMaskIntoConstraints = false
        caption.addSubview(liveDot)

        channelLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        channelLabel.textColor = .white
        channelLabel.translatesAutoresizingMaskIntoConstraints = false
        caption.addSubview(channelLabel)

        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),

            caption.leadingAnchor.constraint(equalTo: leadingAnchor),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor),
            caption.bottomAnchor.constraint(equalTo: bottomAnchor),
            caption.heightAnchor.constraint(equalToConstant: 34),

            liveDot.leadingAnchor.constraint(equalTo: caption.leadingAnchor, constant: 12),
            liveDot.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
            liveDot.widthAnchor.constraint(equalToConstant: 10),
            liveDot.heightAnchor.constraint(equalToConstant: 10),

            channelLabel.leadingAnchor.constraint(equalTo: liveDot.trailingAnchor, constant: 8),
            channelLabel.trailingAnchor.constraint(lessThanOrEqualTo: caption.trailingAnchor, constant: -12),
            channelLabel.centerYAnchor.constraint(equalTo: caption.centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isFocusable = false {
        didSet { isUserInteractionEnabled = isFocusable }
    }

    override var canBecomeFocused: Bool { isFocusable }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let focused = context.nextFocusedView === self
        layer.borderColor = UIColor.white.withAlphaComponent(focused ? 0.7 : 0.18).cgColor
        coordinator.addCoordinatedAnimations {
            self.transform = focused ? CGAffineTransform(scaleX: 1.04, y: 1.04) : .identity
        }
    }

    /// Show `session`'s picture here. Binding a new surface detaches the old
    /// one, so the engine simply moves its layer over.
    func show(_ session: LiveTVSessionHandoff) {
        if boundPlayer !== session.player {
            boundPlayer?.unbind(surface: surface)
            session.player.bind(surface: surface)
            boundPlayer = session.player
        }
        channelLabel.text = [session.channel.displayNumber.map(String.init), session.channel.displayName]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// Let go of the picture (the session is moving on, or has stopped).
    func release() {
        boundPlayer?.unbind(surface: surface)
        boundPlayer = nil
    }
}
