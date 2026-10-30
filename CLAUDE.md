# Rivulet - Claude Context

Rivulet is a tvOS media client for Plex, Jellyfin, Silo and IPTV (the iOS app is Plex and IPTV only). The primary surfaces (Home, Library, Search, Discover, Media Detail, the preview carousel, Person detail, Music, and the player chrome) are **UIKit**, as is Settings; SwiftUI remains for thin navigation shells and Live TV slots.

**UIKit is the default. Do not add SwiftUI to a primary surface.** When you find SwiftUI in one, assume it is a leftover and check reachability before building on it.

**The rule covers enhancements, not just new surfaces.** A substantial addition to
an existing SwiftUI file on a UIKit surface is a signal to port that file, not to
extend it. The player's render layers count as a UIKit surface: being
non-interactive kept SwiftUI overlays there from fighting the focus engine, which
is the only reason they survived as long as they did. The subtitle overlays were
the worked example (ported to `CaptionOverlayView` in `2e5989c`), and staying in
SwiftUI had cost three hacks UIKit does not need:
- SwiftUI `Text` has no stroke, so the caption outline drew the whole string 8
  times at offsets. `NSAttributedString` with a negative `.strokeWidth` is one pass.
- A text box cannot be measured without a layout pass, so cue placement estimated
  half the box height and was wrong for multi-line cues. `boundingRect` is exact.
- `LiveTVAetherPlayerViewController` wrapped the overlay in a `UIHostingController`
  and rebuilt its root view from five call sites, because nothing observes the
  player from SwiftUI. A plain subview needs none of that.

**A clean SwiftLint run does not mean you complied.** The
`swiftui_import_on_uikit_surface` rule only scans paths matching
`Views/**/UIKit/**`. Everything under `Views/Player/`, `Views/Player/Aether/`, and
`Services/**` is invisible to it. Judge by the surface the code renders on, not by
whether the linter fired.

**Detail is UIKit, with no SwiftUI fallback.** Every route lands on the same two surfaces: `MediaItemDetailPageViewController` for episodes, `PreviewCarouselViewController(standaloneDetail:)` for everything else. That holds for in-app taps, tile-menu "More Info" / "Go to …", hero Info, and `rivulet://detail` deep links from Top Shelf / Siri (`TVSidebarView.presentDetailForDeepLink`). The old SwiftUI `MediaDetailView` + `MediaItemContextMenu` + `SummarySheet` are **deleted** (`c0b0bf7`); if you find a comment referencing them, it is stale.

The video player is **AetherPlayer** — an adapter around AetherEngine (FFmpeg demux + HLS-fMP4 remux + AVPlayer, with HDR10+ / HLG / EAC3+JOC Atmos, plus a software sample-buffer backend for AV1 / VP9 / MPEG-2 / VC-1 / MPEG-4p2). It is the only player: VOD **and** Live TV. Video MUST render through the engine surface (`AetherVideoSurfaceView` → `engine.bind(view:)`), never an AVPlayerLayer on `currentAVPlayer`. The only other path is `hls`: AVPlayer on a Plex server transcode, used when no direct-play URL exists or as the fallback after an Aether startup failure. `ContentRouter.plan(...)` picks aether vs hls per item. (RPlayer and the localRemux/avPlayerDirect routes have been removed — see git history.)

Silo's negotiated file and server-HLS deliveries stay on the **Aether host**, including native sidecar tracks; they do not use the legacy AVPlayer-only `hls` route.

## Quick Reference

- **Platform**: tvOS 26+ (Apple TV)
- **Language**: Swift 6
- **UI Framework**: UIKit for the primary surfaces (see above); SwiftUI for the rest
- **Video Player**: AetherPlayer for VOD and Live TV; AVPlayer only for the `hls` route (server transcode, primary-when-no-direct-URL or Aether fallback). See `Docs/RIVULET_PLAYER.md`.
- **AetherEngine**: consumed as an **upstream** SwiftPM dependency (`superuser404notfound/AetherEngine`), pinned `exactVersion` (7.52.0), with the `DualLayerDolbyVision` (P7 FEL), `DolbyVisionStillReshaping` (P5 stills), `TrueHDObjectAudio` and `DTSXObjectAudio` package traits set in `project.pbxproj`; object audio stays off until Settings → Playback → Height Speakers names a layout. A bump must keep the traits. **There is no fork** — engine fixes need an upstream release or a host-side workaround; do not propose editing engine sources. Bumping it has a procedure: use the `aether-update` skill. Every bump gets a changelog line. FFmpeg + libdovi arrive **only transitively through Aether**; there is no app-level FFmpeg layer and no direct FFmpegBuild dependency. Since FFmpegBuild 2.0.0 the FFmpeg libs ship as **embedded dynamic frameworks** in `Rivulet.app/Frameworks/` — their `MinimumOSVersion` (26.0) must stay >= `TVOS_DEPLOYMENT_TARGET` (26.0), so do not raise the deployment target.
- **Design Guide**: See `Docs/DESIGN_GUIDE.md` for UI/UX patterns
- **Repo is public**: keep commit messages short and plain; no internal detail.

## Project Structure

Five code roots. `RivuletCore/` is a buildable folder compiled into BOTH app
targets (not a module: `internal` spans each target); `Rivulet/` is the tvOS
app, `RivuletiOS/` the iOS app, `TopShelfExtension/` the tvOS Top Shelf, and
`AssetPackExtension/` the tvOS Background Assets downloader that fetches the
speech model as an Apple-hosted asset pack (`SpeechModelStore`; Debug builds,
which can't reach Apple hosting, fall back to Hugging Face into Caches; repack
with `Scripts/speech-model-pack.json`). See "Platform Boundary" below for what
goes where.

