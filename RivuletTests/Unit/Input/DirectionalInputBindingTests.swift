// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  DirectionalInputBindingTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

@MainActor
final class DirectionalInputBindingTests: XCTestCase {

    private func recognizers<T: UIGestureRecognizer>(_ type: T.Type, on view: UIView) -> [T] {
        (view.gestureRecognizers ?? []).compactMap { $0 as? T }
    }

    // MARK: Installation — both transports, always together

    func test_installsPressTapAndIndirectSwipe_perDirection() {
        let view = UIView()
        let binding = DirectionalInputBinding(view: view, directions: [.up, .down], onTap: { _ in })

        let taps = recognizers(UITapGestureRecognizer.self, on: view)
        let swipes = recognizers(UISwipeGestureRecognizer.self, on: view)
        XCTAssertEqual(taps.count, 2)
        XCTAssertEqual(swipes.count, 2)

        let upTap = taps.first { binding.direction(of: $0) == .up }
        XCTAssertEqual(upTap?.allowedPressTypes, [NSNumber(value: UIPress.PressType.upArrow.rawValue)])

        let upSwipe = swipes.first { binding.direction(of: $0) == .up }
        XCTAssertEqual(upSwipe?.direction, .up)
        XCTAssertEqual(upSwipe?.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.indirect.rawValue)])
        // A tvOS swipe recognizer with default press types waits on a
        // .select press; the binding must clear them.
        XCTAssertEqual(upSwipe?.allowedPressTypes, [])
    }

    func test_holdDirections_getLongPressAtHoldThreshold() {
        let view = UIView()
        let binding = DirectionalInputBinding(
            view: view, directions: [.left, .right], holds: [.left], onTap: { _ in }, onHold: { _ in }
        )

        let longs = recognizers(UILongPressGestureRecognizer.self, on: view)
        XCTAssertEqual(longs.count, 1)
        XCTAssertEqual(binding.direction(of: longs[0]), .left)
        XCTAssertEqual(longs[0].minimumPressDuration, InputConfig.holdThreshold, accuracy: 0.001)
        XCTAssertEqual(longs[0].allowedPressTypes, [NSNumber(value: UIPress.PressType.leftArrow.rawValue)])
    }

    // MARK: Callback funnel — press and swipe reach the same tap callback

    func test_pressTapAndSwipe_fireSameCallbackWithDirection() {
        let view = UIView()
        var fired: [DirectionalInputBinding.Direction] = []
        let binding = DirectionalInputBinding(view: view, directions: [.left, .right], onTap: { fired.append($0) })

        let rightTap = recognizers(UITapGestureRecognizer.self, on: view).first { binding.direction(of: $0) == .right }!
        let leftSwipe = recognizers(UISwipeGestureRecognizer.self, on: view).first { binding.direction(of: $0) == .left }!

        binding.handleTap(rightTap)
        binding.handleSwipe(leftSwipe)
        XCTAssertEqual(fired, [.right, .left])
    }

    func test_hold_firesOnlyOnBegan() {
        let view = UIView()
        var holds: [DirectionalInputBinding.Direction] = []
        let binding = DirectionalInputBinding(
            view: view, directions: [.right], holds: [.right], onTap: { _ in }, onHold: { holds.append($0) }
        )

        let long = recognizers(UILongPressGestureRecognizer.self, on: view)[0]
        binding.handleLong(long)  // state .possible — must not fire
        XCTAssertTrue(holds.isEmpty)
        long.state = .began
        binding.handleLong(long)
        XCTAssertEqual(holds, [.right])
    }

    // MARK: Gated swipes-only variant (focusable surfaces)

    func test_gatedVariant_installsOnlySwipes_withBindingAsDelegate() {
        let view = UIView()
        let binding = DirectionalInputBinding(
            gatedSwipesOn: view, directions: [.up, .down], shouldHandle: { _ in true }, onSwipe: { _ in }
        )

        XCTAssertTrue(recognizers(UITapGestureRecognizer.self, on: view).isEmpty)
        XCTAssertTrue(recognizers(UILongPressGestureRecognizer.self, on: view).isEmpty)
        let swipes = recognizers(UISwipeGestureRecognizer.self, on: view)
        XCTAssertEqual(swipes.count, 2)
        for swipe in swipes {
            XCTAssertTrue(swipe.delegate === binding)
            XCTAssertEqual(swipe.allowedTouchTypes, [NSNumber(value: UITouch.TouchType.indirect.rawValue)])
            XCTAssertEqual(swipe.allowedPressTypes, [])
        }
    }

    func test_gatedVariant_shouldBeginConsultsGateWithDirection() {
        let view = UIView()
        var asked: [DirectionalInputBinding.Direction] = []
        var allow = false
        let binding = DirectionalInputBinding(
            gatedSwipesOn: view, directions: [.up, .down],
            shouldHandle: { asked.append($0); return allow },
            onSwipe: { _ in }
        )

        let upSwipe = recognizers(UISwipeGestureRecognizer.self, on: view).first { binding.direction(of: $0) == .up }!
        XCTAssertFalse(binding.gestureRecognizerShouldBegin(upSwipe))
        allow = true
        XCTAssertTrue(binding.gestureRecognizerShouldBegin(upSwipe))
        XCTAssertEqual(asked, [.up, .up])
    }

    func test_focuslessVariant_shouldBeginAlwaysTrue() {
        let view = UIView()
        let binding = DirectionalInputBinding(view: view, directions: [.left], onTap: { _ in })
        let swipe = recognizers(UISwipeGestureRecognizer.self, on: view)[0]
        XCTAssertTrue(binding.gestureRecognizerShouldBegin(swipe))
    }

    // MARK: Focusless variant with a swipe gate and a hold release

    func test_swipeGate_makesTheBindingTheSwipesDelegate_andLeavesTapsAndHoldsWithout() {
        let view = UIView()
        let binding = DirectionalInputBinding(
            view: view, directions: [.up, .left], holds: [.up], onTap: { _ in }, swipeGate: { _ in true }
        )

        for swipe in recognizers(UISwipeGestureRecognizer.self, on: view) {
            XCTAssertTrue(swipe.delegate === binding)
        }
        XCTAssertEqual(recognizers(UITapGestureRecognizer.self, on: view).count, 2)
        XCTAssertEqual(recognizers(UILongPressGestureRecognizer.self, on: view).count, 1)
        for press in (view.gestureRecognizers ?? []) where !(press is UISwipeGestureRecognizer) {
            XCTAssertNil(press.delegate)
        }
    }

    func test_swipeGate_shouldBegin_returnsTheGatesAnswerPerDirection() {
        let view = UIView()
        let binding = DirectionalInputBinding(
            view: view, directions: [.up, .left], onTap: { _ in }, swipeGate: { $0 == .left }
        )

        let swipes = recognizers(UISwipeGestureRecognizer.self, on: view)
        let up = swipes.first { binding.direction(of: $0) == .up }!
        let left = swipes.first { binding.direction(of: $0) == .left }!
        XCTAssertFalse(binding.gestureRecognizerShouldBegin(up))
        XCTAssertTrue(binding.gestureRecognizerShouldBegin(left))
    }

    // The existing adopters' case: nothing they installed changes.
    func test_withoutSwipeGate_noRecognizerHasADelegate() {
        let view = UIView()
        _ = DirectionalInputBinding(
            view: view, directions: DirectionalInputBinding.Direction.allCases, holds: [.left], onTap: { _ in },
            onHold: { _ in }
        )
        XCTAssertEqual(view.gestureRecognizers?.count, 9)
        for recognizer in view.gestureRecognizers ?? [] { XCTAssertNil(recognizer.delegate) }
    }

    // Through `hold`: UIKit resets a bare recognizer that is set to ended, so its state cannot carry the release.
    func test_holdEnd_firesOnEndedAndCancelled_notOnBegan() {
        var ended: [DirectionalInputBinding.Direction] = []
        let binding = DirectionalInputBinding(
            view: UIView(), directions: [.down], holds: [.down], onTap: { _ in }, onHold: { _ in },
            onHoldEnd: { ended.append($0) }
        )

        binding.hold(.down, .began)
        binding.hold(.down, .changed)
        XCTAssertTrue(ended.isEmpty)
        binding.hold(.down, .ended)
        binding.hold(.down, .cancelled)
        XCTAssertEqual(ended, [.down, .down])
    }

    func test_foreignRecognizer_hasNoDirectionAndFiresNothing() {
        let view = UIView()
        var fired = 0
        let binding = DirectionalInputBinding(view: view, directions: [.up], onTap: { _ in fired += 1 })

        let foreign = UITapGestureRecognizer()
        XCTAssertNil(binding.direction(of: foreign))
        binding.handleTap(foreign)
        XCTAssertEqual(fired, 0)
    }

    func test_sidebar_horizontalSwipesRequestCollapse_onlyWhileExpanded() throws {
        let sidebar = ShellSidebarViewController()
        sidebar.embedded = true
        sidebar.loadViewIfNeeded()
        let swipes = recognizers(UISwipeGestureRecognizer.self, on: sidebar.view)
        XCTAssertEqual(swipes.count, 2)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let swipe = try XCTUnwrap(swipes.first { $0.direction == direction })
            let binding = try XCTUnwrap(swipe.delegate as? DirectionalInputBinding)
            var closed = 0
            sidebar.onCollapseRequested = { closed += 1 }
            sidebar.setExpanded(true, animated: false)
            XCTAssertTrue(binding.gestureRecognizerShouldBegin(swipe))
            binding.handleSwipe(swipe)
            XCTAssertEqual(closed, 1, "Each horizontal swipe must request collapse exactly once")
            sidebar.setExpanded(false, animated: false)
            XCTAssertFalse(binding.gestureRecognizerShouldBegin(swipe))
        }
    }

    // MARK: Library A to Z strip (device-unverified: the simulator cannot swipe)

    func test_alphabetStrip_leftSwipeLeavesLikeSelect_andIsDeclinedWithoutFocus() throws {
        let bar = LibraryAlphabetBarView()
        bar.setLetters(["A", "B"])
        var left = 0
        bar.onLetterSelected = { left += 1 }

        let swipes = recognizers(UISwipeGestureRecognizer.self, on: bar)
        XCTAssertEqual(swipes.map(\.direction), [.left])
        let binding = try XCTUnwrap(swipes[0].delegate as? DirectionalInputBinding)
        // Focus is outside the strip: the swipe stays with the focus engine.
        XCTAssertFalse(binding.gestureRecognizerShouldBegin(swipes[0]))
        binding.handleSwipe(swipes[0])
        XCTAssertEqual(left, 1)
    }
}
