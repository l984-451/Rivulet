// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import SwiftUI

/// The muted looping theme video over a page's artwork. `isActive` is "this page is visible and
/// settled"; the system's video-preview and Reduce Motion settings, a presented player or sheet,
/// and the app leaving the foreground are handled by `ThemeBackdrop`.
struct IOSThemeVideoBackdrop: UIViewRepresentable {
    let item: MediaItemRef?
    let isActive: Bool

    func makeUIView(context: Context) -> HostView { HostView() }

    func updateUIView(_ view: HostView, context: Context) {
        view.backdrop.item = item
        view.backdrop.isActive = isActive
    }

    @MainActor
    final class HostView: UIView {
        let backdrop = ThemeBackdrop()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            isAccessibilityElement = false
            clipsToBounds = true
            layer.addSublayer(backdrop.layer)
            backdrop.isCovered = { [weak self] in
                self?.window.map { ThemeBackdrop.isCovered($0.rootViewController) } ?? true
            }
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

        override func didMoveToWindow() {
            super.didMoveToWindow()
            backdrop.refresh()
        }
    }
}
