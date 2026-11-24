// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The loading pill: a glass capsule at the top of the main screen while a large load runs
//  ("Loading guide · 38%"). Follows `LoadingActivity.text`; never takes focus or touches.
//  Lives in the shell, so a presented player covers it. iOS and Mac: `LoadingPill`.

import Combine
import UIKit

final class LoadingPillView: UIView {
    private let glass = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let label = UILabel()
    private var observation: AnyCancellable?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        alpha = 0
        isHidden = true

        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.clipsToBounds = true
        addSubview(glass)

        spinner.color = .white
        label.font = .systemFont(ofSize: 24, weight: .semibold)
        label.textColor = .white
        label.adjustsFontForContentSizeCategory = true
        let row = UIStackView(arrangedSubviews: [spinner, label])
        row.spacing = 14
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 14),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -14),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 24),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -28),
        ])

        observation = LoadingActivity.shared.$text
            .receive(on: DispatchQueue.main)
            .sink { [weak self] text in self?.show(text) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.layer.cornerRadius = bounds.height / 2
    }

    private func show(_ text: String?) {
        if let text {
            label.text = text
            accessibilityLabel = text
            guard isHidden else { return }
            isHidden = false
            spinner.startAnimating()
            UIView.animate(withDuration: 0.3) { self.alpha = 1 }
        } else {
            guard !isHidden else { return }
            UIView.animate(withDuration: 0.3, animations: { self.alpha = 0 }, completion: { _ in
                // A load that began during the fade keeps the pill.
                guard LoadingActivity.shared.text == nil else { return }
                self.isHidden = true
                self.spinner.stopAnimating()
            })
        }
    }
}
