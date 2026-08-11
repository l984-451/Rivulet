# Rivulet - Claude Context

Rivulet is a tvOS media client for Plex and IPTV. The primary surfaces (Home, Library, Search, Discover, Media Detail, the preview carousel, Person detail, and the player chrome) are **UIKit**, as is Settings; SwiftUI remains for thin navigation shells, Music, and Live TV slots.

**UIKit is the default. Do not add SwiftUI to a primary surface.** When you find SwiftUI in one, assume it is a leftover and check reachability before building on it.

**The rule covers enhancements, not just new surfaces.** A substantial addition to
an existing SwiftUI file on a UIKit surface is a signal to port that file, not to
extend it. The player's render layers count as a UIKit surface even though the
overlays themselves are still SwiftUI: they are non-interactive, so they never
fought the focus engine, which is the only reason they survived this long.
The subtitle overlays are the worked example, and staying in SwiftUI cost three
hacks UIKit does not need:
- SwiftUI `Text` has no stroke, so the caption outline draws the whole string 8
  times at offsets. `NSAttributedString` with a negative `.strokeWidth` is one pass.
- A text box cannot be measured without a layout pass, so cue placement estimates
  half the box height and is wrong for multi-line cues. `boundingRect` is exact.
- `LiveTVAetherPlayerViewController` wraps the overlay in a `UIHostingController`
  and rebuilds its root view from five call sites, because nothing observes the
  player from SwiftUI. A plain subview needs none of that.

**A clean SwiftLint run does not mean you complied.** The
`swiftui_import_on_uikit_surface` rule only scans paths matching
`Views/**/UIKit/**`. Everything under `Views/Player/`, `Views/Player/Aether/`, and
`Services/**` is invisible to it. Judge by the surface the code renders on, not by
whether the linter fired.

**Detail is UIKit, with no SwiftUI fallback.** Every route lands on the same two surfaces: `MediaItemDetailPageViewController` for episodes, `PreviewCarouselViewController(standaloneDetail:)` for everything else. That holds for in-app taps, tile-menu "More Info" / "Go to …", hero Info, and `rivulet://detail` deep links from Top Shelf / Siri (`TVSidebarView.presentDetailForDeepLink`). The old SwiftUI `MediaDetailView` + `MediaItemContextMenu` + `SummarySheet` are **deleted** (`c0b0bf7`); if you find a comment referencing them, it is stale.

The video player is **AetherPlayer** — an adapter around AetherEngine (FFmpeg demux + HLS-fMP4 remux + AVPlayer, with HDR10+ / HLG / EAC3+JOC Atmos, plus a software sample-buffer backend for AV1 / VP9 / MPEG-2 / VC-1 / MPEG-4p2). It is the only player: VOD **and** Live TV. Video MUST render through the engine surface (`AetherVideoSurfaceView` → `engine.bind(view:)`), never an AVPlayerLayer on `currentAVPlayer`. The only other path is `hls`: AVPlayer on a Plex server transcode, used when no direct-play URL exists or as the fallback after an Aether startup failure. `ContentRouter.plan(...)` picks aether vs hls per item. (RPlayer and the localRemux/avPlayerDirect routes have been removed — see git history.)

## Quick Reference

- **Platform**: tvOS 26+ (Apple TV)
- **Language**: Swift 6
- **UI Framework**: UIKit for the primary surfaces (see above); SwiftUI for the rest
- **Video Player**: AetherPlayer for VOD and Live TV; AVPlayer only for the `hls` route (server transcode, primary-when-no-direct-URL or Aether fallback). See `Docs/RIVULET_PLAYER.md`.
- **AetherEngine**: consumed as an **upstream** SwiftPM dependency (`superuser404notfound/AetherEngine`), pinned `exactVersion` (6.5.5). **There is no fork** — engine fixes need an upstream release or a host-side workaround; do not propose editing engine sources. Bumping it has a procedure: use the `aether-update` skill. Every bump gets a changelog line. FFmpeg + libdovi arrive **only transitively through Aether**; there is no app-level FFmpeg layer and no direct FFmpegBuild dependency. Since FFmpegBuild 2.0.0 the FFmpeg libs ship as **embedded dynamic frameworks** in `Rivulet.app/Frameworks/` — their `MinimumOSVersion` (26.0) must stay >= `TVOS_DEPLOYMENT_TARGET` (26.0), so do not raise the deployment target.
- **Design Guide**: See `Docs/DESIGN_GUIDE.md` for UI/UX patterns
- **Repo is public**: keep commit messages short and plain; no internal detail.

## Project Structure

Four code roots. `RivuletCore/` is a buildable folder compiled into BOTH app
targets (not a module — `internal` spans each target); `Rivulet/` is the tvOS
app, `RivuletiOS/` the iOS app. See "Platform Boundary" above for what goes
where.

