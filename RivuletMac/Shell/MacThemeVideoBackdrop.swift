// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import AppKit
import SwiftUI

/// The muted looping theme video over a page's artwork. `isActive` is "visible and settled";
/// the system's video-preview setting and the app's foreground state are handled by `ThemeBackdrop`.
struct MacThemeVideoBackdrop: NSViewRepresentable {
    let item: MediaItemRef?
    let isActive: Bool
    /// True while the player covers the window.
    let isCovered: Bool

    func makeNSView(context: Context) -> HostView { HostView() }

    func updateNSView(_ view: HostView, context: Context) {
        view.covered = isCovered
        view.backdrop.item = item
        view.backdrop.isActive = isActive
    }

    @MainActor
    final class HostView: NSView {
        let backdrop = ThemeBackdrop()
        var covered = false

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.masksToBounds = true
            layer?.addSublayer(backdrop.layer)
            backdrop.isCovered = { [weak self] in self?.covered ?? true }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            backdrop.refresh()
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backdrop.layer.frame = bounds
            CATransaction.commit()
        }
    }
}
