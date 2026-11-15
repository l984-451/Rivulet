// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Testing
import UIKit
@testable import Rivulet

@MainActor
struct HeroBackwardPagingTests {
    @Test func pagingFadePreservesButtonFocusEligibility() {
        let row = HeroButtonRowView()
        row.canAdvance = true
        row.setSecondaryButtonsFocusable(true)
        let buttons: [UIControl] = [row.playButton, row.watchlistButton, row.infoButton, row.nextButton]

        for visible in [false, true, false] {
            row.setPagingVisible(visible)
            for button in buttons {
                #expect(button.canBecomeFocused)
                #expect(button.isHidden == false)
                var view: UIView? = button
                while let current = view {
                    #expect(current.alpha == 1)
                    #expect(current.isUserInteractionEnabled)
                    view = current.superview
                }
            }
        }
        row.setPagingVisible(true, animated: false)
        #expect(row.subviews.allSatisfy { $0.layer.animation(forKey: "heroPagingOpacity") == nil })
    }

    @Test func leftFromFirstButtonPagesOncePerGesture() {
        let row = HeroButtonRowView()
        row.canRetreat = true
        var pages = 0
        row.onPrevious = { pages += 1 }

        #expect(row.consumeBackwardPaging(from: row.playButton, heading: .left, gesture: 1))
        #expect(pages == 1)
        #expect(row.consumeBackwardPaging(from: row.playButton, heading: .left, gesture: 1))
        #expect(pages == 1)

        #expect(row.consumeBackwardPaging(from: row.playButton, heading: .left, gesture: 2))
        #expect(pages == 2)

        row.canRetreat = false
        #expect(row.consumeBackwardPaging(from: row.playButton, heading: .left, gesture: 2))
        #expect(row.consumeBackwardPaging(from: row.playButton, heading: .left, gesture: 3) == false)
        #expect(pages == 2)
    }

    @Test func firstItemAllowsSidebarNavigation() {
        let row = HeroButtonRowView()
        var pages = 0
        row.onPrevious = { pages += 1 }

        #expect(row.consumeBackwardPaging(from: row.playButton, heading: .left, gesture: 1) == false)
        #expect(pages == 0)
    }

    @Test func otherButtonsAndDirectionsDoNotPageBackward() {
        let row = HeroButtonRowView()
        row.canRetreat = true
        var pages = 0
        row.onPrevious = { pages += 1 }

        for button in [row.watchlistButton, row.infoButton, row.nextButton] {
            #expect(row.consumeBackwardPaging(from: button, heading: .left, gesture: 1) == false)
        }
        for heading: UIFocusHeading in [.right, .up, .down, []] {
            #expect(row.consumeBackwardPaging(from: row.playButton, heading: heading, gesture: 1) == false)
        }
        #expect(pages == 0)
    }
}
