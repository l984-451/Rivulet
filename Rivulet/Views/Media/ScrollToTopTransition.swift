// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

@MainActor
enum ScrollToTopTransition {
    /// Settle layout and focus first, then draw the scroll on presentation layers.
    /// Animating the offset itself lets the focus engine land on a passing row.
    static func perform(in scrollView: UIScrollView, updates: () -> Void, completion: @escaping () -> Void = {}) {
        let distance = min(scrollView.contentOffset.y + scrollView.adjustedContentInset.top, scrollView.bounds.height)
        let snapshot = distance > 1 && !UIAccessibility.isReduceMotionEnabled
            ? scrollView.snapshotView(afterScreenUpdates: false) : nil
        updates()
        guard let snapshot, let container = scrollView.superview else { completion(); return }
        snapshot.frame = scrollView.frame
        container.insertSubview(snapshot, aboveSubview: scrollView)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            snapshot.removeFromSuperview()
            completion()
        }
        for (layer, from, to) in [(scrollView.layer, -distance, 0), (snapshot.layer, 0, distance)] {
            let slide = CABasicAnimation(keyPath: "transform.translation.y")
            slide.fromValue = from
            slide.toValue = to
            slide.duration = 0.35
            slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
            layer.add(slide, forKey: "returnToTop")
        }
        snapshot.layer.transform = CATransform3DMakeTranslation(0, distance, 0)
        CATransaction.commit()
    }
}
