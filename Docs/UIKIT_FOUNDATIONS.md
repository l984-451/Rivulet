# UIKit Foundations for the tvOS Port

Reference notes for the SwiftUI to UIKit conversion on the `perf-tvuikit-spike`
branch. Grounded in a deep-research pass (2026-05-31) over Apple developer
docs, WWDC 2016 sessions 210/215/216, and well-regarded UIKit engineering
writeups (objc.io, Airbnb tvOS focus writeup, Apple Developer Forums). Each
claim below was adversarially verified (3-vote majority-refute gate). Where a
claim was REFUTED, it is called out so we stop repeating it.

The goal of this doc: stop guessing at UIKit layout/animation/focus internals.
When we add a new transition, a new focus interaction, or lift another view
between contexts, consult this first.

---

## 1. Custom layout, parallax, and the expand/collapse morph

### Verified

- **Subclassing `UICollectionViewLayout` is the correct, idiomatic path** for a
  paged carousel with per-cell parallax and custom transforms. (high)

- **`UICollectionViewFlowLayout` has no declarative animation customization.**
  Apple ships one fixed fade for insert/delete. Any custom appearance,
  disappearance, or move animation requires overriding
  `initialLayoutAttributesForAppearingItem(at:)` and
  `finalLayoutAttributesForDisappearingItem(at:)` in a layout subclass. This is
  stable API, unchanged through tvOS 26. Compositional layout (WWDC 2019)
  reduced the *need* for structural subclassing but added NO declarative
  animation knobs. (high, survived 3 refutation attempts)

- **There is a more idiomatic morph mechanism than the one we currently use.**
  `setCollectionViewLayout(_:animated:)` and `UICollectionViewTransitionLayout`
  animate a layout-to-layout transition through public API, without hand-driving
  an `invalidateLayout` + `layoutIfNeeded` inside a `UIView.animate` block. A
  verifier explicitly called this "the idiomatic path for the carousel-to-detail
  morph." (high)

- **`apply(_ layoutAttributes:)` fires only when the layout supplies attributes
  to a cell.** During a morph driven by `layoutIfNeeded()` inside `UIView.animate`,
  the relayout calls `apply()` on visible cells with the *current* (carousel-mode)
  attributes — which is how subview frames set just before the animation get
  clobbered mid-flight. (high)

### The rule we extracted

> During a morph, do not let layout attributes own a subview's frame. Own it
> from the animator. If `apply()` must run during the animation, guard the
> subview writes so the pre-positioned state survives.

This is exactly the backdrop bug we hit: `apply()` reset `backdropImageView.frame`
from carousel-mode `cellViewportOrigin` while the expand animation was running,
making the backdrop animate from the carousel position to fullscreen instead of
staying put. Our current fix is a `suppressBackdropLayoutUpdates` flag on the
cell, set before the animate block and cleared in its completion. That is a
correct workaround. The root-cause-correct design is the layout-transition
approach above (two layouts, animated transition), where the backdrop's frame is
never owned by carousel-mode attributes during the morph.

### Open questions (research could not pin these down; verify empirically)

- Exact `apply()` firing order relative to `invalidateLayout` /
  `layoutIfNeeded` / the `UIView.animate` block. No source nailed the precise
  sequence; our suppress-flag fix sidesteps needing to know it.
- Whether a compositional layout can express our per-cell parallax cleanly.
- The cleanest expand-morph mechanism for our specific 760pt-cap chrome layout.

### REFUTED — do not believe

- "`setCollectionViewLayout` can swap layouts WITHOUT invalidation, so the
  source layout's attributes serve as initial attributes." (0-3) The transition
  still goes through the documented invalidation/transition machinery.
- "The default `final/initialLayoutAttributes...` implementation returns normal
  attributes with alpha 0.0." (0-3) Do not assume a specific default alpha;
  provide attributes explicitly.

---

## 2. Focus engine, responder chain, and the Menu button

### Verified (3-0 across WWDC 2016/210, Apple Forums 20084, tvOS guide)