```
RivuletCore/            # Shared tvOS + iOS. The ONE Plex client (PlexNetworkManager,
│                       #   PlexAuthManager, PlexUserProfileManager), Models/Plex,
│                       #   TMDB, WatchProgressPolicy, IPTV parsers,
│                       #   Security (attest, keychain), Sentry startup, Secrets,
│                       #   OpenSourceLicenses, Plex watchlist, LiveTV/ (the ONE
│                       #   Live TV stack: LiveTVDataStore, Plex + IPTV providers,
│                       #   LiveTVSourceConnector, LiveShelves), IPTV/ (parsers,
│                       #   DispatcharrService), Playback/ (CaptionAppearance,
│                       #   IntroDBClient), Streaming/ (quality decision, throughput,
│                       #   version ranking), Scores/ (Live TV scoreboard).
│                       #   NO #if os(...), lint-enforced.
RivuletiOS/             # iOS/iPadOS app (SwiftUI). Shell/ (tabs, Account sheet,
│                       #   navigation contract), Plex/ (IOSPlexSession + its
│                       #   extensions, IOSPlexAdapters, Home/Library/Detail views;
│                       #   no endpoint code), Search/, Settings/, LiveTV/ (views
│                       #   over the shared LiveTVDataStore), Player/ (iOS
│                       #   AetherPlayer, IOSPlaybackController: PiP, Now Playing),
│                       #   Downloads/ (background transfer, download center, list;
│                       #   records + offline progress live in RivuletCore/Downloads).
Rivulet/                # The tvOS app — everything below.
├── Models/
│   ├── Shared/         # RivuletLink (the one rivulet:// definition) and TopShelfItem,
│   │                   #   both also compiled into the Top Shelf extension
│   └── SwiftData/      # Persistent models (Channel, EPGProgram, PlexServer)
├── Services/
│   ├── DeepLinkHandler.swift  # Opens a RivuletLink or Siri activity once the shell is ready
│   ├── MediaProvider/  # The backend seam (MediaProvider, PhotoProvider, registries);
│   │                   #   Plex/ and Jellyfin/ implement it (see "Media providers")
│   ├── Plex/
│   │   ├── (PlexDataStore, …; the Plex client lives in RivuletCore/Plex)
│   │   └── Playback/   # AetherPlayer + routing/remux (see Docs/RIVULET_PLAYER.md),
│   │       │           #   HLSTrustRelay (loopback relay for the hls route)
│   │       ├── Pipeline/     # ContentRouter (routing decisions)
│   │       ├── ContentFilter/ # Local mute/skip filter (see "Content Filter (VOD)"),
│   │       │                  #   SubtitleImageReader (reads image subtitles on device)
│   │       └── Subtitles/    # LibassRenderer + ASSCompositor (the libass layer), SubtitleCue,
│   │                          #   VTT/SRT/ASS parsers (content-filter only; captions are not app-parsed)
│   ├── LiveTV/         # LiveTVSessionHandoff (store + providers live in RivuletCore/LiveTV)
│   ├── Insights/       # InsightsTriviaClient, InsightsShowIDResolver (in-player cast/trivia panel)
│   ├── Cache/          # CacheManager, ImageCacheManager, TopShelfComposer,
│   │                   #   TopShelfImageCompositor (Top Shelf artwork and logo placement)
│   └── Focus/          # FocusMemory (tvOS section focus restoration)
├── Views/
│   ├── Player/         # UniversalPlayerView, UniversalPlayerViewModel, PlayerContainerViewController,
│   │                   #   AVPlayerLayerView, TrackSelectionSheet, PlayerPresenter
│   │   ├── Aether/     # AetherVideoSurfaceView, AetherSubtitleCue
│   │   ├── Subtitles/  # SubtitleModel (cue store; publishes the active set)
│   │   └── UIKit/      # CaptionOverlayView (the only caption renderer) + ASSOverlayView,
│   │                   #   PlayerRailView, PlayerRailPanelView, PlayerProgressBarView,
│   │                   #   PlayerInfoPaneViews (AVKit info pane: Info card, card rows), UpNextRowState,
│   │                   #   pills (canonical player chrome, cloned from AVKit; DEBUG AVKitScrubProbe measures it),
│   │                   #   PostVideoOverlayView (post-playback / Up Next),
│   │                   #   Insights* views (in-player cast/trivia pane; backed by Services/Insights + TMDB)
│   ├── Media/          # PreviewContext, HeroBackdropSupport, FocusScrollMotion
│   │   ├── UIKit/, PlexHome/UIKit/, MediaDetail/UIKit/, Person/UIKit/, Library/UIKit/, PreviewCarousel/UIKit/
│   │   │              #   The canonical UIKit home/detail/library/person/carousel surfaces.
│   │   │              #   UIKit/Cells/ContinueWatchingCard{Compositor,Placement,Cache} build the
│   │   │              #   Continue Watching card and hold the shared artwork analysis
│   │   └── Hero/       # HeroPlaySession + hero support (SwiftUI HeroBackdropLayer/OverlayContent removed)
│   ├── Music/UIKit/    # MusicLibraryViewController (+ MusicLibrarySidebarView, MusicBrowseViewController),
│   │                   #   MusicAlbumViewController (album and playlist), MusicArtistViewController,
│   │                   #   MusicNowPlayingViewController (+ MusicQueueStripView, MusicLyricsPaneView),
│   │                   #   MusicChrome (the shared primitives), MusicLockupCell, MusicTrackRowCell,
│   │                   #   MusicMenus, MusicPresenter. A measured clone of Apple Music on tvOS 26.
│   ├── Photos/UIKit/   # PhotoLibraryViewController, PhotoGridViewController, PhotoViewerViewController
│   ├── Discover/       # DiscoverViewModel (SwiftUI Discover* views removed; UIKit home renders Discover)
│   ├── LiveTV/         # EPGGuideView + GuideLayoutView (56-style guide), LiveChannelsPaneView,
│   │                   #   LiveTVAetherPlayerViewController (UIKit live rail), LiveTVContainerView,
│   │                   #   MultiStreamViewModel; UIKit/: LiveBrowseViewController ("What's On"),
│   │                   #   LiveMultiviewViewController, LiveCardCell, LiveMiniPlayerView
│   ├── Settings/       # SettingsDescriptors, SettingsModels, PlexAuthView
│   │   └── UIKit/      # SettingsContainer/Page VCs, SettingsCell, SettingsPageModels (canonical)
│   ├── Components/     # CachedAsyncImage, GlassRowStyle, WhatsNewView,
│   │                   #   ProfilePickerOverlay (launch gate), ProfileSwitcherPopup (sidebar panel)
│   └── TVNavigation/   # TVSidebarView (tab content, launch gates), RootShellHost,
│       │               #   MenuPressInterceptor, NavigationEnvironment
│       └── UIKit/      # RootShellViewController, ShellSidebarViewController,
│                       #   ShellSidebarModel (the custom sidebar, see "Sidebar and profiles")
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

Move existing files into `RivuletCore/` when a slice actually needs them, not
speculatively. The list above is the destination, not a migration order.

**New business logic starts in `RivuletCore/`, even when only tvOS ships it.**
Rules, server and API behavior, and non-UI state go there from the first
commit, written generic over the item type (closures for keys and dates) so
they do not depend on tvOS models like `MediaItem`; only views, input and
tvOS-shaped stores stay in `Rivulet/`. #87 is the worked example of getting
this wrong: multi-server discovery and the Continue Watching merge landed in
the tvOS folder and had to be lifted before iOS could use them.

The Plex stack is already across: `PlexNetworkManager`, `PlexAuthManager`,
`PlexUserProfileManager`, `Models/Plex/`, the TMDB client, `IntroDBClient`,
`WatchProgressPolicy`, the attested `URLSession`, and the Sentry startup.
So is the Live TV stack: `LiveTVDataStore`, `PlexLiveTVProvider` + the timeline
keepalive, `IPTVProvider`, `DispatcharrService`, `LiveTVSourceConnector` (the
verify-then-add behind both apps' add-source forms) and `LiveShelves` (What's On
rows). **There is exactly one Plex client.** `RivuletiOS/Plex/` holds
`IOSPlexSession` (the iOS content store, counterpart of `PlexDataStore`, with its
`+Account`/`+Content`/`+Playback` extensions), `IOSPlexAdapters` (display
accessors) and the SwiftUI views; no endpoint code. Never add a second decoder for a Plex
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
`RivuletCore`. The `PlayerProtocol` conformance stays tvOS. iOS has its own
adapter, `RivuletiOS/Player/AetherPlayer.swift` (the only iOS file that imports
AetherEngine), driven by `IOSPlaybackController` (PiP, background audio, Now
Playing). The mapping has not moved to `RivuletCore` yet, so a mapping fix
currently lands in both adapters. This is not bookkeeping: keeping both classes in one
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

The SwiftUI primitives below apply only to the remaining SwiftUI surfaces (Live TV slots, nav shells). No custom focus scope manager; isolation comes from system mechanisms:

- **`fullScreenCover`** — automatic focus isolation for overlays/popups
- **The sidebar is the UIKit shell** (`RootShellViewController` + `ShellSidebarViewController`), not `TabView(.sidebarAdaptable)`: the shell drives sidebar/content focus (`expandSidebar` / `collapseSidebar`, the edge catcher), and `TVSidebarView` only builds tab content
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

### Sidebar and profiles

**The sidebar is custom, and its reference is the Apple TV app's sidebar.** The
Apple TV app does not use UIKit's system tab sidebar: it builds its own on a
split view, with its own panel radius, row pitch, focus platter and icon column.
`ShellSidebarViewController`'s `Metrics` are measured against that. Do not
measure the system sidebar (`UITabBarController`, `TabView(.sidebarAdaptable)`)
as the reference: its numbers differ (a 52 pt panel radius against the Apple TV
app's 40), and matching it moves Rivulet away from the app it sits beside. Only
the panel frame, the pill origin and the morph timing still come from the system
sidebar.

- **`RootShellViewController` is the shell**: one content child per tab, the
  sidebar as chrome, the left-edge focus catcher and the Menu policy. SwiftUI
  stays the tab authority. The shell reports intent through `onTabChange`, and
  `TVSidebarView`'s selection binding pushes the result back. The rows come from
  `ShellSidebarModel.sections`, which is pure and unit-tested.
- **The profile row is not a tab.** Selecting `.account` never becomes
  `selectedTab`: with more than one profile it presents `ProfileSwitcherPopup`
  (the profile panel), and while that is up the collapsed pill names the user.
  Closing the panel on the profile it opened on reopens the sidebar on the
  profile row (`profileRowRequest`). Switching to another profile goes to Home
  with the sidebar closed (`collapseRequest`), as the Apple TV app does.
- **Live TV with no media server opens on Live TV.** With no Plex, Jellyfin or
  Silo signed in, `ShellSidebarModel` hides Search, Home, Discover and Watchlist
  (`opensToLiveTV`) and `TVSidebarView` switches to the Live TV tab.
- **A new install sees the setup landing instead of the shell.**
  `SetupLandingViewController` (cards for Plex, Jellyfin, Silo and Live TV on
  `WelcomeGlowView`, maps from `tools/welcome/flow_map.py`) stands in until Start
  Watching sets `setupComplete`; signing out of everything clears it. Its flows
  are the Settings pages themselves, run standalone
  (`SettingsContainerViewController(rootPage:)` + `onExit`): never a second form.
- **Settings must not drop navigation during a page transition.** The incoming
  page already accepts focus and form completions. `SettingsContainerViewController`
  defers the pending push/pop until the transition finishes; a successful Silo PIN
  selection returns past both the PIN and profile pages. Only the top page may
  navigate or update focus help; changing pages clears the previous row's help.
- **"Profile Picker on Launch" is a hard gate.** `ProfilePickerOverlay` reports a
  chosen profile through `onSelected`; `TVSidebarView` re-presents the picker on
  any other close, so Menu cannot dismiss it into the last profile's content.
  Content, What's New and a held deep link (`DeepLinkHandler.isShellReady`) all
  wait behind it. The same gate comes up mid-session when
  `needsProfileSelection` turns true, and it stops music and dismisses whatever
  is presented first, because the picker cannot present over a player.

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
  Adopters: `LiveTVPressCatcher`, `InfoPopupViewController`, Music's Now
  Playing anchor, `PhotoViewerViewController`.
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
  the engine cannot perform, so reuse the press override's own predicate
  (the player's `contentOwnsPress`, the alphabet strip's `containsFocus`).
  Adopters: the Live TV guide (`EPGGuideView`), the player's content anchor,
  the library alphabet strip (`LibraryAlphabetBarView`) and Music's scrubber. The
  player's info panes don't need it: a `UIFocusGuide` between the pills and
  the pane carries Up and Down.
- **A focusless surface that hands some touches to another recognizer passes
  `swipeGate`.** The focusless binding claims its swipes unconditionally
  unless `swipeGate` is given; then each swipe asks it in
  `gestureRecognizerShouldBegin`. Music's Now Playing anchor is the adopter:
  over loaded lyrics with the controls hidden, vertical touches belong to one
  indirect pan that drags the lyric column, so the Up and Down swipes decline
  exactly when that pan may begin (one predicate, `lyricsBrowsable`).
  `onHoldEnd` reports a hold's release so a repeat can stop. Lyric browsing
  adds no focus item: `MusicLyricsPaneView` stays non-interactive, and showing
  the controls ends browsing.
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
- **A press a presented VC declines reaches its PRESENTER's `pressesBegan`.**
  The presented VC's next responder is the presenter, so a VC that overrides
  `pressesBegan` and presents anything must open with
  `guard presentedViewController == nil else { super.pressesBegan(...); return }`
  and gate its swipe recognizers the same way. Without it, Down on the show
  page's Watched alert also scrolled `PreviewCarouselViewController` behind it.
- **The VOD player's content state has ONE press owner.**
  `PlayerContainerViewController`'s `pressesBegan`/`Ended` ("Content-state
  presses") handle Left/Right/Up/Down/Select whenever no control holds focus,
  reached from `ContentFocusAnchorView`, an invisible UIKit focus stop. Do not
  put focus back on a SwiftUI layer there (arrow presses to a focused SwiftUI
  item never reliably reached UIKit, which is why IR/CEC and clicks-only Siri
  Remotes could not skip: #212, #232, #305), and do not add a GameController
  listener for anything that also arrives as a `UIPress`:
  `RemoteInputHandler` (in `UniversalPlayerView.swift`) acts only on input
  with no `UIPress` (clickpad rotation, shoulders, X). Tap-vs-hold is
  still duration-based (`DirectionalPressDetector`); how a held IR button
  arrives (#212) still wants InputProbe field data.
- **The focus engine's occlusion test is geometric, not hit-test based.** Any
  non-hidden view with alpha above zero that sits above an item's frame makes
  that item unfocusable, even with a clear background and a `hitTest`
  override returning nil. `UIFocusDebugger.checkFocusability(for:)` names the
  occluder. The library's A–Z strip shipped full-bleed once to host its centre
  letter and silently made every grid tile unfocusable: Left from a letter
  went to the shell's edge catcher, Select and Menu did nothing. A view that
  overlays a focus surface must be exactly its own footprint, and anything
  larger (the letter indicator) must be `isHidden` before a focus request.
- **A held Up/Down hands focus to tvOS's fast-scroll index bar after ~1.5s.**
  The engine moves row by row, then focuses `_UIFocusFastScrollingIndexBarView`
  (a hidden subview of the collection, the "dots") and stops issuing focus
  moves. That hand-off bypasses `shouldUpdateFocus` and happens even under
  `indexDisplayMode = .alwaysHidden`; on this self-scrolling collection the
  system bar scrolls nothing, so focus just vanishes. `PlexHomeViewController`
  treats the hand-off as the fast-mode signal and drives the offset itself
  while the arrow stays down (`heldArrow`, `stepFastScroll`), landing on the
  centre tile on release. Do not refuse the engine's repeat moves instead:
  after the same ~1.5s it escalates past the collection to the sidebar.

### Context Menus (long-press)

**On tvOS 26, UIKit's context-menu machinery never engages** — not in this app, not in a clean-room control. A held Select press is delivered then cancelled at +0.4s and no configuration is ever requested. `UIContextMenuInteraction` / `contextMenuConfigurationForItemsAt` are dead ends; do not reach for them, and do not "fix" their absence.

The canonical menu is therefore hand-built: a plain `UILongPressGestureRecognizer` (needs a simultaneous-permissive delegate, or the collection view's own press recognizers force it to fail) feeding `TileMenuPopupViewController`, with actions built as `[[TileMenuAction]]` (inner arrays = divider-separated groups). `UIAction` is useless here — its handler can't be invoked programmatically. Builders live in `PlexHomeViewController.tileMenuSections`.

SwiftUI's `.contextMenu` *does* still work — the tvOS 26 breakage is UIKit-only. But do not reach for it on a UIKit surface: hosting each tile to get it re-introduces the per-cell `UIHostingController` the UIKit migration removed for its measured hitch cost. Nothing in the tvOS app uses it now.

**`UIButton.menu` with `showsMenuAsPrimaryAction = true` does work on tvOS 26** (verified in the tvOS 26.5 simulator, not yet on a device). Select opens the system glass menu, with checkmarks, subtitle rows and submenus, and Menu closes only the menu. Music uses it for every "..." button and for Sort and Filter (`MusicMenus.uiMenu`; Sort and Filter in `MusicBrowseViewController.refreshMenus`). Only long press needs the hand-built popup.

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

Live TV: MultiStreamViewModel instantiates AetherPlayer() per multiview slot, rendered by
         LiveMultiviewTileView through the engine surface. Up to 4 concurrent slots.
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
  feeds the SAME view from `AVPlayerItemLegibleOutput`, and the VOD `hls` route
  from Plex's subtitles endpoint (below). One renderer, three sources.
  Do not add a second view, and do not mount it through a `UIHostingController`: that
  applies the tvOS title-safe inset to the content, so every caption margin is
  measured against the wrong box.
- **ASS/SSA renders through libass**, inside `CaptionOverlayView` as `ASSOverlayView`
  (one caption renderer, now with a libass layer). VOD loads with
  `preserveASSMarkup: true`, so an ASS track's cues arrive as raw event lines
  (`Body.assEvents`). `AetherPlayer` publishes `ASSTrackSource` (header plus the
  file's `fontAttachments`) and `sourceTime(atHostTime:)`, the frame-accurate
  clock the display link renders against. libass comes from our own
  `l984-451/LibassBuild` (one static xcframework, pinned `exactVersion`); do not
  swap in swift-ass-renderer, AssKit or mpvkit binaries.
  - **Video Override decides the path.** All three `allowsContent*` true (the
    default): libass. Any pinned: plain captions in the system style, keeping
    `\an`/`\pos`, dropping drawings. libass's selective style override is NOT a
    substitute: it never touches inline tags and skips positioned events.
  - **libass's ReadOrder dedupe is off** (`ass_set_check_readorder(track, 0)`):
    real files hardcode ReadOrder 0. `ASSOverlayView` dedupes on the engine's
    cue id (stamped once per session, kept across re-decodes); id 0 falls back
    to start plus line.
  - **Rail and Height stepper lift dialogue through `ass_set_line_position`**,
    which libass applies to non-positioned events only.
  - **libass renders ahead; the display tick never calls it.** `ASSRenderQueue`
    keeps ~500 ms of units (image + start/end) rendered on the libass queue: a
    new unit per display frame while libass reports a change, the last one
    extended while it doesn't. The tick picks the unit for `targetTimestamp`.
    Rendering inside the tick is what made tracked signs judder and trail
    (discussion 244); Infuse renders ahead the same way. Only a seek (playhead
    outside the queue by more than its window) resets it; falling slightly
    behind renders on from the playhead, or every tick resets into one stale
    frame and nothing shows for seconds (caught on device). The step widens to
    twice the measured cost when libass can't keep a frame's pace.
  - **Images composite into at most 4 regions**, one layer each
    (`ASSCompositor`), never one buffer over the union: a top sign plus bottom
    dialogue was ~30 MB per frame at 4K. Measured on a 2nd-gen Apple TV 4K
    (optimized build): ~4.5 ms per frame at 3840x2160. A Debug build is ~12x
    slower; never judge subtitle performance on Debug.
  - **Bumping libass**: run LibassBuild's `build.sh`, tag `<libass>-<rev>` (pinned
    `0.17.5-2` today) and never move a published tag, because SwiftPM records each
    tag's revision and refuses one that changes. The module map stays in
    `Headers/Libass/`: at the `Headers` root it collides with LibDovi's in the
    shared `include/` directory.
- **On the Plex `hls` route, text subtitles are drawn by the same libass layer.**
  `buildHLSDirectPlayURL(clientRendersTextSubtitles: true)` asks for an ASS
  subtitle target and adds `advancedSubtitles=text` (without it PMS still burns
  ASS in); `TranscodeSubtitleStream` reads `/video/:/transcode/universal/subtitles`
  and feeds `SubtitleModel` on AVPlayer's item clock. Measured on PMS 1.43.4:
  - The endpoint takes the running session's exact `start.m3u8` query; with no
    session it answers 400. `subtitleStreamID` there is ignored: the part's
    selection (`PUT /library/parts/<id>`) decides.
  - It is one chunked response (mislabelled `text/vtt`) held open for the whole
    playback, advancing only as video segments are fetched, so it needs the
    long-timeout session (`openEndedBytes`). Cue times are absolute media time.
  - Embedded ASS keeps its header and styles; font attachments do not come
    through. SRT arrives converted. PGS/VobSub still burn in.
  - A seek past the transcoded range closes the stream, and requesting it again
    starts a second session that kills the video, so the player restarts the
    transcode at the playhead instead (one extra rebuffer).
  RPlayer's old sidecar pipeline (`SubtitleManager`, `SubtitleOverlayView`) is
  deleted; do not revive it. Jellyfin's transcode still uses server subtitles.
- **Generated subtitles** (the player's subtitle menu, aether route only; the first
  pick downloads the model and the open menu shows its progress) are written from the content filter's speech model (`SpeechCaptions` groups
  the heard words into lines). The track is id `generatedSubtitleId` (-2), added only
  to the menu (`subtitleMenuTracks`), never to `subtitleTracks`, so intent, Plex
  timeline ids and the filter's track logic never see it. While it shows, the
  overlay's model holds generated cues and the engine's cues (the filter's unseen
  read) wait in `engineCues`. The pick saves no preference; it carries on to the
  session's next items unless one has a real English track (`preferRealSubtitlesOverGenerated`).
- `SubtitleParser.swift` survived that cull and is NOT dead, but nothing in it
  renders: it serves the content filter. `VTTParser` reads `text/mcf+vtt` lists
  (`ContentFilterParsers`), and all three parsers (VTT, SRT, ASS) read a title's
  external subtitle file in full so language muting works with subtitles off and on
  the `hls` route (`ContentFilterSources`). Check for the type, not the filename,
  before deleting anything here.

**Playback States** (PlayerProtocol): `.idle`, `.loading`, `.playing`, `.paused`, `.buffering`, `.ended`, `.failed`

**Playback trusts the same certificates as the Plex API session.** One rule,
`PlexCertificateDelegate.trustsServer`: system trust, or else, for a raw IP only, the
valid plex.tv-issued `*.<hash>.plex.direct` certificate that plex.tv lists for the
account's OWN server at that address. Never a DNS name, never a shared server's hash.
It is what `EngineTLS.serverTrustEvaluator` answers with in both `AetherPlayer` adapters.
Connection probes hit `/identity` without a token and must get back the server's
`machineIdentifier` before the token is sent anywhere. AVPlayer has no trust hook, so the tvOS `hls` route goes
through `HLSTrustRelay` (a loopback relay) when system trust refuses the server.
Never send a Plex server request through `URLSession.shared`: it browses fine on
most servers and fails on the ones reached by raw IP (#314, #337).

#### Routing policy (VOD)
1. `ContentRouter.plan(...)` returns `PlaybackPlan { primary, fallbacks }`. Route cases: `.aether`, `.hls`.
2. `.aether` — whenever a direct-play URL is available (AetherEngine handles demux + remux + HDR internally; software-decodes AV1 / VP9 / MPEG-2 / VC-1 / MPEG-4p2). DV P7 FEL composes both layers on a DV panel, P7 MEL becomes 8.1 (see "HDR / DV").
3. `.hls` — server-side transcode; primary when no direct-play URL exists, and the fallback after an Aether startup failure. `requiresVideoTranscode` codecs force a video transcode (not just remux) on this route.

#### Live TV
Two layouts: What's On (`LiveBrowseViewController`, the default) and the Guide (`GuideLayoutView`). Both play through `LiveTVAetherPlayerViewController` on the VOD glass rail. Multiview (`LiveMultiviewViewController`) runs **AetherPlayer** per slot (`MultiStreamViewModel` instantiates `AetherPlayer()`, each tile binds the engine surface), up to 4 concurrent slots. HDHomeRun delivers a direct stream; DVB tuners require a Plex transcode URL with full client-profile parameters (see Plex Live TV section below).
**Xtream Codes** (`RivuletCore/IPTV/XtreamService.swift`) is live channels only, never VOD or series: account check on `player_api.php` with no `action`, channels from `get_live_streams` + `get_live_categories` (not `get.php`), guide from one bulk `xmltv.php`, streams `/live/<user>/<pass>/<id>.ts`. Panels mix ints and strings for the same field, so replies are walked by hand; never put a reply body in a log or error, `player_api.php` echoes the password. Never loop `get_short_epg` across channels: it gets users rate-banned.
iOS reads the same `LiveTVDataStore` and saved sources and adds sources through the same `LiveTVSourceConnector`. Dispatcharr API keys and M3U playlist/guide URLs (which often embed credentials) live in the Keychain (`liveTVSourceToken_`, `liveTVSourceM3U_`, `liveTVSourceEPG_` + source id); the saved source JSON keeps one only if the Keychain write fails. An M3U source id is a hash of its URL (`m3uSourceId`), never the URL itself; older URL-keyed sources are re-keyed on launch with their saved channel ids renamed.

### Content Filter (VOD)

A local VidAngel/ClearPlay-style filter: mute language, skip scenes, never touch the
file. Off by default (Settings → Playback → Content Filtering).
`ContentFilterManager`, owned by `UniversalPlayerViewModel`, merges three sources and
judges all of them against the user's settings at playback time:
1. **The title's own subtitle file**: the English external text stream Plex serves
   (`ContentFilterSources.transcriptStream`), fetched and scanned against
   `ProfanityDictionary` up front. It is the only language source on the `hls` route.
2. **The engine's subtitle cues**: the track on screen, or, with subtitles off and
   no other language source, an embedded English or unlabeled track the filter
   selects and reads unseen (`ContentFilterSources.silentTrack`,
   `syncSilentSubtitleRead`; no preference saved, the user's subtitles stay Off).
   Image tracks (PGS, VobSub, DVB) are read on device by `SubtitleImageReader`
   (Vision), in memory only. Aether route only.
3. **An imported MCF/EDL list** from the user's list source, the only source of
   scene skips. A folder source is searched by file name, IMDb id, then rating key.

Rules that look wrong until you know them:
- **An embedded subtitle stream cannot be fetched on its own.** It has no `key`,
  and asking PMS for one by stream id answers 501. That is why source 2 reads the
  engine's cues: the silent track is selected in the engine and never drawn. The
  engine holds one subtitle selection, so a track the user turned on always wins
  it, and the silent read only runs while theirs is Off.
- **Image cues are read ahead of the playhead**, one at a time and off the main
  thread, so a line's words are usually known before it is spoken. Text ranks
  before image and forced-only last when the silent track is picked.
- **A title with no English or unlabeled subtitle track cannot be language
  filtered**, and neither can an embedded-only title on the `hls` route. The rail
  says so instead of failing quietly (`ContentFilterSources.languageNotice`): "No
  Readable Subtitles", or "Use English Subtitles" when another language's track is
  on screen and blocks the silent read.
- **moviecontentfilter.com's `.mcf` download is not in real time.** It rescales the
  title onto 0–99:59:59.999 and leaves the player to map it back with the release's
  own start and end, which Rivulet can't know, so such a file is rejected as
  `.unsynchronized`. That site's EDL export takes the start and end and is the
  supported route. An MCF file is a full annotation, not a per-user filter, which is
  why `FilterCategory(mcfName:)` drops topics like product placement and kissing.
- **The list cache is keyed by the URLs a list would be fetched from**, not the
  rating key, so clearing or changing the source can't resurrect an old list. The
  cached copy is deleted only when every candidate answers "not found" (404/410, or
  S3's 403) or holds nothing usable; a timeout, a 5xx, a 401/429, or a page that
  isn't a filter list at all (a captive portal) leaves it in place.
- **Profanity Strength applies to profanity from every source**, imported lists
  included. EDL entries carry no severity and count as strong.
- **Only "fuck" matches inside a word.** Every other term is whole-word, because
  every other term has an innocent host ("Scunthorpe", "cocktail", romanized names).
- **The rail button pauses filtering for the current title only.** It shows only
  while filtering is on in Settings, and `reset()` clears the pause on every item.

### Top Shelf and deep links

**URL and user-activity entry points live on the SwiftUI scene and must stay
there**: `.onOpenURL` and `.onContinueUserActivity` on the `WindowGroup` in
`RivuletApp.swift`. In a scene-based app UIKit never calls the app delegate's
`application(_:open:options:)`, and it fails silently. Rivulet handled links
there for six months, and for that whole time every Top Shelf button opened the
app and did nothing else.

- **One link definition**: `Models/Shared/RivuletLink.swift` builds and parses
  `rivulet://play` and `rivulet://detail`, and is compiled into the app and the
  Top Shelf extension. Do not write the scheme, a host or a query name as a
  string anywhere else.
