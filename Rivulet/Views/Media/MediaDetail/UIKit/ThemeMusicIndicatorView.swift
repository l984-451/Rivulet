// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

//
//  ThemeMusicIndicatorView.swift
//  Rivulet
//

import Combine
import UIKit

/// A dim music note beside a show's details while the show has a theme tune, with a thin
/// ring while the tune's file opens. Part of the metadata, not a control: never focusable.
final class ThemeMusicIndicatorView: UIView {
    /// The badge height (MediaDetailChromeView.makeBadge), so a row never grows.
    static let side: CGFloat = 22
    /// About a badge border's strength in the dim details row.
    private static let tint = UIColor.white.withAlphaComponent(0.5)

    var show: MediaItemRef? {
        didSet { if show != oldValue { render(animated: false) } }
    }

    private let glyph = UIImageView(image: UIImage(systemName: "music.note",
                                                   withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
    private let ring = CAShapeLayer()
    private var observer: AnyCancellable?

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        isHidden = true

        glyph.tintColor = Self.tint
        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)

        ring.fillColor = UIColor.clear.cgColor
        ring.strokeColor = Self.tint.cgColor
        ring.lineWidth = 1
        ring.opacity = 0
        layer.addSublayer(ring)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        observer = NotificationCenter.default.publisher(for: ThemeMusic.indicatorDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.render(animated: true) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFocused: Bool { false }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).cgPath
    }

    /// Only alpha is animated, never isHidden: a stack view mis-animates that.
    private func render(animated: Bool) {
        let state = show.flatMap { ThemeMusic.shared.indicator(for: $0) }
        // A still ring; the layer's own short fade carries the change.
        ring.opacity = state?.showsRing == true ? 1 : 0
        let shows = state != nil
        guard isHidden == shows else { return }
        if shows {
            isHidden = false
            alpha = animated ? 0 : 1
            if animated { UIView.animate(withDuration: 0.3) { self.alpha = 1 } }
        } else {
            isHidden = true
        }
    }
}
