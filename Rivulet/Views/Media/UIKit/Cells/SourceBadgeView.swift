// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SourceBadgeView.swift
//  Rivulet
//
//  A small monochrome capsule naming the server a row or tile comes from
//  ("Plex", "Jellyfin"). Shown only while more than one server is signed in.
//

import UIKit

@MainActor
final class SourceBadgeView: UIView {
    enum Style {
        /// Over a poster.
        case onArtwork
        /// Beside a title.
        case inline
    }

    private let label = UILabel()

    /// nil hides the badge.
    var text: String? {
        didSet {
            label.text = text
            accessibilityLabel = text
            isHidden = text == nil
        }
    }

    init(style: Style) {
        super.init(frame: .zero)
        isHidden = true
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        layer.borderWidth = 1
        layer.cornerCurve = .continuous

        let insets: UIEdgeInsets
        switch style {
        case .onArtwork:
            backgroundColor = UIColor.black.withAlphaComponent(0.55)
            layer.borderColor = UIColor.white.withAlphaComponent(0.25).cgColor
            label.font = .systemFont(ofSize: 15, weight: .semibold)
            label.textColor = .white
            insets = UIEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        case .inline:
            backgroundColor = UIColor.white.withAlphaComponent(0.12)
            layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
            label.font = .systemFont(ofSize: 20, weight: .semibold)
            label.textColor = UIColor.white.withAlphaComponent(0.85)
            insets = UIEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        }

        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right)
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    // The label's baseline, so the badge sits on a title's baseline in a stack.
    override var forFirstBaselineLayout: UIView { label }
    override var forLastBaselineLayout: UIView { label }
}