- `DeepLinkHandler` holds a link that arrives before the shell is ready
  (`isShellReady`: launch, the profile gate) and delivers it afterwards.
- **Verify any change by opening a link**, with the app closed and with it
  running. A clean build says nothing about whether the scene receives the URL.

```bash
xcrun simctl openurl <udid> "rivulet://detail?ratingKey=<key>"
xcrun simctl openurl <udid> "rivulet://play?ratingKey=<key>"
```

### Artwork analysis (Continue Watching, Top Shelf)

Two surfaces read the artwork before drawing over it, and they share one
analysis. `ContinueWatchingCardCompositor.analyse` (in
`ContinueWatchingCardPlacement.swift`) turns a still into `Signals`: face boxes,
a luminance grid, and Vision's attention and objectness maps. The scoring is pure
functions over those signals in the same file (`cost`, `chooseSlot`, `choose`,
`placement`), tested without Vision in `ContinueWatchingCardCompositorTests`.

- **Continue Watching card**: `ContinueWatchingCardCompositor` builds the card
  as one image (the still, a mirrored blurred band under it, a gradient), once
  per still, cached by `ContinueWatchingCardCache`. The title rests leading, on the
  floor (`restingPlacement`), and stays there while it reads (`goodEnoughCost`);
  it moves only when another spot reads clearly better (`moveMargin`), so a row
  keeps one look. `trailingCost` keeps it off the trailing edge unless needed.
  The same hold applies to Top Shelf and the pause screen through `chooseSlot`.