- **The focus engine is the sole authority over focus.** There is no public
  set-focus API. You express *preference* (`preferredFocusEnvironments`) and
  request a re-evaluation (`setNeedsFocusUpdate()` / `updateFocusIfNeeded()`);
  the engine decides.

- **Press events go to the focused view and bubble UP the responder chain,
  skipping children.** A view controller receives `pressesBegan`/`pressesEnded`
  only if it is the first responder OR an ancestor of the first responder in the
  responder chain.

- **Presses are delivered to the FOCUSED view, not the first responder**, then
  bubble up the responder chain (WWDC 2016/210). First-responder status and
  focus are DECOUPLED on tvOS. `becomeFirstResponder()` alone does NOT route
  presses to you. (We tried it first — it did not work; see the correction
  below.)

- **A focusless modal never receives Menu at all.** If a modally-presented VC
  has NO focusable content (our carousel cells return `false` from
  `canFocusItemAt`), there is no focused view inside the modal, so Menu presses
  are never delivered into the VC's responder chain — neither a `.menu` gesture
  recognizer nor `pressesBegan`/`pressesEnded` overrides ever fire. The
  presentation controller then handles Menu as a default modal-dismiss one
  layer up (the press surfaces as `pressesCancelled`, and `viewWillDisappear`
  fires even though your code never called `dismiss()`).

- **The fix: give the focus engine a target inside the modal.** Add an
  invisible, always-focusable anchor view (`canBecomeFocused = true`, zero
  size) and point `preferredFocusEnvironments` at it, then
  `setNeedsFocusUpdate()`/`updateFocusIfNeeded()` in `viewDidAppear`. Now Menu
  presses enter the chain; a `.menu` `UITapGestureRecognizer` on the VC's view
  "begins", emits `pressesCancelled` up the chain (which SUPPRESSES the system
  dismiss per WWDC 2016/210), and its action runs your collapse-vs-dismiss
  logic. This is the verified working pattern for our carousel
  (`PreviewFocusAnchorView` + `menuRecognizer` in
  `PreviewCarouselViewController`).

### REFUTED — do not believe

- "`becomeFirstResponder()` is what makes presses reach a focusless modal VC."
  EMPIRICALLY FALSE (we shipped this first; Menu still dismissed straight to
  home). Presses go to the FOCUSED view, not the first responder. A focusless
  modal needs a focus TARGET (the invisible anchor + `preferredFocusEnvironments`),
  not first-responder status. We kept `becomeFirstResponder()` only as harmless
  belt-and-suspenders; the focus anchor is what actually works.

- "Both `pressesBegan` and `pressesEnded` must be forwarded to super for
  consistent `UINavigationController` behavior, and forwarding only one fails App
  Review." (0-3) FALSE. No symmetric-forwarding requirement, no App Review rule.
  Do not cargo-cult super-forwarding.

### The rule we extracted

> A focusless modal VC receives NO button presses until the focus engine has a
> target inside it. Add an invisible always-focusable anchor +
> `preferredFocusEnvironments`, THEN own Menu with a `.menu` gesture recognizer
> (which suppresses the system dismiss by emitting `pressesCancelled`). Focus,
> not first-responder, is the press-delivery prerequisite on tvOS.

---

## 3. Modal presentation style vs Menu dismissal

### Verified (3-0, Apple docs + WWDC 2016/215)

- **`overFullScreen` keeps the presenting VC's views in the hierarchy** (content
  shows through a transparent overlay). **`fullScreen` removes them** (nothing
  behind shows).
- **Presentation moves focus to the presented VC's preferred focus chain.**

### Applied to our carousel (important nuance)

The generic research finding is "use `overFullScreen` for transparent overlays."
**That does NOT apply to our preview carousel, which is opaque by design** — it
renders its own full-viewport backdrop image plus a dimmed surround (see memory
`uikit_carousel_migration.md`, finding 7). It is not meant to show home content
behind it. So `.fullScreen` is an acceptable choice here.

