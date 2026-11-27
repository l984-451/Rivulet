// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

/// Holds a video surface so it can be moved without its host laying it out again.
/// SwiftUI sizes this view; the surface inside fills it, and Picture Position moves
/// the surface by a transform.
final class VideoSurfaceContainerView<Surface: UIView>: UIView {
    let surface: Surface

    init(surface: Surface) {
        self.surface = surface
        super.init(frame: .zero)
        addSubview(surface)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Bounds and centre, not frame: the surface carries a transform.
        surface.bounds = bounds
        surface.center = CGPoint(x: bounds.midX, y: bounds.midY)
    }
}

/// Moves the playing video surface up or down for Picture Position. The surface
/// changes with the route (the engine's view, the HLS player's), so each one
/// attaches as it is made and takes the shift already in force.
@MainActor
final class VideoSurfaceMover {
    private weak var surface: UIView?
    private(set) var shift: CGFloat = 0

    func attach(_ surface: UIView) {
        self.surface = surface
        surface.transform = CGAffineTransform(translationX: 0, y: shift)
    }

    /// Sets the shift. Call inside an animation block to animate it.
    func set(shift: CGFloat) {
        self.shift = shift
        surface?.transform = CGAffineTransform(translationX: 0, y: shift)
    }
}
