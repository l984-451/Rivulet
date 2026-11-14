// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import UIKit

@MainActor
final class NativeFocusScrollCoordinator {
    typealias Schedule = (@escaping @MainActor () -> Void) -> Void

    private weak var scrollView: UIScrollView?
    private let schedule: Schedule
    private var generation: UInt = 0
    private var pendingFocusTarget: CGPoint?
    private var nativeFocusTarget: CGPoint?
    private var programmaticTarget: CGPoint?

    var targetOffset: CGPoint? { pendingFocusTarget ?? programmaticTarget ?? nativeFocusTarget }

    init(scrollView: UIScrollView, schedule: @escaping Schedule = { action in
        DispatchQueue.main.async { action() }
    }) {
        self.scrollView = scrollView
        self.schedule = schedule
    }

    // Keep ordinary focus movement in UIKit's animator so collection views can
    // prepare upcoming cells during idle time.
    func focusChanged(to view: UIView?, target: CGPoint?) {
        invalidatePendingFocus()
        guard let scrollView, scrollView.isScrollEnabled else {
            clearFocusRequest()
            return
        }
        guard let view, view.isDescendant(of: scrollView), let requested = target else {
            if nativeFocusTarget != nil || programmaticTarget != nil { return }
            clearFocusRequest()
            return
        }
        let target = clamped(requested)
        if programmaticTarget == target { return }
        if targetOffset == nil, hasReached(target) { return }
        pendingFocusTarget = target
        let request = generation
        // Defer the fallback past this callback so UIKit can supply its own
        // destination first, including for an already-visible item.
        schedule { [weak self, weak view] in
            guard let self, self.generation == request else { return }
            guard let scrollView = self.scrollView, scrollView.isScrollEnabled,
                  let view, view.isDescendant(of: scrollView) else {
                self.pendingFocusTarget = nil
                return
            }
            self.pendingFocusTarget = nil
            if self.nativeFocusTarget == target {
                if self.hasReached(target) { self.didEndScrolling() }
                return
            }
            if self.targetOffset == nil, self.hasReached(target) { return }
            self.scroll(to: target, animated: true)
        }
    }

    func targetContentOffset(proposed: CGPoint, preferred: CGPoint?) -> CGPoint {
        guard scrollView?.isScrollEnabled == true else { return proposed }
        guard let requested = preferred else {
            clearFocusRequest()
            return proposed
        }
        let preferred = clamped(requested)
        if let pendingFocusTarget, pendingFocusTarget != preferred {
            invalidatePendingFocus()
        }
        nativeFocusTarget = preferred
        programmaticTarget = nil
        return preferred
    }

    func scroll(to offset: CGPoint, animated: Bool) {
        guard let scrollView else { return }
        invalidatePendingFocus()
        let offset = clamped(offset)
        if animated, programmaticTarget == offset {
            return
        }
        if animated, programmaticTarget != nil {
            clearFocusRequest()
        } else {
            cancel()
        }
        let animate = animated && !hasReached(offset)
        programmaticTarget = animate ? offset : nil
        scrollView.setContentOffset(offset, animated: animate)
    }

    func shiftOffset(to offset: CGPoint) {
        guard let scrollView else { return }
        let delta = CGPoint(x: offset.x - scrollView.contentOffset.x,
                            y: offset.y - scrollView.contentOffset.y)
        let destination = targetOffset.map { CGPoint(x: $0.x + delta.x, y: $0.y + delta.y) }
        scroll(to: offset, animated: false)
        if let destination {
            scroll(to: destination, animated: true)
        }
    }

    func didEndDragging(willDecelerate: Bool) {
        if !willDecelerate { didEndScrolling() }
    }

    func didEndScrolling() {
        nativeFocusTarget = nil
        if let target = programmaticTarget, hasReached(target) || clamped(target) != target {
            programmaticTarget = nil
        }
    }

    func clamped(_ offset: CGPoint) -> CGPoint {
        guard let scrollView else { return offset }
        let inset = scrollView.adjustedContentInset
        let maxX = max(-inset.left, scrollView.contentSize.width - scrollView.bounds.width + inset.right)
        let maxY = max(-inset.top, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom)
        return CGPoint(x: max(-inset.left, min(offset.x, maxX)),
                       y: max(-inset.top, min(offset.y, maxY)))
    }

    private func hasReached(_ offset: CGPoint) -> Bool {
        guard let scrollView else { return false }
        return abs(scrollView.contentOffset.x - offset.x) <= 0.5
            && abs(scrollView.contentOffset.y - offset.y) <= 0.5
    }

    private func invalidatePendingFocus() {
        generation &+= 1
        pendingFocusTarget = nil
    }

    func clearFocusRequest() {
        invalidatePendingFocus()
        nativeFocusTarget = nil
        programmaticTarget = nil
    }

    func cancel() {
        clearFocusRequest()
        guard let scrollView else { return }
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
    }

    func settle() {
        guard let scrollView else {
            clearFocusRequest()
            return
        }
        let offset = clamped(targetOffset ?? scrollView.contentOffset)
        clearFocusRequest()
        scrollView.setContentOffset(offset, animated: false)
    }
}