```
RivuletCore/            # Shared tvOS + iOS. The ONE Plex client (PlexNetworkManager,
│                       #   PlexAuthManager, PlexUserProfileManager), Models/Plex,
│                       #   TMDB, IntroDBClient, WatchProgressPolicy, IPTV parsers,
│                       #   Security (attest, keychain), Sentry startup, Secrets,
│                       #   OpenSourceLicenses. NO #if os(...) — lint-enforced.
RivuletiOS/             # iOS/iPadOS app (SwiftUI). Plex/ holds ONLY IOSPlexSession
│                       #   (content store, counterpart of PlexDataStore) and
│                       #   IOSPlexAdapters (display accessors) — no endpoint code.
Rivulet/                # The tvOS app — everything below.
├── Models/
│   ├── Plex/           # (moved to RivuletCore/Models/Plex)
│   └── SwiftData/      # Persistent models (Channel, EPGProgram, PlexServer)
├── Services/
│   ├── Plex/
│   │   ├── (PlexNetworkManager, PlexAuthManager, PlexDataStore, …)
│   │   └── Playback/   # AetherPlayer + routing/remux (see Docs/RIVULET_PLAYER.md)
│   │       ├── Pipeline/     # ContentRouter (routing decisions)
│   │       └── Subtitles/    # CaptionAppearance (system caption settings), SubtitleCue,
│   │                          #   VTTParser (content-filter only; captions are not app-parsed)
│   ├── LiveTV/         # PlexLiveTVProvider, IPTVProvider, LiveTVDataStore
│   ├── IPTV/           # M3UParser, XMLTVParser, DispatcharrService
│   ├── Insights/       # InsightsTriviaClient, InsightsShowIDResolver (in-player cast/trivia panel)
│   ├── Cache/          # CacheManager, ImageCacheManager
│   └── Focus/          # FocusMemory (tvOS section focus restoration)
├── Views/
│   ├── Player/         # UniversalPlayerView, UniversalPlayerViewModel, PlayerContainerViewController,
│   │                   #   AVPlayerLayerView, TrackSelectionSheet, PlayerPresenter
│   │   ├── Aether/     # AetherVideoSurfaceView, AetherSubtitleCue
│   │   ├── Subtitles/  # SubtitleModel (cue store; publishes the active set)
│   │   ├── UIKit/      # CaptionOverlayView (the only caption renderer),
│   │   │               #   PlayerRailView, PlayerRailPanelView, PlayerProgressBarView,
│   │   │               #   PlayerUpNextPanelView, UpNextRowState, pills (canonical player chrome),
│   │   │               #   Insights* panels (in-player cast/trivia; backed by Services/Insights + TMDB)
│   │   └── PostVideo/  # Post-playback summary overlays
│   ├── Media/          # PreviewContext, HeroBackdropSupport, SharedMediaComponents,
│   │                   #   FocusScrollMotion
│   │   ├── UIKit/, PlexHome/UIKit/, MediaDetail/UIKit/, Person/UIKit/, Library/UIKit/, PreviewCarousel/UIKit/
│   │   │              #   — the canonical UIKit home/detail/library/person/carousel surfaces
│   │   └── Hero/       # HeroPlaySession + hero support (SwiftUI HeroBackdropLayer/OverlayContent removed)
│   ├── Music/          # MusicHomeView, MusicAlbumDetailView, MusicArtistDetailView,
│   │                   #   MusicNowPlayingView, MusicQueueListView, MusicQueueCarousel,
│   │                   #   MusicPlaylistView, MusicLyricsView, MusicVisualizerView
│   │   └── Components/ # MusicProgressBar, MusicPosterCard, MusicShelfRow
│   ├── Discover/       # DiscoverViewModel (SwiftUI Discover* views removed; UIKit home renders Discover)
│   ├── LiveTV/         # EPGGuideView + GuideLayoutView + LiveGuideInfoCardView (56-style guide),
│   │                   #   LiveTVAetherPlayerViewController (UIKit live rail), LiveTVContainerView,
│   │                   #   ChannelListView, MultiStreamViewModel, StreamSlotView, AetherSlotPlayerView
│   ├── Settings/       # SettingsDescriptors, SettingsModels, PlexAuthView
│   │   └── UIKit/      # SettingsContainer/Page VCs, SettingsCell, SettingsPageModels (canonical)
│   ├── Components/     # CachedAsyncImage, GlassRowStyle, WhatsNewView
│   └── TVNavigation/   # TVSidebarView, NavigationEnvironment
└── Docs/                   # gitignored, maintainer-local (see Build & Run note)
    ├── RIVULET_PLAYER.md   # Canonical player reference (routing, AetherPlayer + AVPlayer)
    └── DESIGN_GUIDE.md     # UI/UX documentation
```

## Platform Boundary (tvOS / iOS)

Three buildable folders, three memberships. `Rivulet/` is the tvOS app.
`RivuletiOS/` is the iOS/iPadOS app. `RivuletCore/` is compiled into both. All
three are `PBXFileSystemSynchronizedRootGroup`s, so a file joins its targets by
where it sits on disk and never needs a project edit. Do not add shared code by
hand-listing `PBXBuildFile` entries in the iOS target: that list has to be
maintained inside `project.pbxproj`, which is the worst merge surface in the repo.

**Shared code contains no `#if os(...)`.** That single rule is the boundary, and
it is the only thing keeping the iOS app from taxing tvOS work. It is
lint-enforced: `platform_conditional_in_shared_code` in `.swiftlint.yml` errors
on any platform directive under `RivuletCore/`. When a shared
file needs a platform branch, the file is in the wrong place: lift the
platform-specific part out into `Rivulet/` or `RivuletiOS/`. Do not add the
ifdef. PR 284 arrived with both failure modes and they are the worked examples:
an `#if os(tvOS)` around `M3UParser.toUnifiedChannel` (the fix is to move that
extension next to `UnifiedChannel`, after which the parser needs no conditional
at all), and an `#if os(iOS)/#else` wrapping two unrelated `AetherPlayer`
classes in one 1799-line file (the fix is two files).

### What qualifies as shared

The test is **"must a bug found on one platform be fixed on both?"**, not "does
it compile everywhere."

Yes, so it belongs in `RivuletCore/`: anything encoding how Plex or IPTV
actually behaves. `PlexNetworkManager` (`includeGuids=1`, the three Discover
hosts, account-vs-server token, `includeHttps=1&includeRelay=1`, the transcode
profile params), `Models/Plex/`, `PlexLiveTVProvider` + `PlexLiveTVModels` + the
timeline keepalive, `WatchProgressPolicy`, `ContentRouter`, `TrackIntent`,
`MediaTrack`, `StreamBodyClassifier`, the IPTV parsers, `Services/Security/`,
`Services/MediaProvider/`, `CacheManager`, `LibraryGUIDIndex`, `PlexAuthManager`,
`LiveTVDataStore`.

No, so it stays in `Rivulet/`: all of `Views/` (focus engine, morphs, Siri
Remote), `Services/Input/`, `Services/Focus/`, the Top Shelf composer and
extension, `Services/Siri/`, `DisplayCriteriaManager` (`AVDisplayManager` is
tvOS-only), and `PlexDataStore` — it carries tvOS-home-shaped state (the
`mergedItems` cache, the Continue Watching merge), so iOS goes through
`Services/MediaProvider/` instead.

