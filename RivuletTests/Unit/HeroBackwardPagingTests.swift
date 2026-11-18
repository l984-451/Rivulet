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

    @Test func swipeThatKeepsGoingPassesPlayOnce() {
        let row = HeroButtonRowView()
        row.canRetreat = true

        // A swipe that stops on Play asks for nothing more; a later gesture is a fresh one.
        row.noteArrival(gesture: 1, fromRow: true)
        #expect(row.passesPlay(gesture: 2) == false)

        // The same gesture asking for another Left carries past Play, once.
        row.noteArrival(gesture: 3, fromRow: true)
        #expect(row.passesPlay(gesture: 3))
        #expect(row.passesPlay(gesture: 3) == false)
        #expect(row.consumeBackwardPaging(from: row.playButton, heading: .left, gesture: 3))
    }

    @Test func swipeDoesNotPassPlayOnTheFirstItem() {
        let row = HeroButtonRowView()
        row.noteArrival(gesture: 1, fromRow: true)
        #expect(row.passesPlay(gesture: 1) == false)
    }

    @Test func swipeUpFromTheShelvesDoesNotPassPlay() {
        let row = HeroButtonRowView()
        row.canRetreat = true
        row.noteArrival(gesture: 1, fromRow: false)
        #expect(row.passesPlay(gesture: 1) == false)
    }

    @Test func swipeThatKeepsGoingPassesNextOnce() {
        let row = HeroButtonRowView()
        row.canAdvance = true

        row.noteArrival(gesture: 1, fromRow: true)
        #expect(row.passesNext(gesture: 2) == false)

        row.noteArrival(gesture: 3, fromRow: true)
        #expect(row.passesNext(gesture: 3))
        #expect(row.passesNext(gesture: 3) == false)

        row.canAdvance = false
        row.noteArrival(gesture: 4, fromRow: true)
        #expect(row.passesNext(gesture: 4) == false)
    }
}
