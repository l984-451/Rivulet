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

/// Group caption between runs of rows, matching Apple TV Settings: small
/// uppercase tracked gray text, no capsule, no divider rule, never focusable
/// (`SettingsRowItem.header(_:)` is built on the unfocusable `.info` kind).
/// The label is bottom-aligned, so the empty top of the cell IS the gap that
/// separates one group from the previous one.
/// Settings follows the system appearance, as tvOS Settings does. Light values measured off
/// tvOS Settings in light mode: rows are white 0.24 over a ~0.87 gray, with black text.
enum SettingsPalette {
    static func adaptive(dark: UIColor, light: UIColor) -> UIColor {
        UIColor { $0.userInterfaceStyle == .light ? light : dark }
    }
    static let text = adaptive(dark: .white, light: .black)
    static let caption = adaptive(dark: .white.withAlphaComponent(0.5), light: .black.withAlphaComponent(0.45))
    static let dim = adaptive(dark: .white.withAlphaComponent(0.35), light: .black.withAlphaComponent(0.4))
}

final class SettingsHeaderCell: UICollectionViewCell {
    static let reuseID = "SettingsHeaderCell"

    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            // tvOS Settings insets captions 32, two past the row titles' 30.
            label.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            label.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -32),
            // Baseline 17 above the next capsule, as measured.
            label.lastBaselineAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -9)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Not tertiaryLabel: the dynamic gray vanishes on the dark page.
    static let captionColor = SettingsPalette.caption

    func configure(title: String) {
        // 31 = tvOS Callout. Measured off tvOS Settings' own captions: 21.0-21.5pt
        // cap height (31 x 0.70 = 21.7), against 27.0pt for a row title.
        label.attributedText = NSAttributedString(string: title.uppercased(), attributes: [
            .font: UIFont.systemFont(ofSize: 31, weight: .semibold),
            .foregroundColor: Self.captionColor
        ])
    }
}

final class SettingsCell: UICollectionViewCell {
    static let reuseID = "SettingsCell"

    /// Focus growth per side, an outset because a scale factor cannot match it.
    /// Measured off tvOS Settings at 4K: 780.0 x 66.5pt at rest, 788.0 x 74.5pt
    /// focused, so 4pt on all four sides.
    private static let focusOutset: CGFloat = 4
    /// Resting inset of the capsule inside the 64pt row height.
    private static let restingInsetY: CGFloat = 3

    private let bg = CapsuleBackgroundView()
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let chevron = UIImageView()
    private let checkmark = UIImageView()
    /// Stands in for the value while the row's change is in flight.
    private let spinner = UIActivityIndicatorView(style: .medium)

    private var bgTop: NSLayoutConstraint!
    private var bgBottom: NSLayoutConstraint!
    private var bgLeading: NSLayoutConstraint!
    private var bgTrailing: NSLayoutConstraint!
    private var valueToAccessory: NSLayoutConstraint!
    private var valueToEdge: NSLayoutConstraint!