BUT the *reason* recorded in the code comment was wrong. The old comment claimed
`.overFullScreen` has "a built-in Menu-dismiss path that fires before
pressesBegan and can't be suppressed," and that choosing `.fullScreen` is how we
own Menu. The research refuted that reasoning (see section 2): Menu dismissal
flows through `pressesEnded` to `UIApplication` regardless of presentation
style. The real Menu fix is `becomeFirstResponder()` + handling the press. The
presentation style is an independent decision driven by whether the overlay is
opaque (fullScreen) or see-through (overFullScreen).

### The rule we extracted

> Choose `fullScreen` vs `overFullScreen` based ONLY on whether the overlay is
> opaque or see-through. Do not choose presentation style to control Menu — Menu
> is a responder-chain concern.

---

## 4. Lifting a shared "chrome" view between contexts

### Verified (3-0, objc.io + Apple VC Programming Guide)

- **Standard view-controller containment, three steps:**
  1. `addChild(childVC)`
  2. add the child's root view to your hierarchy (`addSubview` + constraints)
  3. `childVC.didMove(toParent: self)`
  (Removal reverses it: `willMove(toParent: nil)`, remove view, `removeFromParent()`.)

- **The parent lays out only the child's ROOT view and talks to the child
  through its public API.** Never reach into the child's internal view tree.

### Applied to our planned chrome lift

The plan to extract `MediaDetailChromeView` and share it between the carousel
cell and the expanded detail VC is architecturally sound IF chrome is wrapped in
a child VC (or a self-contained `UIView` with a clean public API) and both hosts
respect the boundary: position the chrome's root, drive it via public methods,
never mutate its internals.

### Open question (verify empirically)

`restoresFocusAfterTransition` behavior with a lifted chrome VC is unverified.
When we do the lift, test focus restoration across the carousel <-> expanded
transition explicitly.

---

## 5. Coordinated, staged animations (chrome cascade)

### Verified (WWDC 2016/216 + objc.io)

- **`UIViewPropertyAnimator` is the modern primitive** for interruptible,
  re-timable animations. Stage multiple sub-animations by composing several
  animators and re-timing them via `continueAnimation(withTimingParameters:
  durationFactor:)`, rather than nesting `UIView.animate` `delay:` calls.
- **Focus-driven animations belong in
  `UIFocusAnimationCoordinator.addCoordinatedAnimations(_:completion:)`** so they
  run in lockstep with the focus engine's own focus transition.

### The rule we extracted

> For the chrome cascade (logo, metadata, action row staged in), prefer separate
> `UIViewPropertyAnimator`s coordinated by re-timing over a pile of nested
> `UIView.animate` `delay:` blocks. For anything that should track a focus
> change, use the focus animation coordinator.

---

## 6. One morph = one clock (and what can actually ride it)

The carousel expand/collapse morph must look continuous frame-by-frame, not
just land on the right end state. The hard-won rule:

> Every visible layer that moves during a morph must be driven by the SAME
> `UIViewPropertyAnimator`. Any layer on a different clock (CADisplayLink with
> its own timing, a `CABasicAnimation`, an implicit CA animation, the focus
> engine) will visibly desync mid-morph even when the endpoints are correct.

We hit this repeatedly; each fix brought one more layer onto the single animator
until the morph was clean:

- **A `CALayer` sublayer's `frame` set in `layoutSubviews` does NOT ride a
  `UIViewPropertyAnimator`.** Setting it mid-animation fires a FRESH IMPLICIT CA
  animation (default 0.25s ease-in-out) each `layoutSubviews` pass; the
  overlapping implicits read as "jump small, grow, settle." This burned us on
  the vignette.
  - **Fix: make the animated thing a UIView, not a sublayer.** A gradient becomes
    a `GradientView` (`override class var layerClass { CAGradientLayer.self }`)
    positioned by Auto Layout. Its bounds animate as a first-class UIView
    property → rides the animator natively. Gradients in UNIT coordinates
    (`startPoint`/`endPoint` in [0,1], fractional `locations`) fill the view at
    any size, so no per-frame frame math is needed.