**An import of UIKit or SwiftUI does not make a file tvOS-only.** Both exist on
iOS, and `ObservableObject` / `@Published` are the only reason most of the
service layer imports them. Of ~33k lines across `Services/` and `Models/`,
exactly four files touch genuinely tvOS-only API: the three in `Services/Input/`
plus `DisplayCriteriaManager`. Judge by tvOS-only frameworks (`TVServices`,
`TVUIKit`, `AVDisplayManager`) and focus/press API, nothing else.

Move files into `RivuletCore/` when a slice actually needs them, not
speculatively. The list above is the destination, not a migration order.

The Plex stack is already across: `PlexNetworkManager`, `PlexAuthManager`,
`PlexUserProfileManager`, `Models/Plex/`, the TMDB client, `IntroDBClient`,
`WatchProgressPolicy`, the attested `URLSession`, and the Sentry startup.
**There is exactly one Plex client.** `RivuletiOS/Plex/` holds only
`IOSPlexSession` (the iOS content store, counterpart of `PlexDataStore`) and
`IOSPlexAdapters` (display accessors). Never add a second decoder for a Plex
endpoint to the iOS folder; a bug fixed in the shared client must be the fix
for both apps.

### Host injection instead of platform conditionals

Where shared code genuinely differs per platform, the app injects the
difference at launch — the shared file stays free of `#if os(...)` and of
references to per-platform types:

- `PlexAPI.platform` / `PlexAPI.deviceName` are `static var`s defaulting to
  the tvOS values; `RivuletiOSApp.init` overrides them before any request is
  built. Not `UIDevice.systemName`, which splits iPads across "iOS"/"iPadOS".
- `PlexAuthManager.onAuthenticated` / `.onSignedOut` and
  `PlexUserProfileManager.onProfileChanged` / `.onInitialProfileSelected` are
  closures the host sets at launch (tvOS → `PlexDataStore`, iOS →
  `IOSPlexSession`). The managers own identity; content stores are per
  platform. `onAuthenticated` is awaited on purpose — it prefetches the
  libraries the tvOS sidebar needs on its first build.
- `SentryStartup.start(platform:)` takes the platform from the caller for the
  same reason.

RivuletCore is compiled into each app target, not built as a module, so
`internal` visibility spans the whole target and no `public` is needed. That
also means an extension on a shared type inside `RivuletiOS/` is not a
retroactive conformance.

### The player split

