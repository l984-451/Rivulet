// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Testing
import UIKit
@testable import Rivulet

@MainActor
struct NativeFocusScrollCoordinatorTests {
    private final class ScrollSpy: UIScrollView {
        var animatedOffsets: [CGPoint] = []
        var immediateOffsets: [CGPoint] = []

        override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
            if animated {
                animatedOffsets.append(contentOffset)
            } else {
                immediateOffsets.append(contentOffset)
                super.setContentOffset(contentOffset, animated: false)
            }
        }
    }

    @MainActor
    private final class Harness {
        let scroll = ScrollSpy(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        let item = UIView(frame: CGRect(x: 0, y: 100, width: 260, height: 400))
        var pending: [@MainActor () -> Void] = []
        lazy var coordinator = NativeFocusScrollCoordinator(scrollView: scroll) { [weak self] action in
            self?.pending.append(action)
        }

        init() {
            scroll.contentSize = CGSize(width: 1920, height: 6000)
            scroll.addSubview(item)
        }

        func finishFocusUpdate() {
            let actions = pending
            pending.removeAll()
            actions.forEach { $0() }
        }
    }

    @Test func engineScrollDoesNotStartACompetingAnimator() {
        let h = Harness()
        let target = CGPoint(x: 0, y: 500)
        h.coordinator.focusChanged(to: h.item, target: target)
        let destination = h.coordinator.targetContentOffset(proposed: CGPoint(x: 0, y: 300), preferred: target)
        h.finishFocusUpdate()
        #expect(destination == target)
        #expect(h.scroll.animatedOffsets.isEmpty)
    }

    @Test func acceptedNativeDestinationInvalidatesADifferingQueuedFallback() {
        let h = Harness()
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 500))
        let nativeTarget = CGPoint(x: 0, y: 900)
        let destination = h.coordinator.targetContentOffset(proposed: .zero, preferred: nativeTarget)
        #expect(destination == nativeTarget)
        #expect(h.coordinator.targetOffset == nativeTarget)
        let writes = h.scroll.immediateOffsets.count
        h.finishFocusUpdate()
        #expect(h.coordinator.targetOffset == nativeTarget)
        #expect(h.scroll.animatedOffsets.isEmpty)
        #expect(h.scroll.immediateOffsets.count == writes)
    }

    @Test func subsequentFocusDoesNotReplaceAnActiveEngineScroll() {
        let h = Harness()
        let target = CGPoint(x: 0, y: 500)
        _ = h.coordinator.targetContentOffset(proposed: .zero, preferred: target)
        h.coordinator.focusChanged(to: h.item, target: target)
        h.finishFocusUpdate()
        h.coordinator.focusChanged(to: h.item, target: target)
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets.isEmpty)
    }

    @Test func engineCallbackMayPrecedeFocusBookkeeping() {
        let h = Harness()
        let target = CGPoint(x: 0, y: 500)
        _ = h.coordinator.targetContentOffset(proposed: .zero, preferred: target)
        h.coordinator.focusChanged(to: h.item, target: target)
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets.isEmpty)
    }

    @Test func visibleItemStillReachesItsAppDefinedRest() {
        let h = Harness()
        let target = CGPoint(x: 0, y: 100)
        h.coordinator.focusChanged(to: h.item, target: target)
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets == [target])
    }

    @Test func rapidFocusChangesOnlyApplyTheLatestDestination() {
        let h = Harness()
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 500))
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 900))
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets == [CGPoint(x: 0, y: 900)])
    }

    @Test func explicitRestoreInvalidatesQueuedFocusScroll() {
        let h = Harness()
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 500))
        h.coordinator.scroll(to: CGPoint(x: 0, y: 80), animated: false)
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets.isEmpty)
        #expect(h.scroll.contentOffset.y == 80)
    }

    @Test func explicitKeyboardHandoffKeepsScrollingAfterFocusLeaves() {
        let h = Harness()
        let target = CGPoint(x: 0, y: 500)
        h.coordinator.scroll(to: target, animated: true)
        let writes = h.scroll.immediateOffsets.count
        h.coordinator.focusChanged(to: nil, target: nil)
        h.finishFocusUpdate()
        #expect(h.coordinator.targetOffset == target)
        #expect(h.scroll.immediateOffsets.count == writes)
    }

    @Test func newFocusCanReplaceAnExplicitScroll() {
        let h = Harness()
        h.coordinator.scroll(to: CGPoint(x: 0, y: 500), animated: true)
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 900))
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets.last == CGPoint(x: 0, y: 900))
        h.coordinator.focusChanged(to: nil, target: nil)
        #expect(h.coordinator.targetOffset == CGPoint(x: 0, y: 900))
        h.scroll.contentOffset.y = 900
        h.coordinator.didEndScrolling()
        #expect(h.coordinator.targetOffset == nil)
    }

    @Test func focusLeavingThePageCancelsQueuedMovement() {
        let h = Harness()
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 500))
        h.coordinator.focusChanged(to: nil, target: nil)
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets.isEmpty)
        #expect(h.coordinator.targetOffset == nil)
    }

    @Test func detachedItemCannotStartAQueuedScroll() {
        let h = Harness()
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 500))
        h.item.removeFromSuperview()
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets.isEmpty)
        #expect(h.coordinator.targetOffset == nil)
        h.coordinator.settle()
        #expect(h.scroll.contentOffset == .zero)
    }

    @Test func suspendedFocusScrollingDoesNotWriteDuringCustomMotion() {
        let h = Harness()
        h.scroll.isScrollEnabled = false
        h.scroll.immediateOffsets.removeAll()
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 500))
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets.isEmpty)
        #expect(h.scroll.immediateOffsets.isEmpty)
    }

    @Test func snapshotShiftTranslatesTheInFlightDestination() {
        let h = Harness()
        _ = h.coordinator.targetContentOffset(proposed: .zero, preferred: CGPoint(x: 0, y: 600))
        h.scroll.contentOffset.y = 200
        h.coordinator.shiftOffset(to: CGPoint(x: 0, y: 250))
        #expect(h.scroll.contentOffset.y == 250)
        #expect(h.scroll.animatedOffsets == [CGPoint(x: 0, y: 650)])
        #expect(h.coordinator.targetOffset?.y == 650)
    }

    @Test func interruptedNativeScrollCanRetryItsDestination() {
        let h = Harness()
        let target = CGPoint(x: 0, y: 500)
        _ = h.coordinator.targetContentOffset(proposed: .zero, preferred: target)
        h.scroll.contentOffset.y = 100
        h.coordinator.didEndScrolling()
        h.coordinator.focusChanged(to: h.item, target: target)
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets == [target])
    }

    @Test func oldCompletionCannotClearARetargetedScroll() {
        let h = Harness()
        h.coordinator.scroll(to: CGPoint(x: 0, y: 500), animated: true)
        h.coordinator.scroll(to: CGPoint(x: 0, y: 900), animated: true)
        h.scroll.contentOffset.y = 500
        h.coordinator.didEndScrolling()
        #expect(h.coordinator.targetOffset?.y == 900)
        h.scroll.contentOffset.y = 900
        h.coordinator.didEndScrolling()
        #expect(h.coordinator.targetOffset == nil)
    }

    @Test func horizontalFocusDoesNotRestartTheFallbackScroll() {
        let h = Harness()
        let other = UIView()
        h.scroll.addSubview(other)
        let target = CGPoint(x: 0, y: 500)
        h.coordinator.focusChanged(to: h.item, target: target)
        h.finishFocusUpdate()
        let writes = h.scroll.immediateOffsets.count
        h.coordinator.focusChanged(to: other, target: target)
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets == [target])
        #expect(h.scroll.immediateOffsets.count == writes)
    }

    @Test func horizontalFocusAtRestDoesNotWriteAnOffset() {
        let h = Harness()
        h.scroll.contentOffset.y = 500
        let writes = h.scroll.immediateOffsets.count
        h.coordinator.focusChanged(to: h.item, target: h.scroll.contentOffset)
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets.isEmpty)
        #expect(h.scroll.immediateOffsets.count == writes)
    }

    @Test func nativeCompletionClearsAnUnreachedDestination() {
        let h = Harness()
        _ = h.coordinator.targetContentOffset(proposed: .zero, preferred: CGPoint(x: 0, y: 500))
        h.scroll.contentOffset.y = 450
        h.coordinator.didEndScrolling()
        #expect(h.coordinator.targetOffset == nil)
    }

    @Test func shrinkingContentCannotLeaveAnUnreachableProgrammaticTarget() {
        let h = Harness()
        h.coordinator.scroll(to: CGPoint(x: 0, y: 500), animated: true)
        h.scroll.contentSize.height = 1200
        h.scroll.contentOffset.y = 120
        h.coordinator.didEndScrolling()
        #expect(h.coordinator.targetOffset == nil)
    }

    @Test func disappearingPageSettlesAtTheClampedDestination() {
        let h = Harness()
        h.coordinator.scroll(to: CGPoint(x: 0, y: 500), animated: true)
        h.scroll.contentOffset.y = 200
        h.scroll.contentSize.height = 1400
        h.coordinator.settle()
        #expect(h.scroll.contentOffset.y == 320)
        #expect(h.coordinator.targetOffset == nil)
    }

    @Test func horizontalMoveWithoutDecelerationClearsTheLateNativeRequest() {
        let h = Harness()
        let target = CGPoint(x: 0, y: 500)
        _ = h.coordinator.targetContentOffset(proposed: .zero, preferred: target)
        h.scroll.contentOffset = target
        h.coordinator.didEndScrolling()

        h.coordinator.focusChanged(to: h.item, target: target)
        h.finishFocusUpdate()
        #expect(h.coordinator.targetOffset == nil)
        _ = h.coordinator.targetContentOffset(proposed: target, preferred: target)
        #expect(h.coordinator.targetOffset == target)
        h.coordinator.didEndDragging(willDecelerate: false)

        #expect(h.coordinator.targetOffset == nil)
        #expect(h.scroll.animatedOffsets.isEmpty)
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 900))
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets == [CGPoint(x: 0, y: 900)])
    }

    @Test func dragCompletionWaitsForNativeDeceleration() {
        let h = Harness()
        let target = CGPoint(x: 0, y: 500)
        _ = h.coordinator.targetContentOffset(proposed: .zero, preferred: target)
        h.coordinator.didEndDragging(willDecelerate: true)
        #expect(h.coordinator.targetOffset == target)
        h.scroll.contentOffset = target
        h.coordinator.didEndScrolling()
        #expect(h.coordinator.targetOffset == nil)
    }

    @Test func nondeceleratingDragCompletionDoesNotCancelAnActiveFallback() {
        let h = Harness()
        let target = CGPoint(x: 0, y: 500)
        h.coordinator.focusChanged(to: h.item, target: target)
        h.finishFocusUpdate()
        h.coordinator.didEndDragging(willDecelerate: false)
        #expect(h.coordinator.targetOffset == target)
        #expect(h.scroll.animatedOffsets == [target])
    }

    @Test func focusLeavingDuringNativeScrollDoesNotSnapOrCancelIt() {
        let h = Harness()
        let target = CGPoint(x: 0, y: 500)
        _ = h.coordinator.targetContentOffset(proposed: .zero, preferred: target)
        h.scroll.contentOffset.y = 200
        let writes = h.scroll.immediateOffsets.count
        h.coordinator.focusChanged(to: nil, target: nil)
        h.finishFocusUpdate()
        #expect(h.scroll.contentOffset.y == 200)
        #expect(h.scroll.immediateOffsets.count == writes)
        #expect(h.coordinator.targetOffset == target)
        h.scroll.contentOffset = target
        h.coordinator.didEndScrolling()
        #expect(h.coordinator.targetOffset == nil)
    }

    @Test func unresolvedNestedFocusDoesNotSnapBeforeItsReveal() {
        let h = Harness()
        h.coordinator.scroll(to: CGPoint(x: 0, y: 500), animated: true)
        h.scroll.contentOffset.y = 200
        let writes = h.scroll.immediateOffsets.count
        h.coordinator.focusChanged(to: h.item, target: nil)
        #expect(h.scroll.contentOffset.y == 200)
        #expect(h.scroll.immediateOffsets.count == writes)
        h.coordinator.scroll(to: CGPoint(x: 0, y: 700), animated: true)
        #expect(h.scroll.animatedOffsets.last == CGPoint(x: 0, y: 700))
    }

    @Test func nativeTakeoverWithoutARestingTargetReleasesTheInterruptedRequest() {
        let h = Harness()
        let target = CGPoint(x: 0, y: 500)
        h.coordinator.focusChanged(to: h.item, target: target)
        h.finishFocusUpdate()
        h.scroll.contentOffset.y = 200
        let writes = h.scroll.immediateOffsets.count
        let proposed = CGPoint(x: 0, y: 300)
        #expect(h.coordinator.targetContentOffset(proposed: proposed, preferred: nil) == proposed)
        #expect(h.coordinator.targetOffset == nil)
        #expect(h.scroll.immediateOffsets.count == writes)
        h.scroll.contentOffset = proposed
        h.coordinator.didEndScrolling()

        h.coordinator.focusChanged(to: h.item, target: target)
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets == [target, target])
    }

    @Test func nativeTakeoverWithoutARestingTargetInvalidatesTheQueuedFallback() {
        let h = Harness()
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 500))
        _ = h.coordinator.targetContentOffset(proposed: CGPoint(x: 0, y: 300), preferred: nil)
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets.isEmpty)
        #expect(h.coordinator.targetOffset == nil)
    }

    @Test func disabledScrollingDropsTheQueuedDestinationWithoutWriting() {
        let h = Harness()
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 500))
        h.scroll.isScrollEnabled = false
        let writes = h.scroll.immediateOffsets.count
        h.finishFocusUpdate()
        #expect(h.coordinator.targetOffset == nil)
        #expect(h.scroll.animatedOffsets.isEmpty)
        #expect(h.scroll.immediateOffsets.count == writes)
    }

    @Test func deallocatedFocusViewDropsTheQueuedDestination() {
        let h = Harness()
        var item: UIView? = UIView()
        if let item { h.scroll.addSubview(item) }
        h.coordinator.focusChanged(to: item, target: CGPoint(x: 0, y: 500))
        item?.removeFromSuperview()
        item = nil
        h.finishFocusUpdate()
        #expect(h.coordinator.targetOffset == nil)
        #expect(h.scroll.animatedOffsets.isEmpty)
    }

    @Test func obsoleteInvalidRequestCannotClearANewerScroll() {
        let h = Harness()
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 500))
        h.item.removeFromSuperview()
        let next = UIView()
        h.scroll.addSubview(next)
        let target = CGPoint(x: 0, y: 900)
        h.coordinator.focusChanged(to: next, target: target)
        h.finishFocusUpdate()
        #expect(h.coordinator.targetOffset == target)
        #expect(h.scroll.animatedOffsets == [target])
    }

    @Test func equivalentOutOfBoundsTargetsKeepTheSameAnimationAndState() {
        let h = Harness()
        let end = CGPoint(x: 0, y: h.scroll.contentSize.height - h.scroll.bounds.height)
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 10000))
        #expect(h.coordinator.targetOffset == end)
        h.finishFocusUpdate()
        let writes = h.scroll.immediateOffsets.count
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 12000))
        h.finishFocusUpdate()
        #expect(h.coordinator.targetOffset == end)
        #expect(h.scroll.animatedOffsets == [end])
        #expect(h.scroll.immediateOffsets.count == writes)
    }

    @Test func nativeAndFallbackRequestsUseTheSameClampedDestination() {
        let h = Harness()
        let end = CGPoint(x: 0, y: h.scroll.contentSize.height - h.scroll.bounds.height)
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 10000))
        let result = h.coordinator.targetContentOffset(proposed: .zero, preferred: CGPoint(x: 0, y: 12000))
        h.finishFocusUpdate()
        #expect(result == end)
        #expect(h.coordinator.targetOffset == end)
        #expect(h.scroll.animatedOffsets.isEmpty)
    }

    @Test func retargetingAnActiveFallbackDoesNotWriteAnIntermediateStop() {
        let h = Harness()
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 500))
        h.finishFocusUpdate()
        h.scroll.contentOffset.y = 200
        let writes = h.scroll.immediateOffsets.count
        h.coordinator.focusChanged(to: h.item, target: CGPoint(x: 0, y: 900))
        h.finishFocusUpdate()
        #expect(h.scroll.immediateOffsets.count == writes)
        #expect(h.scroll.animatedOffsets == [CGPoint(x: 0, y: 500), CGPoint(x: 0, y: 900)])
        #expect(h.coordinator.targetOffset?.y == 900)
    }

    @Test func shortPageRestoreAndFocusUseTheSameInsetAdjustedRest() {
        let h = Harness()
        h.scroll.contentSize.height = 1000
        h.scroll.contentInset = UIEdgeInsets(top: 300, left: 0, bottom: 50, right: 0)
        let rest = h.coordinator.clamped(.zero)
        #expect(rest.y == -30)
        h.coordinator.scroll(to: rest, animated: false)
        h.coordinator.focusChanged(to: h.item, target: .zero)
        h.finishFocusUpdate()
        #expect(h.scroll.contentOffset == rest)
        #expect(h.scroll.animatedOffsets.isEmpty)
        #expect(h.coordinator.targetContentOffset(proposed: .zero, preferred: .zero) == rest)
    }

    @Test func oldNativeCompletionPreservesTheNewerQueuedFocusRequest() {
        let h = Harness()
        let old = CGPoint(x: 0, y: 500)
        let next = CGPoint(x: 0, y: 900)
        _ = h.coordinator.targetContentOffset(proposed: .zero, preferred: old)
        h.scroll.contentOffset = old
        h.coordinator.focusChanged(to: h.item, target: next)
        h.coordinator.didEndScrolling()
        #expect(h.coordinator.targetOffset == next)
        #expect(h.scroll.animatedOffsets.isEmpty)
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets == [next])
        #expect(h.coordinator.targetOffset == next)
    }

    @Test func oldProgrammaticCompletionPreservesTheNewerQueuedFocusRequest() {
        let h = Harness()
        let old = CGPoint(x: 0, y: 500)
        let next = CGPoint(x: 0, y: 900)
        h.coordinator.scroll(to: old, animated: true)
        h.scroll.contentOffset = old
        h.coordinator.focusChanged(to: h.item, target: next)
        h.coordinator.didEndScrolling()
        #expect(h.coordinator.targetOffset == next)
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets == [old, next])
        #expect(h.coordinator.targetOffset == next)
    }

    @Test func nondeceleratingCompletionPreservesTheNewerQueuedFocusRequest() {
        let h = Harness()
        let old = CGPoint(x: 0, y: 500)
        let next = CGPoint(x: 0, y: 900)
        _ = h.coordinator.targetContentOffset(proposed: .zero, preferred: old)
        h.scroll.contentOffset = old
        h.coordinator.focusChanged(to: h.item, target: next)
        h.coordinator.didEndDragging(willDecelerate: false)
        #expect(h.coordinator.targetOffset == next)
        h.finishFocusUpdate()
        #expect(h.scroll.animatedOffsets == [next])
    }
}
