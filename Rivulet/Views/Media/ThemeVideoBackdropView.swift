// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// Hosts `ThemeBackdrop`'s layer over the artwork. Not a player, and not AetherPlayer.
@MainActor
final class ThemeVideoBackdropView: UIView {
    let backdrop: ThemeBackdrop

    init(frame: CGRect = .zero, backdrop: ThemeBackdrop? = nil) {
        self.backdrop = backdrop ?? ThemeBackdrop()
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        clipsToBounds = true
        layer.addSublayer(self.backdrop.layer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.layer.frame = bounds
        CATransaction.commit()
    }

    /// The title whose clip plays, and the controller whose presentations cover this page.
    func configure(item: MediaItemRef?, host: UIViewController?) {
        backdrop.isCovered = { [weak host] in host.map { ThemeBackdrop.isCovered($0) } ?? true }
        backdrop.item = item
    }

    func setActive(_ active: Bool) { backdrop.isActive = active }
    func setSuspended(_ suspended: Bool) { backdrop.isSuspended = suspended }
}
