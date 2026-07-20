// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  SettingsCell.swift
//  Rivulet
//
//  Capsule settings row cell, matching Apple TV Settings. cornerRadius =
//  height/2 (true capsule). Unfocused = translucent glass fill + white
//  title; focused = bright white capsule + dark title + slight lift,
//  animated on the focus coordinator's clock (native focus timing).
//  Reports focus via `onFocusGained` (drives the left description panel).
//

import UIKit

/// A view that keeps itself a capsule (cornerRadius = height/2). It rounds in
/// its OWN `layoutSubviews`, where its bounds are resolved — unlike the cell's
/// `layoutSubviews`, which runs before the contentView lays out this subview
/// (so reading `bg.bounds` there yields 0 and sets cornerRadius to 0).
final class CapsuleBackgroundView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

final class SettingsCell: UICollectionViewCell {
    static let reuseID = "SettingsCell"

    private let bg = CapsuleBackgroundView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let chevron = UIImageView()
    private let checkmark = UIImageView()

    /// Called when this cell GAINS focus (drives the description panel).
    var onFocusGained: (() -> Void)?

    private var destructive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setup() {
        backgroundColor = .clear

        // Capsule rows (CapsuleBackgroundView rounds itself to height/2).
        bg.layer.masksToBounds = true
        bg.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        bg.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bg)
        // Kill any system focus/selection background so only `bg` paints.
        backgroundView = nil
        selectedBackgroundView = nil
        contentView.backgroundColor = .clear

        titleLabel.font = .systemFont(ofSize: 36, weight: .medium)
        titleLabel.textColor = .white
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(titleLabel)

        valueLabel.font = .systemFont(ofSize: 32, weight: .medium)
        valueLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        valueLabel.textAlignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(valueLabel)

        chevron.image = UIImage(systemName: "chevron.right",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .semibold))
        chevron.tintColor = UIColor.white.withAlphaComponent(0.55)
        chevron.contentMode = .center
        chevron.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(chevron)

        checkmark.image = UIImage(systemName: "checkmark",
                                  withConfiguration: UIImage.SymbolConfiguration(pointSize: 28, weight: .bold))
        checkmark.tintColor = .systemBlue
        checkmark.contentMode = .center
        checkmark.isHidden = true
        checkmark.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(checkmark)

        NSLayoutConstraint.activate([
            bg.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 3),
            bg.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -3),
            bg.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            bg.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 28),
            titleLabel.centerYAnchor.constraint(equalTo: bg.centerYAnchor),

            chevron.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -28),
            chevron.centerYAnchor.constraint(equalTo: bg.centerYAnchor),

            checkmark.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -28),
            checkmark.centerYAnchor.constraint(equalTo: bg.centerYAnchor),

            valueLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -16),
            valueLabel.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16)
        ])
    }

    func configure(title: String, value: String?, showsChevron: Bool, destructive: Bool,
                   showsCheckmark: Bool = false) {
        titleLabel.text = title
        checkmark.isHidden = !showsCheckmark
        valueLabel.text = value
        valueLabel.isHidden = (value == nil || value?.isEmpty == true)
        chevron.isHidden = !showsChevron
        self.destructive = destructive
        applyAppearance(focused: isFocused)
    }

    func updateValue(_ value: String?) {
        valueLabel.text = value
        valueLabel.isHidden = (value == nil || value?.isEmpty == true)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onFocusGained = nil
        transform = .identity
        bg.layer.removeAnimation(forKey: "reorderWiggle")
        applyAppearance(focused: false)
    }

    /// Apple-Home-style "grabbed" state: a continuous gentle wiggle on the
    /// capsule (the cell keeps its focused scale). Toggled by the reorder
    /// (move) mode in `SettingsPageViewController`.
    func setReordering(_ on: Bool) {
        if on {
            let wiggle = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            wiggle.values = [-0.022, 0.022, -0.022]
            wiggle.duration = 0.34
            wiggle.repeatCount = .infinity
            wiggle.isRemovedOnCompletion = false
            bg.layer.add(wiggle, forKey: "reorderWiggle")
        } else {
            bg.layer.removeAnimation(forKey: "reorderWiggle")
        }
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let gained = context.nextFocusedView === self
        let lost = context.previouslyFocusedView === self
        if gained { onFocusGained?() }
        if gained || lost {
            coordinator.addCoordinatedAnimations({ [weak self] in
                self?.applyAppearance(focused: gained)
            }, completion: nil)
        }
    }

    private func applyAppearance(focused: Bool) {
        if focused {
            // Bright near-opaque white capsule + dark text + slight lift.
            bg.backgroundColor = .white
            titleLabel.textColor = destructive ? .systemRed : .black
            valueLabel.textColor = UIColor.black.withAlphaComponent(0.6)
            chevron.tintColor = UIColor.black.withAlphaComponent(0.6)
            checkmark.tintColor = .black
            transform = CGAffineTransform(scaleX: 1.04, y: 1.04)
        } else {
            // Unfocused rows are translucent glass capsules (visible buttons).
            bg.backgroundColor = UIColor.white.withAlphaComponent(0.12)
            titleLabel.textColor = destructive ? .systemRed : .white
            valueLabel.textColor = UIColor.white.withAlphaComponent(0.55)
            chevron.tintColor = UIColor.white.withAlphaComponent(0.55)
            checkmark.tintColor = .systemBlue
            transform = .identity
        }
    }
}
