// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//  The detail action row's focusable rounded button. Callers add the content and name the
//  subviews that invert on focus; Select fires `.primaryActionTriggered`.

import UIKit

final class FocusableActionButton: UIControl {
    /// Content views recolored to black on focus (UIImageView via tintColor,
    /// UILabel via textColor). Set by the builder after adding content.
    var invertOnFocus: [UIView] = []

    /// Views whose background goes dark on focus, such as the Play progress track on the white fill.
    var invertBackgroundOnFocus: [UIView] = []

    /// Like `invertBackgroundOnFocus` but for the filled portion drawn on top of
    /// a track — it has to stay darker than the track it sits in, or the bar
    /// reads backwards on the white focused pill.
    var invertFillOnFocus: [UIView] = []

    /// Invoked on Select (`.primaryActionTriggered`).
    var onPrimaryAction: (() -> Void)?

    /// `.pill` inverts to white with black content; `.glass` keeps content white, for large targets like the bio panel.
    enum FocusStyle { case pill, glass }
    var focusStyle: FocusStyle = .pill

    private let restingFill = UIColor.white.withAlphaComponent(0.15)
    private let glassRestingFill = UIColor.white.withAlphaComponent(0.06)

    /// Real Liquid Glass material, behind the color fill. Shows through at
    /// rest, fades out on focus (matches HeroPillButton/HeroCircleButton).
    private let materialBackground = UIVisualEffectView(effect: UIGlassEffect(style: .regular))

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = restingFill
        layer.cornerCurve = .continuous

        materialBackground.translatesAutoresizingMaskIntoConstraints = false
        materialBackground.isUserInteractionEnabled = false
        insertSubview(materialBackground, at: 0)
        NSLayoutConstraint.activate([
            materialBackground.topAnchor.constraint(equalTo: topAnchor),
            materialBackground.bottomAnchor.constraint(equalTo: bottomAnchor),
            materialBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialBackground.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        addTarget(self, action: #selector(primary), for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        materialBackground.layer.cornerRadius = layer.cornerRadius
        materialBackground.layer.cornerCurve = .continuous
        materialBackground.clipsToBounds = true
    }

    @objc private func primary() { fireOnce() }

    // A bare UIControl's primaryActionTriggered misses Select on tvOS, so presses fire
    // too, debounced against double-firing.
    private var lastFireTime: CFTimeInterval = 0
    private func fireOnce() {
        let now = CACurrentMediaTime()
        guard now - lastFireTime > 0.3 else { return }
        lastFireTime = now
        onPrimaryAction?()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { return }
        super.pressesBegan(presses, with: event)
    }
    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if presses.contains(where: { $0.type == .select }) { fireOnce(); return }
        super.pressesEnded(presses, with: event)
    }

    override var canBecomeFocused: Bool { true }

    /// The detail pages' pill: icon and title, white until focus inverts them.
    static func pill(title: String, systemImage: String?) -> (button: FocusableActionButton, title: UILabel, icon: UIImageView) {
        let pill = FocusableActionButton()
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.layer.cornerRadius = HeroPillButton.buttonHeight / 2
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        let icon = UIImageView(image: systemImage.flatMap { UIImage(systemName: $0) })
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = HeroPillButton.titleFont
        label.textColor = .white
        label.text = title
        pill.addSubview(icon)
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: HeroPillButton.buttonHeight),
            icon.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: HeroPillButton.sidePadding),
            icon.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: HeroPillButton.iconGap),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -HeroPillButton.sidePadding),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        pill.invertOnFocus = [icon, label]
        return (pill, label, icon)
    }

    /// The detail pages' round icon button.
    static func circle(systemImage: String) -> FocusableActionButton {
        let b = FocusableActionButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        b.layer.cornerRadius = HeroPillButton.buttonHeight / 2
        let icon = UIImageView(image: UIImage(systemName: systemImage))
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.tintColor = .white
        icon.contentMode = .scaleAspectFit
        b.addSubview(icon)
        NSLayoutConstraint.activate([
            b.widthAnchor.constraint(equalToConstant: HeroPillButton.buttonHeight),
            b.heightAnchor.constraint(equalToConstant: HeroPillButton.buttonHeight),
            icon.centerXAnchor.constraint(equalTo: b.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: b.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
        ])
        b.invertOnFocus = [icon]
        return b
    }

    /// Swaps a `circle`'s glyph.
    func setIcon(_ systemImage: String) {
        (subviews.compactMap { $0 as? UIImageView }.first)?.image = UIImage(systemName: systemImage)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        let focused = context.nextFocusedView === self
        if focusStyle == .glass {
            // Glass: content stays white; soften the fill, add a hairline border,
            // gentle 1.02 scale (the app's glass-row convention). No invert.
            coordinator.addCoordinatedAnimations { [weak self] in
                guard let self else { return }
                self.transform = focused ? CGAffineTransform(scaleX: 1.02, y: 1.02) : .identity
                self.backgroundColor = focused
                    ? UIColor.white.withAlphaComponent(0.18)
                    : self.glassRestingFill
                self.materialBackground.alpha = focused ? 0 : 1
                self.layer.borderWidth = 1
                self.layer.borderColor = (focused
                    ? UIColor.white.withAlphaComponent(0.25)
                    : UIColor.white.withAlphaComponent(0.08)).cgColor
            }
            return
        }
        coordinator.addCoordinatedAnimations { [weak self] in
            guard let self else { return }
            self.transform = focused
                ? CGAffineTransform(scaleX: HeroPillButton.focusScale, y: HeroPillButton.focusScale) : .identity
            self.backgroundColor = focused ? .white : self.restingFill
            self.materialBackground.alpha = focused ? 0 : 1
            for v in self.invertOnFocus {
                if let iv = v as? UIImageView { iv.tintColor = focused ? .black : .white }
                if let lb = v as? UILabel { lb.textColor = focused ? .black : .white }
            }
            for v in self.invertBackgroundOnFocus {
                v.backgroundColor = focused
                    ? UIColor.black.withAlphaComponent(0.2)
                    : UIColor.white.withAlphaComponent(0.5)
            }
            for v in self.invertFillOnFocus {
                v.backgroundColor = focused
                    ? UIColor.black.withAlphaComponent(0.7)
                    : UIColor.white
            }
        }
    }
}
