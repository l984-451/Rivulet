// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DirectionHintView.swift
//  Rivulet
//
//  A compact chevron with an optional label, naming what a swipe or press that
//  way does: multiview's "Swipe up to watch" and edit chevron, the photo viewer's Info.
//

import UIKit

final class DirectionHintView: UIView {
    /// Multiview's hints take focus only so a move toward them has somewhere to land; the
    /// controller changes mode the moment one does, so it never shows a focused look.
    /// The photo viewer's stays unfocusable, so the viewer keeps no focus target but its anchor.
    private let focusable: Bool
    private let stack = UIStackView()

    override var canBecomeFocused: Bool { focusable }

    /// The chevron sits on the side it points to, the label away from the edge.
    init(pointsUp: Bool, text: String?, focusable: Bool = true) {
        self.focusable = focusable
        super.init(frame: .zero)
        let chevron = UIImageView(image: UIImage(systemName: pointsUp ? "chevron.compact.up" : "chevron.compact.down"))
        chevron.tintColor = UIColor.white.withAlphaComponent(0.8)
        chevron.preferredSymbolConfiguration = .init(pointSize: 34, weight: .semibold)

        stack.addArrangedSubview(chevron)
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 2
        if let text {
            let label = UILabel()
            label.text = text
            label.font = .systemFont(ofSize: 24, weight: .medium)
            label.textColor = UIColor.white.withAlphaComponent(0.8)
            stack.insertArrangedSubview(label, at: pointsUp ? 1 : 0)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// For Auto Layout hosts; multiview sets frames.
    override var intrinsicContentSize: CGSize { stack.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize) }
}
