// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PreviewEntrySnapshot.swift
//  Rivulet
//
//  UIKit-only handoff for the row -> preview carousel entrance. The presenter
//  captures visible source tile snapshots before presentation; the carousel VC
//  owns animating those views into its card geometry.
//

import UIKit

@MainActor
struct PreviewEntrySnapshot {
    let itemIndex: Int
    let sourceFrame: CGRect
    let snapshotView: UIView
}

/// Clipping window for a captured tile snapshot during the row -> carousel
/// morph.
///
/// A `snapshotView(afterScreenUpdates:)` stretches its contents to whatever
/// bounds you assign, so animating one straight to the card frame squashes it
/// (a 2:3 poster tile into a ~1.70:1 card is x5.89 across but x2.32 down).
/// The window takes that frame instead; the snapshot inside is aspect-filled
/// and top-anchored, so it scales uniformly and overflows the bottom edge.
///
/// No display link needed: both endpoint content frames satisfy
/// `h = w / aspect`, and linear interpolation preserves that, so the ratio
/// holds at every intermediate frame.
@MainActor
final class EntryMorphWindowView: UIView {

    private let contentAspect: CGFloat
    private let content: UIView

    /// `sourceSize` is the size the snapshot was captured at — its true aspect.
    init(content: UIView, sourceSize: CGSize) {
        self.content = content
        self.contentAspect = sourceSize.height > 0
            ? sourceSize.width / sourceSize.height
            : 1
        super.init(frame: CGRect(origin: .zero, size: sourceSize))
        clipsToBounds = true
        layer.cornerCurve = .continuous
        content.removeFromSuperview()
        addSubview(content)
        setWindow(CGRect(origin: .zero, size: sourceSize))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not Storyboard-backed") }

    /// Call inside an animation block — both frames tween on that curve.
    func setWindow(_ rect: CGRect) {
        frame = rect
        content.frame = Self.contentFrame(inWindowOfSize: rect.size, aspect: contentAspect)
    }

    /// Aspect-fill, anchored to the window's top edge so growth spills off the
    /// bottom.
    static func contentFrame(inWindowOfSize size: CGSize, aspect: CGFloat) -> CGRect {
        guard size.width > 0, size.height > 0, aspect > 0 else {
            return CGRect(origin: .zero, size: size)
        }
        let width = size.width >= size.height * aspect
            ? size.width
            : size.height * aspect
        let height = width / aspect
        return CGRect(
            x: (size.width - width) / 2,
            y: 0,
            width: width,
            height: height
        )
    }
}