    // Measured off tvOS Settings: fill white 0.10 (0.24 in light mode), value and chevron
    // white 0.3 / black 0.4.
    private static let restingFill = SettingsPalette.adaptive(dark: .white.withAlphaComponent(0.10),
                                                              light: .white.withAlphaComponent(0.24))
    private static let restingValue = SettingsPalette.adaptive(dark: .white.withAlphaComponent(0.3),
                                                               light: .black.withAlphaComponent(0.4))
    private static let focusedValue = UIColor.black.withAlphaComponent(0.4)

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
        // Unmasked so the focus shadow shows; the fill still follows cornerRadius.
        bg.backgroundColor = Self.restingFill
        bg.layer.shadowColor = UIColor.black.cgColor
        bg.layer.shadowOffset = CGSize(width: 0, height: 6)
        bg.layer.shadowRadius = 10
        bg.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bg)
        // Kill any system focus/selection background so only `bg` paints.
        backgroundView = nil
        selectedBackgroundView = nil
        contentView.backgroundColor = .clear

        // 38 = tvOS Headline, and a 27.0pt cap height measured off tvOS
        // Settings' own rows (38 x 0.70 = 26.6).
        titleLabel.font = .systemFont(ofSize: 38, weight: .medium)
        titleLabel.textColor = SettingsPalette.text
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(titleLabel)

        valueLabel.font = titleLabel.font
        valueLabel.textColor = Self.restingValue
        valueLabel.textAlignment = .right
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(valueLabel)

        chevron.image = UIImage(systemName: "chevron.right",
                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 38, weight: .medium))
        chevron.tintColor = Self.restingValue
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

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(spinner)

        // Held as properties: focus grows the capsule by moving these four, so
        // the labels ride with it and nothing is scaled (text stays crisp).
        bgTop = bg.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Self.restingInsetY)
        bgBottom = bg.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Self.restingInsetY)
        bgLeading = bg.leadingAnchor.constraint(equalTo: contentView.leadingAnchor)
        bgTrailing = bg.trailingAnchor.constraint(equalTo: contentView.trailingAnchor)

        // tvOS Settings: leave room for the trailing chevron or selection mark.
        valueToAccessory = valueLabel.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -85)
        valueToEdge = valueLabel.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -30)

        NSLayoutConstraint.activate([
            bgTop, bgBottom, bgLeading, bgTrailing,

            titleLabel.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 30),
            titleLabel.centerYAnchor.constraint(equalTo: bg.centerYAnchor),

            chevron.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -32),
            chevron.centerYAnchor.constraint(equalTo: bg.centerYAnchor),

            checkmark.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -28),
            checkmark.centerYAnchor.constraint(equalTo: bg.centerYAnchor),

            spinner.trailingAnchor.constraint(equalTo: valueLabel.trailingAnchor),
            spinner.centerYAnchor.constraint(equalTo: bg.centerYAnchor),

            valueToAccessory,
            valueLabel.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16)
        ])
    }

    func configure(title: String, value: String?, showsChevron: Bool, destructive: Bool,
                   showsCheckmark: Bool = false, dimmed: Bool = false, busy: Bool = false) {
        titleLabel.text = title
        checkmark.isHidden = !showsCheckmark
        valueLabel.text = value
        valueLabel.isHidden = busy || (value == nil || value?.isEmpty == true)
        if busy { spinner.startAnimating() } else { spinner.stopAnimating() }
        chevron.isHidden = !showsChevron
        NSLayoutConstraint.deactivate([valueToAccessory, valueToEdge])
        (showsChevron || showsCheckmark ? valueToAccessory : valueToEdge).isActive = true
        self.destructive = destructive
        setDimmed(dimmed)
        applyAppearance(focused: isFocused)
    }

    /// Grayed-out state for a row disabled by another setting. It is also
    /// unfocusable (`SettingsRowItem.isFocusable`), so it never focuses while dim.
    func setDimmed(_ dimmed: Bool) {
        contentView.alpha = dimmed ? 0.35 : 1
    }

    func updateValue(_ value: String?) {
        valueLabel.text = value
        valueLabel.isHidden = (value == nil || value?.isEmpty == true)
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onFocusGained = nil
        bg.setReorderWiggle(false)
        setDimmed(false)
        applyAppearance(focused: false)
    }

    /// Apple-Home-style "grabbed" state: a continuous gentle wiggle on the
    /// capsule (the cell keeps its focused scale). Toggled by the reorder
    /// (move) mode in `SettingsPageViewController`.
    func setReordering(_ on: Bool) {
        bg.setReorderWiggle(on)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        let gained = context.nextFocusedView === self
        let lost = context.previouslyFocusedView === self
        if gained { onFocusGained?() }
        if gained {
            coordinator.addCoordinatedAnimations({ [weak self] in
                self?.applyAppearance(focused: true)
            }, completion: nil)
        } else if lost {
            // Instant, colors AND outset: any animated unfocus reads as the
            // old row ghosting or lagging behind the focus move.
            applyAppearance(focused: false)
        }
    }

    /// Internal, not private: both entry points are outside this method's own
    /// callers' reach — `configure` applies it flat, `didUpdateFocus` applies it
    /// inside the focus coordinator's animation block.
    func applyAppearance(focused: Bool) {
        if focused {
            // Bright near-opaque white capsule + dark text.
            bg.backgroundColor = .white
            titleLabel.textColor = destructive ? .systemRed : .black
            valueLabel.textColor = Self.focusedValue
            chevron.tintColor = Self.focusedValue
            checkmark.tintColor = .black
            spinner.color = Self.focusedValue
        } else {
            // Unfocused rows are translucent glass capsules (visible buttons).
            bg.backgroundColor = Self.restingFill
            titleLabel.textColor = destructive ? .systemRed : SettingsPalette.text
            valueLabel.textColor = Self.restingValue
            chevron.tintColor = Self.restingValue
            checkmark.tintColor = .systemBlue
            spinner.color = SettingsPalette.text
        }
        // Grow the capsule outward by the same amount on all four sides. The
        // grown capsule reaches past the cell's own bounds, so lift it above its
        // neighbours; CapsuleBackgroundView re-rounds itself to the new height.
        let outset = focused ? Self.focusOutset : 0
        bgTop.constant = Self.restingInsetY - outset
        bgBottom.constant = outset - Self.restingInsetY
        bgLeading.constant = -outset
        bgTrailing.constant = outset
        layer.zPosition = focused ? 1 : 0
        bg.layer.shadowOpacity = focused ? 0.3 : 0
        // Inside the focus coordinator's block this animates on the native focus
        // clock; from `configure` it just applies.
        contentView.layoutIfNeeded()
    }
}