- **Top Shelf logo**: `TopShelfImageCompositor.placement` runs the same `choose`
  over its own candidate rects.
- **The Home hero does not read its artwork.** Its scrim is the Apple TV app's,
  constant black on every image (`HeroBackdropView`); do not bring back a
  brightness-driven boost (#342: it read as a dim filter next to Apple's).
- **Vision needs the CPU pin in the simulator.** The simulator can only build
  Vision's models on the CPU; without `setComputeDevice` under
  `#if targetEnvironment(simulator)` face detection fails there, `Signals.faces`
  is nil and each title stays where it started, which looks like scoring that
  does nothing. Even pinned, the simulator's saliency and objectness maps are
  junk: the same near-zero map for every image (measured 2026-10-20). Faces
  work, but almost every title stays on the floor. **Judge placement on a device
  or on a macOS bench** (swiftc the two pure files plus a small `main.swift`;
  the Mac's Vision returns real maps), never in the simulator.
- **Vision and drawing run on `ContinueWatchingCardCache`'s own serial queue
  (`offPool`), never in a `Task`.** On Swift's cooperative pool a few cards'
  analysis held every thread of a 3-core Apple TV (2nd-gen 4K), and image
  loads and Plex requests queued behind it: Home stayed empty on some
  launches. The simulator has the Mac's cores and never shows it.
- **Tune the weights, never special-case a title.** A bad placement is fixed in
  `subjectWeight`, `faceWeight`, `travelWeight`, `comfortableLuma` or
  `trailingCost`, with the still added as a test case. A per-title exception fixes
  one card on one server.

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
The old optimistic path (`PlexDataStore.updateItemWatchStatus`,
`.episodeWatchedStatusChanged`) is deleted; don't revive it, and don't
reintroduce optimistic Continue Watching mutation from a shelf (reverted in
`90bfd2b` for focus reasons).

### Content margin and tile grid

Every media surface (Home hero and shelves, library and watchlist grids, Search,
Discover, Person, the expanded detail with its below-fold rows and footer) rests
on one grid, measured against the Apple TV app's layout:
an **80 pt** side margin, **40 pt** between tiles, and a tile width that divides
the rest by the column count (`MediaRowMetrics.gridWidth`: 6 across = 260 for
posters and cast, 5 = 320 for Continue Watching, 4 = 410 for episodes, 3 = 560).
`MediaRowMetrics.rowLeading` is the one margin, and `tileGap` the one gap. Do not
write either number anywhere else.

- **The grid numbers are ARTWORK numbers; a cell is the lockup's frame.**
  `TVPosterView` and `TVCardView` rest their artwork short of their frame and grow
  into it on focus, so `MediaRowMetrics.Tile` derives the frame, the spacing
  between frames and the frame inset that put the artwork on the grid. Size a
  cell from `Tile.frame`, never from the artwork width.
- **The collapsed carousel card is the one exception to 80**: its content sits 160
  from the screen edge (120 card inset + 40), `PreviewCarouselGeometry.collapsedChromeInset`.
  The below-fold collection rests there untransformed and is pulled left by the
  difference on expand. Its sections set `contentInsetsReference = .none`: the
  collection's safe area changes with that pull, and a section measured from it
  moves outside the morph's clock.
- **`ShelfRowCell` shelves land on the grid exactly; the detail's episode, cast and
  trailer rails do not.** Those are orthogonal sections the focus engine scrolls:
  they rest on the margin, but a mid-rail landing is the engine's (measured: the
  focused view flush with x 1840 going right, about 80 pt past the margin coming
  back left). Insets and in-content padding do not change that; exact landings
  there mean hosting the rail the way `ShelfRowCell` does.
- Music (already at 80), Live TV (`liveLeading`, `EPGTheme.pageMargin`), Settings
  and the sidebar keep margins of their own.

### Media providers (Plex, Jellyfin, Silo)

Jellyfin and Silo are tvOS only. All backends sit behind one seam,
`Services/MediaProvider/MediaProvider.swift`, with `Plex/`, `Jellyfin/` and `Silo/` below it.
Views talk to the protocol. A non-Plex item plays through `ProviderPlayback+Prepare.swift`,
which never names a backend.

- **One GUI for every server.** No backend-only browse or player surface. A feature
  is simply absent when the item's provider does not support it.
- **Never merge across servers, except Continue Watching.** Each server's
  libraries and Home rows show on their own. Names appear only when more than
  one library source is visible. In that case Continue Watching is ONE row (`ContinueWatchingRow`,
  `ContinueWatchingMerge`): the same title on two servers is one card, matched
  on ids only (never title), episodes per show, the copy watched last shown.
  Plex to Plex costs no request (`plex://` guids, `includeGuids=1` on the hub);
  missing movie/show ids come from `itemIdentityKeys(for:)`, cached per provider.
  Episodes resolve their owning show's identity, never their own episode ids;
  static merged See All grids await `resolveIdentities` before freezing cards.
  A card's Mark Watched / Remove reach every copy.
- **Server library visibility composes with individual library choices.**
  `LibrarySettingsManager` owns the per-server `Show Libraries` gate, scoped to
  the Plex profile or native server account. Turning it off hides library/VOD
  surfaces, including native feeds, without signing out or disabling Live TV.
  Keep each library's own hidden state and order so showing the server restores
  those choices; newly discovered libraries inherit the server gate.
- **The account's other Plex servers (#87) ride the same seam.** The selected
  server keeps `PlexDataStore` and the legacy `.plex` paths; every other server
  on the account is a `PlexProvider` from `PlexExtraServers` (RivuletCore:
  per-profile list and tokens from `/resources`, shared with iOS), shown beside
  Jellyfin and Silo by `ServerDataStore`. iOS keys the same servers on
  `PlexMetadata.serverID` / `PlexLibrary.serverID` / `PlexHub.serverID` (nil is
  the selected server) and resolves each through `IOSPlexSession.configuration(serverID:)`.
  `MediaItemRef.isPlex` means the SELECTED server only, so an extra server's
  item takes the provider path; never test `hasPrefix("plex:")` to mean
  "the Plex server".
- **A new feature is a protocol requirement plus one implementation per provider.**
  When a decision point names one backend, generalize it onto the seam.
- Jellyfin's server floor is 10.10 (`JellyfinSession.minimumVersion`), tested on 12.1. No
  per-version code paths.

**Silo's native contract.** Implemented against Silo server commit
`6de6d5e5e285a9b423e95a1122cb39e5bb9ca93b`: API v2 and negotiated playback
protocol v3, never compatibility endpoints or Plex Discover substitutions.

- `SiloSession` stages login/profile/PIN before atomically committing the account.
  Keychain holds token pairs and profile proofs, not passwords/PINs. Providers
  capture `authorityRevision`; reject stale prepare/presentation work after a switch.
  `ServerDataStore` scopes cached slices by account and revision; reload invalidates
  stale work without publishing unchanged empty state.
- The configured display name comes from public `theme/branding.server_name`,
  not the server URL or `system/identity`. Refresh saved names only after account
  and profile verification. Branding failures must not invalidate credentials.
- Description translation follows the Silo profile/library metadata language
  and `metadata-ai.on_view`: `auto`, `button`, or `off`. The selected visible
  movie may start before expansion; adjacent/prefetched cards must not create
  jobs. Keep the original description dimmed while running, restore contrast
  afterward, and retain the provenance icon. Stopping local observation never
  cancels the durable server job or automatically replays an uncertain POST.
- Home rows retain server order, presentation, source ids and cursors. Use
  `hubItems`/`discoveryItems`; respect `MediaHub.canBrowse` when no native
  continuation exists. Native-only Continue Watching keeps its layout position.
  Native featured rows stay authoritative; Jellyfin's cached TMDB matches must
  not trigger Silo-only fetches or create a second hero over native featured rows.
- Discover renders `recommendations/discover` inline rows, as Silo Apple's
  For You → Recommendations does. Pin the case-insensitive For You row, omit
  empty rows, and reject incomplete collection continuations. Do not refetch
  separate section endpoints or add All/See All controls to this feed.
  Collect native provider results directly on `DiscoverViewModel`'s actor before
  publication; keep its generation/cancellation guard so obsolete profiles cannot
  repopulate the screen.
  Use the shared Discover hero for the leading artwork-backed native shelf only
  when no explicit hero exists; replace, never duplicate, that shelf. Discover
  heroes do not append a second section title beneath their controls. A feed
  without hero artwork uses normal shelf clearance and clears the old backdrop.
- `allEpisodes` traverses the returned season content ids: the catalog
  `items/{id}/episodes` endpoint accepts a **season**, not a show.
- People results use native person navigation for Select and long-press; their
  opaque identities must never enter catalog playback or watched-state actions.
- Played sessions stop with a final observed sample; `discardStream` retires
  unplayed reservations without writing zero progress. Native `stop_id` values
  must be canonical lowercase UUIDs. Mutations are never automatically replayed.
- `replaceStream` keeps the native session for track/quality changes. Explicit
  version and Up Next handoffs retire the old reservation before preparing a
  new one when `reservesPlaybackOnResolve` is true.
  Continuous-stall recovery uses the grace-adjusted policy deadline, fenced to
  the current item, source and session; cancelled waits cannot lower a new plan.
- Native track menus use provider shim ids. Engine active-track publishers must
  not overwrite these picks with engine indices.
  Keep Silo actions in the shared On/Off, Language and Style subtitle menu;
  refresh capabilities before presentation and preserve disabled operation rows,
  selection and progress when submenus rebuild.
  Keep on-device generation distinct from Silo search, audio transcription,
  subtitle translation and jobs; nested menus return to their parent with Menu.
  Operation and sync outcomes wrap instead of truncating recovery instructions.
- Playback preferences belong to the profile. Rivulet reads Silo's effective
  `playback.*` values — subtitle language, behavior and forced subtitles among
  them — and applies them by default; the Settings toggle opts out, and a local
  pick overrides for this Apple TV only. Keep Silo's names in the rows ("Always
  on", the contract's own `playback_subtitle_languages` tags), and show the
  profile's resolved value on the Follow row so a preference set in Silo's own
  app is visible here instead of silently ignored.
- Subtitle sync uses the canonical inventory `sync_key`, never a display label,
  engine index or a reconstructed sidecar key. Probe native capability and
  permissions; only the selected syncable track is observed. Poll active jobs
  every two seconds and idle state every ten seconds, fenced to item, file and
  selection. There is no playback realtime subscription.
  Timing reset reads that exact target's strong ETag and sends it in `If-Match`;
  cancellation, stale preconditions and uncertain mutations never trigger replay.
  Silo applies scale/offset to delivered bytes; the local Delay stacks separately.
- A subtitle replan is not automatically a new video. Compare provider-stamped
  canonical transport/session/source/recipe facts, not rotating relay or plan ids.
  Proven caption-only changes prepare and atomically commit fresh text cues while
  retaining video, audio, pause state and display ownership. On preparation failure,
  retain old cues and restore the local subtitle pick without failing the movie.
  Deselect a native HLS legible rendition only after successful commit.
  Actual video changes retain the normal reload and final display cleanup paths.
  Timing-only refresh waits for initial engine readiness and never reloads video.
- Requests uses shared UIKit margins, focus platters and action controls. Keep
  scroll rows clipped below its fixed header. Pagination and retry use the
  submitted query, not an edited search field; uncertain writes reconcile through
  reads without replay, and profile changes invalidate both content and actions.
- The native HLS delivery advertises `containers: ["hls"]`, not its MP4/TS
  segment packaging; the server compares this with the plan's stream container.
- Map HLS player time through `StreamInfo.timelineOffset` and `playerStartTime`;
  report source position, retain full source duration, and replan restricted seeks.
  Aether's caption clock already uses source PTS, matching native sidecars' absolute
  source timestamps; do not add the video-window offset to that clock again.
- `SiloMediaRelay` streams media with fresh scoped authentication, Range/HEAD,
  redirect checks, opaque resource grants and HLS variable substitution. Player
  headers are explicitly empty, never inherited from Plex. Playlist input/output
  is bounded at 32 MiB and retained expansion state at 128 MiB per relay.
- Both catalog and `/watch` bitrates in this pinned server are **kbps**, despite
  the watch schema's bps description; normalize once at the DTO boundary.
- Native editable playlists, multipart-only sources and dynamic transport-header
  renewal plans are unsupported; do not fabricate fallback playback.


### Photos

A photo library (Plex section type `photo`, Jellyfin `photos`, or `homevideos` holding at least
one photo) is a library like any other: listed in the sidebar and in Settings > Sidebar Libraries, opened by
`PhotoLibraryViewController` (`Views/Photos/UIKit/`), a stack of `PhotoGridViewController` grids
with a focusless full-screen `PhotoViewerViewController` (paging and slideshow, both remote
transports through `DirectionalInputBinding`). tvOS only.

- **Photos are `PhotoItem`, never `MediaItem`.** That is what keeps them out of Home rows,
  Search, the detail page, Continue Watching and Top Shelf. Do not map one into a `MediaItem`.
- **One seam: `PhotoProvider.photoPage(in:folder:page:)`**, adopted by extension on the Plex and
  Jellyfin providers. Every server assumption lives in `PlexPhotoProvider.swift` and
  `JellyfinPhotoProvider.swift`.
- **`visibleSidebarLibraries` lists photo libraries; `visibleMediaLibraries` does not.** The
  second feeds Home rows, hub fetches and prefetch, so widening it puts photo sections on Home.
- **Never request the original file.** Thumbnails ask the photo transcoder for a 520 px cover,
  the viewer for a fit inside 3840x2160 with no `minSize` (`minSize=1` scales to cover, so a
  portrait photo comes back larger than the screen). The transcoder applies EXIF rotation.
- **Both servers are measured (PMS 1.43.4, Jellyfin 12.1).** What Plex does:
  - An album, a photo and a clip all sit under `Metadata`. An album is `type="photo"` with a key
    ending in `/children` and carries no item count; a clip is `type="clip"`.
  - Every level is two `/library/sections/<id>/all` requests: `type=14` for its albums and
    `type=13,12` for its photos and clips, both with `parent=<album>` inside a folder. Do not
    page `/library/metadata/<album>/children`: sorted by date it puts sub-albums last.
  - At the root `type=13,12` lists only the photos loose in the root folder.
    `clusterZoomLevel=1` makes it every photo and clip in the section, sorted and paged.
  - `originallyAvailableAt` is a camera-local day: parse it in the device's zone, or the caption
    is a day early west of UTC. `addedAt` is the file's date, not the scan time.
  - HEIC files were not indexed on the test server (0 of 4): they are absent from every listing.
  - A clip's Part is the video file (the transcoder answers 500 for it): its still is the thumb.
- **What Jellyfin does:**
  - **A `homevideos` view is a photo library only when it holds a photo.** `JellyfinProvider.libraries()`
    asks each one for a count (`holdsPhotos`: `Items?parentId=<view>&recursive=true&includeItemTypes=Photo&limit=0`,
    48 bytes). None leaves it `.mixed`: the video page and its Home row, as before the photo
    feature. A failed probe fails `libraries()`, so the store keeps the previous list. A `photos` view is always a photo library, with no probe. A 12.1
    server can only create `homevideos`. The mapper stays pure (`homeVideosHoldPhotos:`).
  - Every level is two `Items` requests with `parentId`: `includeItemTypes=PhotoAlbum,Folder`
    sorted by `SortName`, first page only, and `includeItemTypes=Photo,Video` sorted
    `DateCreated,SortName` descending and paged against `TotalRecordCount`. The media request
    adds `recursive=true` at the root, which lists every photo and clip in the library.
  - **The folders request must say `recursive=false`.** With `includeItemTypes` and a library id
    the server recurses by itself: the root gains every nested album and the library's own
    physical `Folder`. Inside an album it does not.
  - A sub-folder is a `PhotoAlbum`. `RecursiveItemCount` counts its photos and clips at any
    depth. It has no image (404), so the cell keeps the folder glyph.
  - A photo's `PremiereDate` is the camera's wall clock stamped `Z`: read its first ten
    characters as a day in the device's zone. A clip's `PremiereDate`, and `DateCreated` (all a
    photo without EXIF has), are real instants. `DateCreated` arrives only with `fields=DateCreated`.
  - Images come from `Items/<id>/Images/Primary` with the item's tag and no token:
    `fillWidth=fillHeight=520` is a cover, `maxWidth=3840&maxHeight=2160` a fit. Neither
    upscales, both apply EXIF rotation. No size parameters means a full-resolution re-encode.
  - Server limits: HEIC is not indexed (0 of 4), `isFolder` is not an `/Items` parameter, and
    the legacy `X-Emby-Token` header answers 401 (the client sends `Authorization: MediaBrowser`).

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
iOS has its own, `IOSChangelog.entries` in `RivuletiOS/Settings/IOSWhatsNew.swift`,
keyed the same way from the `ios-vX.Y.Z-<build>` tag (sheet at launch, Account → Changelog).
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

Settings is **UIKit** on tvOS (the iOS app's settings are a SwiftUI Form in the Account sheet, `RivuletiOS/Settings/`). A page is a list of `SettingsRowItem` values built in
`Views/Settings/UIKit/SettingsPageModels.swift`; `SettingsPageViewController`
renders each one through `SettingsCell`. Add a row by adding a case to the
relevant page's builder, picking a `SettingsRowItem.Kind`:
- `.navigation` / `.navigationValue` - pushes another page (chevron)
- `.navigationAction` - runs `prepare` (stash the tapped item), then pushes a per-item page
- `.toggle` - On/Off toggle
- `.cycle` - cycles through options in place
- `.action` - runs a handler (supports `destructive:`)
- `.info` - read-only value
- `.option` / `.selectable` - checkmark rows on a picker page
- `.textEntry` - presents `TextEntryViewController`

Every row title renders at one size and weight; there is no per-row-kind
typography. The SwiftUI settings rows are gone (`SettingsComponents.swift` and
`UserProfileSettingsView.swift` are deleted) — do not reintroduce them.

**A form that collects several fields** (add-source, Jellyfin sign-in) builds its
rows from `EntryStep`s (`AddLiveTVSourceContent.swift`): one list of its fields.
Nothing opens on arrival; landing on a form and being made to type first read as
forced. Selecting any text row opens the system keyboard at once and Menu goes
straight back, as tvOS Settings does (measured: About > Name has no page between
the row and the keyboard). The keyboard's only header is the field's placeholder,
so the placeholder names the field and examples go in the row's description
panel. Only a field with suggestions (My Own Server's address) shows a page.

**A row's `key:` is not wired to anything by adding the row.** Nothing reads it
for you and nothing warns you, so a toggle can look and persist perfectly while
having no effect — the state issue #260 shipped in for 16 builds, after the UIKit
migration orphaned two keys whose only reader was the deleted SwiftUI library
view. When you add or touch a row, grep its key across the repo: a single hit, in
`SettingsPageModels.swift`, means dead. The Music page was withdrawn for exactly
this (`SettingsPageModels.music` returns no rows): `musicLoudnessNormalization`,
`musicCrossfadeDuration` and `musicShowQualityBadges` had no reader. Restore a row
only with its reader. Also check the reader re-renders on
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

UIKit surfaces load remote images through `ImageCacheManager` (Music: `MusicChrome.loadArtwork`).
The remaining SwiftUI views use `CachedAsyncImage`:
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
  -only-testing:RivuletTests/SiloHierarchyTests/test_allEpisodesFlattensEverySeasonAndPreservesOpaqueParents
```

Most tests live in `RivuletTests/Unit/` (mirrors `Rivulet/` roughly by feature — Parsers, Playback, Player, Preferences, Services, Siri, etc.), with shared fixtures/mocks in `RivuletTests/Fixtures/`, `RivuletTests/Helpers/`, `RivuletTests/Mocks/`. A few sit at the `RivuletTests/` root (`PlexDeviceDecodingTests.swift`).

**Building requires full Xcode** (not just Command Line Tools) since it's tvOS. There is still no CI test run — run tests locally. CI is split across two systems: `codemagic.yaml` archives and publishes to TestFlight on tag push (`v*` → tvOS, `ios-v*` → iOS), and `.github/workflows/` holds five workflows — the SwiftLint gate, two Claude review/mention bots, and two build checks that exist to guard the platform boundary: `build-ios.yml` compiles the `Rivulet iOS` scheme on PRs/pushes touching `RivuletCore/**`, `RivuletiOS/**`, or the project file (otherwise nothing compiles iOS between release tags), and `build-tvos-core.yml` compiles the tvOS scheme when shared code changes from the iOS side. Both are build-only; signing and archives stay on Codemagic.

**One Xcode everywhere: `codemagic.yaml`'s `xcode:` pin.** Both build checks read it, and it must equal the Xcode you build with locally (27.1 today). When you upgrade local Xcode, bump the pin in the same commit (and the checks' `runs-on` image on a major). The type checker is the reason: a newer compiler accepts expressions an older one gives up on ("unable to type-check this expression in reasonable time"), so a mismatch passes every local build and breaks CI after the push. It happened twice before the pin (`e602163`, the favorites sort in `LiveTVDataStore`).

**No `.metal` files.** Compiling one needs Apple's separate Metal Toolchain download, which the GitHub runners (and likely Codemagic) lack: the tvOS check failed on it once. Ship a shader as source and compile it at runtime with `makeLibrary(source:)`, as `WelcomeGlowShader` does.

**The Simulator does not fully mimic Apple TV**, especially for focus-engine behavior. Treat Simulator-only verification of tvOS focus/remote-input changes as provisional; say so rather than declaring it fixed.

**`Docs/` is gitignored** (untracked on purpose, `c89b52d`), though some files under it are force-added and do ship: the `superpowers/` plans, specs and handoff, `handoff/`, `release/screenshots/` (App Store art), and `AETHER_ENGINE_STARTUP_NOTES.md`. What is *not* in the repo is `Docs/RIVULET_PLAYER.md` and `Docs/DESIGN_GUIDE.md`, both referenced throughout this file; they live only on the maintainer's machine. The `aether-update` and `rivulet-tvos-uikit` skills referenced above are also absent — `.claude/` is gitignored with nothing force-added. If a referenced doc or skill is missing in your environment, say so and proceed carefully rather than guessing its contents.

## Key Files

| Purpose | File |
|---------|------|
| Player container (SwiftUI) | `Views/Player/UniversalPlayerView.swift` |
| Player view model | `Views/Player/UniversalPlayerViewModel.swift` |
| Player container (UIKit chrome) | `Views/Player/PlayerContainerViewController.swift` |
| Player rail UI (UIKit) | `Views/Player/UIKit/PlayerRailView.swift` |
| Rail panel (UIKit) | `Views/Player/UIKit/PlayerRailPanelView.swift` |
| Info pane content (UIKit) | `Views/Player/UIKit/PlayerInfoPaneViews.swift` |
| Player (AetherEngine adapter) | `Services/Plex/Playback/AetherPlayer.swift` |
| Live TV multiview (tiles bind the engine surface) | `Views/LiveTV/UIKit/LiveMultiviewViewController.swift` |
| Routing decisions | `Services/Plex/Playback/Pipeline/ContentRouter.swift` |
| Aether render surface | `Views/Player/Aether/AetherVideoSurfaceView.swift` |
| Music library (sidebar + browse pane) | `Views/Music/UIKit/MusicLibraryViewController.swift` |
| Music Now Playing | `Views/Music/UIKit/MusicNowPlayingViewController.swift` |
| Music shared primitives | `Views/Music/UIKit/MusicChrome.swift` |
| Music menus | `Views/Music/UIKit/MusicMenus.swift` |
| Caption renderer | `Views/Player/UIKit/CaptionOverlayView.swift` |
| libass layer (ASS/SSA) | `Views/Player/UIKit/ASSOverlayView.swift` |
| Content filter sources | `Services/Plex/Playback/ContentFilter/ContentFilterSources.swift` |
| Image subtitle reader | `Services/Plex/Playback/ContentFilter/SubtitleImageReader.swift` |
| `hls` route trust relay | `Services/Plex/Playback/HLSTrustRelay.swift` |
| Navigation shell | `Views/TVNavigation/UIKit/RootShellViewController.swift` |
| Sidebar | `Views/TVNavigation/UIKit/ShellSidebarViewController.swift` |
| Sidebar rows (pure) | `Views/TVNavigation/UIKit/ShellSidebarModel.swift` |
| Launch profile picker | `Views/Components/ProfilePickerOverlay.swift` |
| Sidebar profile panel | `Views/Components/ProfileSwitcherPopup.swift` |
| `rivulet://` links | `Models/Shared/RivuletLink.swift` |
| Deep link handling | `Services/DeepLinkHandler.swift` |
| Continue Watching card | `Views/Media/UIKit/Cells/ContinueWatchingCardCompositor.swift` |
| Artwork analysis and scoring | `Views/Media/UIKit/Cells/ContinueWatchingCardPlacement.swift` |
| Home hero backdrop, scrim and motion | `Views/Media/PlexHome/UIKit/HeroBackdropView.swift` |
| Top Shelf logo placement | `Services/Cache/TopShelfImageCompositor.swift` |
| Focus memory | `Services/Focus/FocusMemory.swift` |
| Watch progress rule | `RivuletCore/Models/Media/WatchProgressPolicy.swift` |
| Plex star rating / favorite | `RivuletCore/Models/Plex/PlexUserRating.swift` |
| Plex API | `RivuletCore/Plex/PlexNetworkManager.swift` |
| Backend seam (Plex, Jellyfin) | `Services/MediaProvider/MediaProvider.swift` |
| Jellyfin provider | `Services/MediaProvider/Jellyfin/JellyfinProvider.swift` |
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
- DV is engine-owned; the RPU stays in the samples and Apple's decoder applies it. P5 is a `dvh1` sample entry with `dvcC` and `CODECS="dvh1.05.LL"`. P8.1 / P8.4 are `hvc1` + `dvvC` with `SUPPLEMENTAL-CODECS="dvh1.08.LL/db1p"` (`/db4h` for 8.4), and the HDMI criteria request `dvh1`. The supplemental only rides the master playlist, which is served once the panel is in HDR, so real DV needs a DV TV plus Match Dynamic Range (or HDR/DV output locked). P7 FEL on a DV panel takes the engine's dual-layer route (#345): `AetherPlayer` sets `preferDualLayerDolbyVision` from `AetherEngine.displayCapabilities.supportsDolbyVision`, because the engine does not check the panel itself. That route is the software host: height channels still render there (Height Speakers), but it has no AirPlay picture, and the engine refuses it over its real-time budget (UHD 30 fps plus a 1080p EL). P7 MEL, and FEL over budget, is converted live to single-layer 8.1 (libdovi, EL dropped) on a DV panel. Without DV on the TV, P7 plays the HDR10 base. P8.2 plays its SDR base. Without DV on the TV, 8.x plays its base layer. Rivulet sets neither `dolbyVisionHandling` nor `forceDolbyVisionOnNonDVDisplay`, so the engine defaults apply. Both FEL and P5 stills exist only because of package traits (see Quick Reference), so a bump that drops them silently turns FEL off. Routing lives in the engine's `CodecRoutePolicy.swift`.

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

## Plex server API gotchas

**Hub items are not full metadata.** `/hubs/continueWatching` sends the `Guid`
array only with `includeGuids=1` (which `continueWatchingURL` sends), and only three `Role` entries. Anything keyed on external
ids or the full cast reads `getFullMetadata` first, as Insights does
(`insightsFullMetadata`).

**`X-Plex-Container-Size` is ignored unless `X-Plex-Container-Start` is sent
with it.** Measured on PMS 1.43.4: `/library/recentlyAdded?X-Plex-Container-Size=1`
returned all 50 items (75KB); adding `X-Plex-Container-Start=0` returned one
(1.7KB). So a `limit:` argument that only sets the size parameter silently does
nothing, and the caller pays for the full page. `getRecentlyAdded` has shipped
that way, which is why its `start` is an optional parameter rather than always 0:
`PlexProvider.recentlyAdded` was tuned against the over-fetch, so making the
limit work would shrink its results.

**Neither `updatedAt` nor `scannedAt` on `/library/sections` detects new content.**
On the same server a section's `updatedAt` was six months stale with items added
that morning (it tracks section settings, not contents), and `scannedAt` moved on
every library at once from the scheduled scan whether or not anything was added.
The working signal is the newest item on `/library/recentlyAdded` capped with
`X-Plex-Container-Start=0&X-Plex-Container-Size=1`, keyed on ratingKey + addedAt +
`updatedAt` together, because an episode added to the season that is already
newest keeps that season's ratingKey and moves only its timestamps. `PlexDataStore`'s 30s poll
uses exactly this to decide when to refetch Home's Recently Added rows (#315).

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