`AetherPlayer` is three pieces in two homes. The engine mapping (state and track
translation, cue conversion, background→foreground reload, mute persistence
across Aether's internal player swaps) is platform-neutral and belongs in
`RivuletCore`. The `PlayerProtocol` conformance stays tvOS. iOS gets its own thin
`ObservableObject` on top. This is not bookkeeping: keeping both classes in one
file also forced `@preconcurrency import AVFoundation` above the conditional,
which silently loosened Swift 6 Sendable checking on the *shipping tvOS player*
for the iOS half's benefit.

### Folders, not a SwiftPM package

A local `RivuletCore` package would enforce the boundary at compile time, but
every shared symbol would need `public` — a mechanical diff across 170+ files
touching every access modifier. The folder buys the same boundary for a day's
work, and the lint rule above makes the no-`#if` half mechanical. What lint
cannot catch is a shared file quietly referencing a per-platform type; if that
starts happening, the package is the escalation — it is the enforcement
mechanism for a rule that discipline is failing to hold, not an upgrade to
reach for on its own.

## Key Architectural Patterns

### Focus Management (tvOS)

**On the primary (UIKit) surfaces, focus is the UIKit focus engine**: `preferredFocusEnvironments`, `didUpdateFocus`, `setNeedsFocusUpdate`, and `pressesBegan` for Siri Remote input. Use the `rivulet-tvos-uikit` skill before writing or debugging any of it — the focus/press/morph traps there are already solved and are not guessable.

The SwiftUI primitives below apply only to the remaining SwiftUI surfaces (Music, Live TV slots, nav shells). No custom focus scope manager; isolation comes from system mechanisms:

- **`fullScreenCover`** — automatic focus isolation for overlays/popups
- **`TabView` with `sidebarAdaptable`** — system-managed sidebar/content focus
- **`@FocusState` + `.onAppear`** — setting initial focus in presented views
- **`FocusMemory`** — remembers and restores focus within scrollable sections

```swift
// Section focus memory
.focusSection()
.remembersFocus(key: "uniqueSectionKey", focusedId: $focusedItemId)

// Initial focus in fullScreenCover (no Namespace/resetFocus needed)
.onAppear {
    focusedUserId = profileManager.selectedUser?.id
}
```

### Remote Input (every remote type)

**tvOS delivers remote input on two disjoint transports, and a surface must
handle both.** A touch-surface swipe (Siri Remote, iPhone Remote) arrives as
`.indirect` `UITouch`es feeding the focus engine and NEVER as an arrow
`UIPress`; d-pad and clickpad-edge clicks, IR and HDMI-CEC remotes, and
keyboards send ONLY discrete arrow `UIPress`es. The iPhone Remote emits NO
arrow presses at all, so any press-only interaction is a hard wall for it,
not a degraded one. Focusable surfaces get both transports for free — the
engine translates everything. A surface is broken exactly when it is
focusless AND single-transport, or when a needed hand-off is press-only.

- **New focusless directional surface → use `DirectionalInputBinding`**
  (`Services/Input/`). One call installs arrow-press taps, optional holds at
  `InputConfig.holdThreshold`, and `.indirect` swipe recognizers, funneled
  into one callback, so one transport cannot be adopted without the other.
  Adopters: `LiveTVPressCatcher`, `InfoPopupViewController`.
- **A sometimes-focusable surface claiming swipes must gate in
  `gestureRecognizerShouldBegin`, never by bailing inside the handler.** A
  recognizer that begins has already cancelled the focus engine's move, so a
  handler-side bail still eats the swipe. The carousel's horizontal paging
  swipes shipped exactly this bug (claimed unconditionally, which made
  swiping between the detail action buttons dead on every touch remote); the
  gate is `state.isCarouselInputEnabled` in `PreviewCarouselViewController`.
- **Focusable surface whose press half is a declined-press `pressesBegan`
  override → `DirectionalInputBinding(gatedSwipesOn:)`.** The press override
  is correct there (engine acts first, declined presses bubble); the gated
  swipes are its touch-remote twin. The gate must claim exactly the moves
  the engine cannot perform — reuse the press override's own predicates
  (`canEscapeUpward`, `containsFocus`, would-a-step-move). Adopters:
  `InsightsPanelContainerView`, `PlayerInfoTabsView`, `InfoScrollView`
  (escape to pills), `InsightsActorView` (bio steps).
- **Do not migrate an already dual-transport surface onto the binding.** It
  changes nothing at runtime and splits a tuned interaction across two
  mechanisms. Settings reorder (grab-gated press taps + swipes) stays
  hand-rolled on purpose.
- **A handler that claims a press at the WINDOW level must gate on focus
  containment, never on `isKeyWindow`.** `MenuPressInterceptor` swizzles
  `UIWindow.sendEvent`, which is earlier than every responder and every
  gesture recognizer, so a `MenuBackHandling` handler that wrongly returns
  true kills Menu inside whatever modal is on screen. A modal presents into
  the SAME window, so `view.window?.isKeyWindow` is TRUE while it covers
  you: it is not a frontmost test. Require the focused item to be a
  descendant of your own view (a presented VC's view is added to the window,
  never to the presenter's view, so this is exact). `RootShellViewController`
  shipped without that check in `cfb44f1` and, from the carousel's below-fold
  detail, expanded a sidebar buried under the modal and returned true —
  withholding the press from the system AND from the carousel's own `.menu`
  recognizer. Because the invisible expand flipped `sidebar.isExpanded`, the
  next press took the collapse branch and worked: **every other Menu press
  did nothing at all.** `PlexHomeViewController.handleMenuBack` had the check
  from the start, which is why only the shell absorbed the press.
- The player's tap-vs-hold sites are duration-based and deliberately
  untouched pending InputProbe field data on IR repeat codes (#212).

### Context Menus (long-press)

**On tvOS 26, UIKit's context-menu machinery never engages** — not in this app, not in a clean-room control. A held Select press is delivered then cancelled at +0.4s and no configuration is ever requested. `UIContextMenuInteraction` / `contextMenuConfigurationForItemsAt` are dead ends; do not reach for them, and do not "fix" their absence.

The canonical menu is therefore hand-built: a plain `UILongPressGestureRecognizer` (needs a simultaneous-permissive delegate, or the collection view's own press recognizers force it to fail) feeding `TileMenuPopupViewController`, with actions built as `[[TileMenuAction]]` (inner arrays = divider-separated groups). `UIAction` is useless here — its handler can't be invoked programmatically. Builders live in `PlexHomeViewController.tileMenuSections`.

SwiftUI's `.contextMenu` *does* still work (verified in Music) — the tvOS 26 breakage is UIKit-only. But do not reach for it on a UIKit surface: hosting each tile to get it re-introduces the per-cell `UIHostingController` the UIKit migration removed for its measured hitch cost. Music is now its only user.

### Video Player Architecture

**AetherPlayer** (an adapter around AetherEngine) is the only player, used for both VOD and Live TV. It conforms to `PlayerProtocol`; video renders through the engine surface via `AetherVideoSurfaceView` (`engine.bind(view:)`), which hosts whichever layer the active backend uses. The app drives a plain `AVPlayer` only on the `hls` route (Plex server transcode). `ContentRouter.plan(...)` returns a `PlaybackPlan { primary, fallbacks }`. Canonical reference: `Docs/RIVULET_PLAYER.md`.

```
UniversalPlayerView (SwiftUI) + PlayerContainerViewController (UIKit chrome)
        │
UniversalPlayerViewModel  ← state, markers, post-video, NowPlaying, route changes
        │
   ContentRouter.plan(...) → PlaybackPlan { primary, fallbacks }
        │
        ├── .aether → AetherPlayer, rendered via AetherVideoSurfaceView (direct-play URL exists; the default)
        └── .hls    → AVPlayer on Plex server transcode (no direct-play URL, or fallback after Aether failure)

Live TV: MultiStreamViewModel / StreamSlotView instantiate AetherPlayer() per grid slot,
         rendered via AetherSlotPlayerView (AVPlayerLayer). Up to 4 concurrent slots.
```

Key components:
- **`UniversalPlayerView`** / **`UniversalPlayerViewModel`**: SwiftUI container + state. Handles markers, post-video, route changes, NowPlaying. The player chrome itself is UIKit (`Views/Player/UIKit/`).
- **`AetherPlayer`**: `PlayerProtocol` adapter around AetherEngine. Exposes Combine publishers for state, audio/subtitle tracks, and `currentAVPlayer`. Handles HDR10+ / HLG / EAC3+JOC Atmos. `setMuted` persists across Aether's internal player swaps (used by the Live TV grid). Also owns background→foreground recovery: the engine tears its pipeline down on tvOS background and has NO tvOS foreground observer — the host must call `reloadAtCurrentPosition()` (playing user: on foreground; paused user: deferred to play(), because a reload zeroes the clock until playback starts). See `observeAppLifecycle` in AetherPlayer.
  **AetherPlayer is the only file allowed to name an AetherEngine type.** Map
  engine values to host types at the wrapper and publish those; do not widen the
  `import AetherEngine` set to reach a new engine API. `seekEvents` is the worked
  example — `AetherPlayer` maps `SeekEvent` to `SeekHoldEvent` so
  `UniversalPlayerViewModel` stays uncoupled. Putting the `switch` in the view
  model fails to compile ("enum case 'stalled' is not available due to missing
  import of defining module 'AetherEngine'"), and adding the import is the wrong
  fix.
- **`ContentRouter`**: routing decisions → `PlaybackPlan`.
- **Captions are UIKit: `CaptionOverlayView`** (`Views/Player/UIKit/`), mounted as a
  plain subview above the video and below the chrome by both
  `PlayerContainerViewController` and `LiveTVAetherPlayerViewController`. Cues come
  from the engine's publishers via `SubtitleModel`; Live TV's remote-HLS direct path
  feeds the SAME view from `AVPlayerItemLegibleOutput`. One renderer, two sources.
  Do not add a third view, and do not mount it through a `UIHostingController`: that
  applies the tvOS title-safe inset to the content, so every caption margin is
  measured against the wrong box.
- **The `hls` route has no app-side captions at all.** `SubtitleManager`,
  `SubtitleClockSyncController` and the SwiftUI `SubtitleOverlayView` were RPlayer's
  sidecar pipeline; `390ebec` removed RPlayer's VOD branches and took the last caller
  of `SubtitleManager.load` with it, leaving a permanently empty track feeding a view
  that rendered nothing. All deleted. On that route subtitles come from the server
  (burn-in, or the WebVTT rendition the client profile requests).
- `SubtitleParser.swift` survived that cull and is NOT dead: `VTTParser` is live,
  parsing `text/mcf+vtt` for the content filter (`ContentFilterParsers`). `SRTParser`,
  `ASSParser` and `SubtitleFormat` in the same file have no production caller and are
  held up only by their own unit test. Check for the type, not the filename, before
  deleting anything here.

**Playback States** (PlayerProtocol): `.idle`, `.loading`, `.playing`, `.paused`, `.buffering`, `.ended`, `.failed`

#### Routing policy (VOD)
1. `ContentRouter.plan(...)` returns `PlaybackPlan { primary, fallbacks }`. Route cases: `.aether`, `.hls`.
2. `.aether` — whenever a direct-play URL is available (AetherEngine handles demux + remux + HDR internally; software-decodes AV1 / VP9 / MPEG-2 / VC-1 / MPEG-4p2). DV P7 plays as HDR10 base.
3. `.hls` — server-side transcode; primary when no direct-play URL exists, and the fallback after an Aether startup failure. `requiresVideoTranscode` codecs force a video transcode (not just remux) on this route.

#### Live TV
Routes through **AetherPlayer** per grid slot (`MultiStreamViewModel` / `StreamSlotView` instantiate `AetherPlayer()`, rendered via `AetherSlotPlayerView`). The grid supports up to 4 concurrent slots (opt-in past 2). HDHomeRun delivers a direct stream; DVB tuners require a Plex transcode URL with full client-profile parameters (see Plex Live TV section below).

### Plex Metadata Hierarchy

For TV shows:
- **Show** (`grandparentRatingKey`) → **Season** (`parentRatingKey`) → **Episode** (`ratingKey`)
- Episode has `index` (episode number) and `parentIndex` (season number)

**Note**: Items from "Continue Watching" hub may lack parent metadata. Use `PlexNetworkManager.getMetadata()` to fetch full details.

### Watch State

`WatchProgressPolicy` is the **only** definition of "has a resume point" and
"how far in" (2% floor, 90% ceiling, one capped fraction). `MediaUserState`,
`MediaItem`, and `PlexMetadata` all delegate to it — there were once three rival
copies under the same name, two of them gating the same resume prompt with
different thresholds. Do not add a fourth: extend the policy.

Two rules that look wrong until you know them:
- **A resume point outranks the watched flag.** `PlexMetadata.isWatched` reports
  false while a rewatch is in progress, and the poster/episode cells draw the
  progress bar *instead of* the watched glyph. A label keyed on
  `viewOffset > 0 && !isWatched` mislabels a resumable rewatch (issue #270).
  `MediaUserState.isInProgress` adds `!isPlayed` for exactly one reason: On Deck
  must advance past a finished episode.
- **Drawing a partial progress bar is a different rule** (`0 < fraction < 1`) and
  lives at the render sites on purpose. Folding it into the 90% ceiling changes
  every tile.

**Changing watch state must repaint.** `.plexDataNeedsRefresh` is the live
channel; all three UIKit surfaces observe it. Post it after the server call.
`PlexDataStore.updateItemWatchStatus` and `.episodeWatchedStatusChanged` are
both **dead** (no callers / no posters), orphaned when the SwiftUI detail view
was deleted — don't revive either, and don't reintroduce optimistic Continue
Watching mutation from a shelf (reverted in `90bfd2b` for focus reasons).

### Glass UI Style

All focusable rows use consistent styling (see `Docs/DESIGN_GUIDE.md`):

```swift
// Background
.fill(isFocused ? .white.opacity(0.18) : .white.opacity(0.08))
.strokeBorder(isFocused ? .white.opacity(0.25) : .white.opacity(0.08), lineWidth: 1)

// Scale
.scaleEffect(isFocused ? 1.02 : 1.0)

// Animation
.animation(.spring(response: 0.3, dampingFraction: 0.7), value: isFocused)
```

## Common Tasks

### Presenting a Focus-Isolated Overlay

Use `fullScreenCover` — it provides automatic focus isolation without manual scope management:

```swift
.fullScreenCover(isPresented: $showOverlay) {
    MyOverlayView(isPresented: $showOverlay)
        .presentationBackground(.clear)  // See-through to content behind
}
```

In the presented view, use `@FocusState` with `.onAppear`:
```swift
@FocusState private var focusedItem: String?

.onAppear {
    focusedItem = defaultItemId
}
.onExitCommand {
    isPresented = false
}
```

### Fetching Next Episode

```swift
// Get episodes in current season
let episodes = try await networkManager.getChildren(
    serverURL: serverURL,
    authToken: authToken,
    ratingKey: metadata.parentRatingKey  // Season key
)

// Find next episode
let next = episodes.first(where: { $0.index == currentEpisodeIndex + 1 })
```

### Release Notes / Changelog

Release notes live ONLY in the `changelogs` array in
`Rivulet/Views/Components/WhatsNewView.swift` (root `CHANGELOG.md` is a stub).
Entries are keyed by build-qualified version (`"1.0.3 (65)"`), newest first.
Settings → About → Changelog renders the full history; the fresh-launch
"What's New" shows only the current build's entry.

**The build number in that key comes from the git tag, and nothing warns you
when it is wrong.** CI derives `CFBundleVersion` from the tag suffix
(`v1.0.4-74` → 74) and overwrites `CURRENT_PROJECT_VERSION`, so an entry keyed
to a build that never ships is dead. The lookup is an exact match on
`"<CFBundleShortVersionString> (<CFBundleVersion>)"`; Settings → Changelog
falls back to `changelogs.first` on a miss, but the fresh-launch What's New
gates on `features(for:) != nil` with **no fallback**, so a mismatched key
silently means no panel at all. Before CI took the number from the tag it used
`latest TestFlight build + 1`, and one build that never reached TestFlight put
every build number in git permanently one ahead — five releases shipped with
the wrong notes or none. Build 73 does not exist for that reason. Write bullets as simple,
user-facing sentences (what users get, not internal details); no em dashes.
Every AetherEngine bump gets a changelog line, and it states **only the
version** (`"Updated AetherEngine to X.Y.Z"`). Do not list what the engine
release fixes: engine internals are not the user's mental model, and a long
engine-fix paragraph crowds out the app's own notes.

### Adding Settings

Settings is **UIKit**. A page is a list of `SettingsRow` values built in
`Views/Settings/UIKit/SettingsPageModels.swift`; `SettingsPageViewController`
renders each one through `SettingsCell`. Add a row by adding a case to the
relevant page's builder, picking a `SettingsRow.Kind`:
- `.navigation` / `.navigationValue` - pushes another page (chevron)
- `.toggle` - On/Off toggle
- `.cycle` - cycles through options in place
- `.action` - runs a handler (supports `destructive:`)
- `.info` - read-only value
- `.option` / `.selectable` - checkmark rows on a picker page
- `.textEntry` - presents `TextEntryViewController`

Every row title renders at one size and weight; there is no per-row-kind
typography. The SwiftUI settings rows are gone (`SettingsComponents.swift` and
`UserProfileSettingsView.swift` are deleted) — do not reintroduce them.

**A row's `key:` is not wired to anything by adding the row.** Nothing reads it
for you and nothing warns you, so a toggle can look and persist perfectly while
having no effect — the state issue #260 shipped in for 16 builds, after the UIKit
migration orphaned two keys whose only reader was the deleted SwiftUI library
view. When you add or touch a row, grep its key across the repo: a single hit, in
`SettingsPageModels.swift`, means dead. `musicLoudnessNormalization` and
`musicShowQualityBadges` are dead right now. Also check the reader re-renders on
`UserDefaults.didChangeNotification` if the surface computes from the key at
snapshot/render time, and never apply a display preference where it would be
written to a cache.

**Never put a subtitle/description inside a settings row.** Rows are title-only
so the list stays scannable and the focus target stays compact. Any descriptive
copy lives in the **left-side description panel**, which is driven by
`SettingsDescriptors.swift`. Register a descriptor keyed by the row's
`focusedSettingId` with an icon, color, and a clear description. The panel
updates as the user moves focus between rows.

### Image Loading

Always use `CachedAsyncImage` for remote images:
```swift
CachedAsyncImage(url: imageURL) { phase in
    switch phase {
    case .success(let image): image.resizable()
    case .empty: ProgressView()
    case .failure: Image(systemName: "photo")
    }
}
```

## Build & Run

One-time setup: `RivuletCore/Config/Secrets.swift` is gitignored and required for **both** app targets to compile. Copy the template and fill in real values (or leave placeholders for a build that doesn't need Sentry/TMDB/etc. to actually work):

```bash
cp RivuletCore/Config/Secrets.swift.template RivuletCore/Config/Secrets.swift
```

It lives in `RivuletCore/` rather than `Rivulet/Config/` because tvOS and iOS both start Sentry through `RivuletCore/Diagnostics/SentryStartup.swift`. The rest of `Rivulet/Config/` (`TMDBConfig`, `InsightsConfig`, `InputConfig`) is tracked, tvOS-only, and present in a fresh clone. Copying the template is the whole step: every target uses Xcode buildable-folder references (`PBXFileSystemSynchronizedRootGroup`), so files are picked up from disk and never need adding to the project. Both `RivuletApp.swift` and `RivuletiOSApp.swift` read `Secrets.sentryDSN`, so neither app compiles without it.

Two shared schemes: `Rivulet` (tvOS) and `Rivulet iOS`. No SwiftFormat is configured.

SwiftLint is configured, but **every stock rule is off** (`only_rules: [custom_rules]`
in `.swiftlint.yml`). It is not a style checker here and has no opinion about force
casts, line length, or naming. It runs four project-specific rules: no SwiftUI on a
UIKit surface, no `UIHostingController` in a cell, no UIKit context menus (dead on
tvOS 26, iOS exempt), and no `#if os(...)` in `RivuletCore/` (the platform boundary;
the regex is line-anchored so comments may discuss the directive, and it deliberately
avoids `match_kinds` — a wrong kind name silently disables a custom rule). A PR gate
runs them on Linux; there is no local hook.

```bash
swiftlint lint --strict     # or: docker run --rm -v "$PWD":/work -w /work \
                            #       ghcr.io/realm/swiftlint:0.65.0 lint --strict
```

Do not add stock rules. A full run of the default set produced 129 violations and zero
bugs: all 43 `force_cast` hits were `dequeueReusableCell(...) as! Cell` or
`layer as! CAGradientLayer` behind a `layerClass` override, and all 14 `force_try` hits
were test fixtures. The bar for a new rule is that when it fires, the response is to fix
the code rather than suppress the rule.

```bash
# Build for tvOS Simulator
xcodebuild -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' build

# Build for device
xcodebuild -scheme Rivulet -destination 'platform=tvOS,name=My Apple TV' build

# Run the full unit test suite (RivuletTests, XCTest, @testable import Rivulet)
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV'

# Run a single test class or method
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' \
  -only-testing:RivuletTests/MediaItemTests
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' \
  -only-testing:RivuletTests/MediaItemTests/test_id_returnsRef
```

Most tests live in `RivuletTests/Unit/` (mirrors `Rivulet/` roughly by feature — Parsers, Playback, Player, Preferences, Services, Siri, etc.), with shared fixtures/mocks in `RivuletTests/Fixtures/`, `RivuletTests/Helpers/`, `RivuletTests/Mocks/`. A few sit at the `RivuletTests/` root (`PlexDeviceDecodingTests.swift`).

**Building requires full Xcode** (not just Command Line Tools) since it's tvOS. There is still no CI test run — run tests locally. CI is split across two systems: `codemagic.yaml` archives and publishes to TestFlight on tag push (`v*` → tvOS, `ios-v*` → iOS), and `.github/workflows/` holds five workflows — the SwiftLint gate, two Claude review/mention bots, and two build checks that exist to guard the platform boundary: `build-ios.yml` compiles the `Rivulet iOS` scheme on PRs/pushes touching `RivuletCore/**`, `RivuletiOS/**`, or the project file (otherwise nothing compiles iOS between release tags), and `build-tvos-core.yml` compiles the tvOS scheme when shared code changes from the iOS side. Both are build-only; signing and archives stay on Codemagic.

**The Simulator does not fully mimic Apple TV**, especially for focus-engine behavior. Treat Simulator-only verification of tvOS focus/remote-input changes as provisional; say so rather than declaring it fixed.

**`Docs/` is gitignored** (untracked on purpose, `c89b52d`), though some files under it are force-added and do ship — the `superpowers/` plans and specs, and `AETHER_ENGINE_STARTUP_NOTES.md`. What is *not* in the repo is `Docs/RIVULET_PLAYER.md` and `Docs/DESIGN_GUIDE.md`, both referenced throughout this file; they live only on the maintainer's machine. The `aether-update` and `rivulet-tvos-uikit` skills referenced above are also absent — `.claude/` is gitignored with nothing force-added. If a referenced doc or skill is missing in your environment, say so and proceed carefully rather than guessing its contents.

## Key Files

| Purpose | File |
|---------|------|
| Player container (SwiftUI) | `Views/Player/UniversalPlayerView.swift` |
| Player view model | `Views/Player/UniversalPlayerViewModel.swift` |
| Player container (UIKit chrome) | `Views/Player/PlayerContainerViewController.swift` |
| Player rail UI (UIKit) | `Views/Player/UIKit/PlayerRailView.swift` |
| Rail panel (UIKit) | `Views/Player/UIKit/PlayerRailPanelView.swift` |
| Up Next panel (UIKit) | `Views/Player/UIKit/PlayerUpNextPanelView.swift` |
| Player (AetherEngine adapter) | `Services/Plex/Playback/AetherPlayer.swift` |
| Live TV slot render surface | `Views/LiveTV/AetherSlotPlayerView.swift` |
| Routing decisions | `Services/Plex/Playback/Pipeline/ContentRouter.swift` |
| Aether render surface | `Views/Player/Aether/AetherVideoSurfaceView.swift` |

| Caption renderer | `Views/Player/UIKit/CaptionOverlayView.swift` |
| Focus memory | `Services/Focus/FocusMemory.swift` |
| Watch progress rule | `Models/Media/WatchProgressPolicy.swift` |
| Plex star rating / favorite | `Models/Plex/PlexUserRating.swift` |
| Plex API | `Services/Plex/PlexNetworkManager.swift` |
| Glass row styling | `Views/Components/GlassRowStyle.swift` |
| Settings rows / pages | `Views/Settings/UIKit/SettingsPageModels.swift` |
| Player canon docs | `Docs/RIVULET_PLAYER.md` |
| Design patterns | `Docs/DESIGN_GUIDE.md` |

## Design Philosophy

From `Docs/DESIGN_GUIDE.md`:

- **Simplicity First**: Remove rather than add. The interface should feel calm.
- **Elegant Restraint**: Subtle effects (2% scale, soft glow) over flashy ones.
- **Liquid Glass**: Translucent backgrounds with subtle borders (tvOS 26 aesthetic).
- **Subtle Motion**: Small scale effects, natural animations.
- **Invisible Complexity**: Complex features should feel simple to use.

**Design Don'ts**:
- No over-decoration (gradients, unnecessary shadows)
- No aggressive animations (bouncing, overshooting)
- No redundant icons/labels
- No "just in case" features

## PR Review Standard

Every PR review — contributor or AI-generated — requires two assessments, not one:

1. **Technical**: Will it work? Bugs, Swift 6 correctness, edge cases, regressions.
2. **Fit**: Does it belong in Rivulet? Apply these filters:
   - Does it match the design philosophy above (Simplicity First, no "just in case" features)?
   - Is this better owned by the OS/platform? (If AVPlayer / AetherEngine gets it for free, defer to the system rather than replicate.)
   - Does it add ongoing maintenance surface the project has to own?
   - Does it pull Rivulet toward a focused, calm product or away from it?

Good code that adds the wrong thing is still a no. A verdict of MERGE requires both assessments to pass.

**Re-check the head SHA immediately before posting a review**, not just before
starting one. `gh pr view N --json headRefOid,files,state,isDraft` — compare
against the SHA the review was written from. `mergeable` and the merge-base can
both be unchanged while the author has pushed a fix; a changed file count is the
visible tell. A submitted review cannot be retracted: deleting one returns 422,
and dismissing silently no-ops on a closed PR, leaving only a follow-up comment
as cleanup.

## Troubleshooting

### Focus Not Working in Overlay
UIKit surfaces (the usual case): consult the `rivulet-tvos-uikit` skill first. Two traps recur — `indexPathForPreferredFocusedView` must return a path whose cell EXISTS right now, and `setNeedsFocusUpdate` is ignored unless the requesting environment currently CONTAINS focus.

SwiftUI surfaces only:
- Use `fullScreenCover` for focus-isolated overlays (provides its own focus hierarchy)
- Set initial focus via `@FocusState` in `.onAppear`
- Use `.onExitCommand` for Menu button dismissal
- For transparent overlays, add `.presentationBackground(.clear)` to the cover content

### Video Not Shrinking/Positioning
- Check `VideoFrameState` offset values (positive = padding from top-left with `.topLeading` anchor)
- Ensure `videoFrameState` is being set to `.shrunk`

### Post-Video Not Triggering
- Check if `hasTriggeredPostVideo` flag needs resetting
- Verify credits marker detection in `checkMarkers(at:)`
- Ensure `duration > 60` for time-based trigger (45s before end)

### Plex Live TV Not Starting (DVB Tuners)
- DVB tuners (TBS cards, etc.) don't have HDHomeRun stream URLs
- They require Plex server transcode via `/video/:/transcode/universal/start.m3u8`
- The transcode URL must include comprehensive client profile parameters
- Minimal URLs will cause stream-load failures; Plex needs to know client capabilities
- See `PlexLiveTVModels.buildPlexLiveTVStreamURL()` for required parameters

## Player (AetherPlayer / AVPlayer) on tvOS

VOD is served by AetherPlayer (`aether` route, the default) or AVPlayer (`hls` route: server transcode). Live TV runs on AetherPlayer per grid slot with `LoadOptions.isLive`. AetherEngine does its own demux + HLS-fMP4 remux + HDR handling internally; Rivulet has no app-level FFmpeg layer anymore (the packages are linked transitively through AetherEngine only).

### HDR / DV
- Aether drives `AVDisplayManager.preferredDisplayCriteria` itself (host `DisplayCriteriaManager` stands down on the aether route).
- DV P5 / P8.1 play with Dolby Vision via dvh1+dvcC sample entries; DV P7 plays as HDR10 base (the localRemux P7→P8 conversion path was removed).

## Plex Discover API

The Plex Discover API uses three different hosts:
- `discover.provider.plex.tv` — watchlist CRUD (`/library/sections/watchlist/all`, `/actions/addToWatchlist`, `/actions/removeFromWatchlist`)
- `metadata.provider.plex.tv` — metadata matches (`/library/metadata/matches?type={1|2}&guid=tmdb://X`)
- `metadata-static.plex.tv` — image CDN (fully-qualified URLs, no auth needed)

| Requirement | Notes |
|------------|-------|
| Token | Must use `authToken` (account-level), NOT `selectedServerToken` |
| GUIDs | Pass `includeGuids=1` — Plex omits the `Guid` array by default |
| Pagination | `X-Plex-Container-Size` is rejected on the watchlist endpoint |
| Mutations | Resolve external GUID → discover `ratingKey` via matches endpoint first, then PUT actions |

## Plex Live TV

### Stream URL Types

| Tuner Type | URL Source | Notes |
|------------|-----------|-------|
| HDHomeRun | `PlexLiveTVChannel.streamURL` | Direct stream, works out of box |
| DVB / cloud-EPG | Tune → decision handshake in `PlexLiveTVProvider.resolveStreamURL` | See below |

### Tuned-channel handshake (DVB / cloud-EPG DVRs)

Channels without a direct stream URL go through a three-step, server-authoritative flow:

1. **Tune**: `POST /livetv/dvrs/{dvr}/channels/{id}/tune?X-Plex-Session-Identifier={sid}`.
   Parse the first `key` prefixed `/livetv/sessions/` (excluding `.m3u8`) as the session
   path — some PMS variants carry NO `Media.uuid` (legacy fallback only). An HTTP 200
   with `MediaContainer.status: -1` is a FAILED tune. Also extract the first numeric
   `ratingKey` (the timeline keepalive 404s with `plex://` string keys).
2. **Decision**: `GET /video/:/transcode/universal/decision` with `path={sessionPath}`,
   `directPlay=1&directStream=1`, and the shared param set from
   `PlexLiveTVChannel.universalLiveQueryItems`. `mdeDecisionCode == 1000` → play the
   returned Part key verbatim (raw session HLS, teletext/mp2 intact — load it with
   `forceEngineDemux: true`; AVPlayer can't decode broadcast mp2/teletext). Otherwise →
   `start.m3u8` with the IDENTICAL param set.
3. **Keepalive**: PMS releases the grab on a 300s rolling timer. `PlexLiveTimelineKeepalive`
   pings `/:/timeline` every 10s (first ping delayed 3s — an immediate ping spawns a
   duplicate transcode job), `time=0&duration=0&playbackTime={ms}` (avoids the
   time-exceeds-duration 400), and sends `state=stopped` on teardown to free the tuner.
   Wired in `LiveTVAetherPlayerViewController` and per multiview slot.

`X-Plex-Client-Profile-Extra` encoding: clauses joined by raw `+`, comma lists pre-encoded
`%2C`, whole value percent-encoded once (`URLComponents` + a `"+"→"%2B"` pass). This is the
canonical form working Plex clients ship; do not "fix" it back to raw commas.

## Sentry Error Patterns

| Error | Likely Cause |
|-------|-------------|
| `FFmpeg avformat_open_input failed` | Bad stream URL, network issue, missing transcode params, or Plex returned an HTML error page instead of a stream |
| `Demuxer: no streams found` / `unsupported codec` | AetherEngine probe failure — check the engine's demux logs |
| `HLS transcode session failed` | Incomplete transcode URL parameters |
| `HTTP 500 on /hubs` | Plex server issue (not client-side) |
| `NSURLErrorDomain -999 cancelled` | User navigated away, request timeout |
| Aether/AVPlayer startup fatal → auto HLS fallback | Expected: ContentRouter falls back to `.hls` once at current playback time |

### Performance tracing

Sampling is driven by `options.tracesSampler`, **not** a flat `tracesSampleRate`.
Transactions we deliberately measure (e.g. `live.join`) return 1.0; everything
else returns 0.05, because `enableSwizzling` otherwise emits a transaction for
every UIViewController appearance and HTTP request, and a saturated quota makes
Sentry drop spans server-side (biasing the named measurements, not just thinning
them). Add new measured transaction names to the sampler's 1.0 branch; do not
restore a flat 1.0. Start transactions through `SentryBridge.startTransaction`,
which no-ops in DEBUG.

**Never send stream URLs to Sentry.** Xtream-style IPTV paths embed credentials
(`/live/user/pass/id.ts`) and Plex URLs carry tokens. Derive a category and send
that (see `LiveJoinTelemetry`), or use `SensitiveDataRedactor.safeURLString`.