- **`cornerRadius` is not UIView-animatable**, but a `CADisplayLink` reading the
  SAME animator's `fractionComplete` and lerping it IS genuinely synced (one
  clock, sampled). That one is fine; a *separate* `CABasicAnimation` for radius
  is not (second clock).
- **Geometry beats alpha for reveal/cover.** Peeks that fade (alpha 0↔1) on a
  timeline disjoint from the centered card's grow/shrink "rip" across it. Better:
  keep peeks at their carousel frames and let the centered card (kept on top via
  `bringSubviewToFront`) cover/reveal them geometrically — no alpha timeline.
- **Compute morph endpoints from a layout that is actually installed.** A
  `UICollectionViewLayout`'s `.collectionView` is nil while it is NOT the active
  layout, so its frame math returns `.zero`. During collapse the expanded layout
  is active, so the carousel layout can't compute frames — derive the target from
  the live `collectionView.bounds` instead. (This is why the backdrop once flew
  to the top-left `(0,0,0,0)`.)
- **Keep the focus update OUT of the morph window.** `setNeedsFocusUpdate()`
  during the morph can spawn a concurrent focus animation; call it in the morph
  completion.

### The rule we extracted

> Before adding any layer to a morph, ask "what clock drives it?" If the answer
> isn't "the morph's `UIViewPropertyAnimator`" (directly, or sampled via a
> display link reading its `fractionComplete`), it will desync. Convert
> sublayers to views, prefer geometry over alpha, and read endpoints from live
> bounds, not from a detached layout.

---

## Quick decision table

| Situation | Do this | Not this |
|---|---|---|
| Subview frame must survive a layout-driven morph | Own it from the animator, or guard `apply()` writes | Let `apply()` reset it mid-animation |
| Carousel-to-detail morph (clean redo) | Two layouts + `setCollectionViewLayout(_:animated:)` | In-place `invalidateLayout` + `layoutIfNeeded` in `animate` |
| Focusless modal needs button input | Invisible focusable anchor + `preferredFocusEnvironments` → it | `becomeFirstResponder()` alone (presses go to FOCUS, not first responder) |
| Own Menu on a presented modal | `.menu` `UITapGestureRecognizer` on the VC view (after giving it a focus target) | Absorb in `pressesEnded` (system dismiss races you in parallel) |
| Opaque overlay | `.fullScreen` | `.overFullScreen` |
| See-through overlay | `.overFullScreen` | `.fullScreen` |
| Share a view between two VCs | Child-VC containment, public API only | Reach into the child's view tree |
| Animate a gradient/CALayer with a view animator | Make it a UIView (`layerClass`) + Auto Layout | Set sublayer `.frame` in `layoutSubviews` (fires mismatched implicit anims) |
| Animate `cornerRadius` with a morph | CADisplayLink sampling the animator's `fractionComplete` | A separate `CABasicAnimation` (second clock) |
| Reveal/cover sibling views during a morph | Geometry + z-order (`bringSubviewToFront`) | A disjoint alpha-fade timeline (rips) |
| Morph endpoint from a collection layout | Live `collectionView.bounds` math | A layout whose `.collectionView` is nil (returns `.zero`) |
| Stage delayed sub-animations | Composed `UIViewPropertyAnimator`s, re-timed | Nested `UIView.animate(delay:)` |
| Animate alongside a focus change | `UIFocusAnimationCoordinator` | Free-running animation outside the coordinator |

---

## Sources

Primary: WWDC 2016 session 210 (focus interactions), 215 (UIKit apps for tvOS),
216 (advanced collection/animation); Apple `UIModalPresentationStyle`
documentation; Apple TV Programming Guide ("Working with the Apple TV Remote");
Apple View Controller Programming Guide (containment).

Engineering writeups: objc.io (view-controller containment; collection-view
animations), Airbnb "Mastering the tvOS Focus Engine," Brightec tvOS focus,
Apple Developer Forums thread 20084 (Menu/responder behavior).
