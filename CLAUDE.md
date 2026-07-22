# Rivulet - Claude Context

Rivulet is a tvOS media client for Plex and IPTV. The primary surfaces (Home, Library, Search, Discover, Media Detail, the preview carousel, Person detail, and the player chrome) are **UIKit**, as is Settings; SwiftUI remains for thin navigation shells, Music, and Live TV slots.

**UIKit is the default. Do not add SwiftUI to a primary surface.** When you find SwiftUI in one, assume it is a leftover and check reachability before building on it.

**Detail is UIKit, with no SwiftUI fallback.** Every route lands on the same two surfaces: `MediaItemDetailPageViewController` for episodes, `PreviewCarouselViewController(standaloneDetail:)` for everything else. That holds for in-app taps, tile-menu "More Info" / "Go to …", hero Info, and `rivulet://detail` deep links from Top Shelf / Siri (`TVSidebarView.presentDetailForDeepLink`). The old SwiftUI `MediaDetailView` + `MediaItemContextMenu` + `SummarySheet` are **deleted** (`c0b0bf7`); if you find a comment referencing them, it is stale.

The video player is **AetherPlayer** — an adapter around AetherEngine (FFmpeg demux + HLS-fMP4 remux + AVPlayer, with HDR10+ / HLG / EAC3+JOC Atmos, plus a software sample-buffer backend for AV1 / VP9 / MPEG-2 / VC-1 / MPEG-4p2). It is the only player: VOD **and** Live TV. Video MUST render through the engine surface (`AetherVideoSurfaceView` → `engine.bind(view:)`), never an AVPlayerLayer on `currentAVPlayer`. The only other path is `hls`: AVPlayer on a Plex server transcode, used when no direct-play URL exists or as the fallback after an Aether startup failure. `ContentRouter.plan(...)` picks aether vs hls per item. (RPlayer and the localRemux/avPlayerDirect routes have been removed — see git history.)

## Quick Reference

- **Platform**: tvOS 26+ (Apple TV)
- **Language**: Swift 6
- **UI Framework**: UIKit for the primary surfaces (see above); SwiftUI for the rest
- **Video Player**: AetherPlayer for VOD and Live TV; AVPlayer only for the `hls` route (server transcode, primary-when-no-direct-URL or Aether fallback). See `Docs/RIVULET_PLAYER.md`.
- **AetherEngine**: consumed as an **upstream** SwiftPM dependency (`superuser404notfound/AetherEngine`), pinned `exactVersion` (5.20.2). **There is no fork** — engine fixes need an upstream release or a host-side workaround; do not propose editing engine sources. Bumping it has a procedure: use the `aether-update` skill. Every bump gets a changelog line. FFmpeg + libdovi arrive **only transitively through Aether**; there is no app-level FFmpeg layer and no direct FFmpegBuild dependency. Since FFmpegBuild 2.0.0 the FFmpeg libs ship as **embedded dynamic frameworks** in `Rivulet.app/Frameworks/` — their `MinimumOSVersion` (26.0) must stay >= `TVOS_DEPLOYMENT_TARGET` (26.0), so do not raise the deployment target.
- **Design Guide**: See `Docs/DESIGN_GUIDE.md` for UI/UX patterns
- **Repo is public**: keep commit messages short and plain; no internal detail.

## Project Structure

```
Rivulet/
├── Models/
│   ├── Plex/           # Plex API models (PlexMetadata, PlexStream, etc.)
│   └── SwiftData/      # Persistent models (Channel, EPGProgram, PlexServer)
├── Services/
│   ├── Plex/
│   │   ├── (PlexNetworkManager, PlexAuthManager, PlexDataStore, …)
│   │   └── Playback/   # AetherPlayer + routing/remux (see Docs/RIVULET_PLAYER.md)
│   │       ├── Pipeline/     # ContentRouter (routing decisions)
│   │       └── Subtitles/    # SubtitleManager, SubtitleParser, SubtitleOverlayView, SubtitleClockSyncController
│   ├── LiveTV/         # PlexLiveTVProvider, IPTVProvider, LiveTVDataStore
│   ├── IPTV/           # M3UParser, XMLTVParser, DispatcharrService
│   ├── Insights/       # InsightsTriviaClient, InsightsShowIDResolver (in-player cast/trivia panel)
│   ├── Cache/          # CacheManager, ImageCacheManager
│   └── Focus/          # FocusMemory (tvOS section focus restoration)
├── Views/
│   ├── Player/         # UniversalPlayerView, UniversalPlayerViewModel, PlayerContainerViewController,
│   │                   #   AVPlayerLayerView, TrackSelectionSheet, PlayerPresenter
│   │   ├── Aether/     # AetherVideoSurfaceView, AetherSubtitleOverlayView, AetherSubtitleCue
│   │   ├── Subtitles/  # SubtitleModel (bridge); the pipeline lives in Services/…/Subtitles
│   │   ├── UIKit/      # PlayerRailView, PlayerRailPanelView, PlayerProgressBarView,
│   │   │               #   PlayerUpNextPanelView, UpNextRowState, pills (canonical player chrome),
│   │   │               #   Insights* panels (in-player cast/trivia; backed by Services/Insights + TMDB)
│   │   └── PostVideo/  # Post-playback summary overlays
│   ├── Media/          # PreviewContext, HeroBackdropSupport, SharedMediaComponents,
│   │                   #   CastMemberCard (CastCrewRow), FocusScrollMotion
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
- **`ContentRouter`**: routing decisions → `PlaybackPlan`.
- **`SubtitleManager` + `SubtitleParser` + `SubtitleOverlayView` + `SubtitleClockSyncController`**: subtitle rendering for the `hls` route. On the aether route, subtitles come from the engine's cue publishers rendered by `AetherSubtitleOverlayView` (fed via `SubtitleModel`).

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
"What's New" shows only the current build's entry. Write bullets as simple,
user-facing sentences (what users get, not internal details); no em dashes.
Every AetherEngine bump gets a changelog line.

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

One-time setup: `Rivulet/Config/Secrets.swift` is gitignored and required for the app target to compile. Copy the template and fill in real values (or leave placeholders for a build that doesn't need Sentry/TMDB/etc. to actually work):

```bash
cp Rivulet/Config/Secrets.swift.template Rivulet/Config/Secrets.swift
```

`Secrets.swift` is the only gitignored file in `Rivulet/Config/` — the rest (`TMDBConfig`, `InsightsConfig`, `InputConfig`) are tracked and present in a fresh clone. Copying the template is the whole step: all three targets use Xcode buildable-folder references (`PBXFileSystemSynchronizedRootGroup`), so files are picked up from disk and never need adding to the project. `RivuletApp.swift` reads `Secrets.sentryDSN`, so the app target will not compile without it.

There is a single shared scheme, `Rivulet`. No SwiftFormat is configured.

SwiftLint is configured, but **every stock rule is off** (`only_rules: [custom_rules]`
in `.swiftlint.yml`). It is not a style checker here and has no opinion about force
casts, line length, or naming. It runs three project-specific rules: no SwiftUI on a
UIKit surface, no `UIHostingController` in a cell, and no UIKit context menus (dead on
tvOS 26). A PR gate runs them on Linux; there is no local hook.

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

**Building requires full Xcode** (not just Command Line Tools) since it's tvOS. There is no CI test run today — `codemagic.yaml` only builds/archives/publishes to TestFlight on tag push; the two GitHub workflows (`.github/workflows/`) are Claude Code review/mention bots, not test runners. Run tests locally.

**The Simulator does not fully mimic Apple TV**, especially for focus-engine behavior. Treat Simulator-only verification of tvOS focus/remote-input changes as provisional; say so rather than declaring it fixed.

**`Docs/` is gitignored** (untracked on purpose, `c89b52d`), though some files under it are force-added and do ship — the `superpowers/` plans and specs, and `AETHER_ENGINE_STARTUP_NOTES.md`. What is *not* in the repo is `Docs/RIVULET_PLAYER.md` and `Docs/DESIGN_GUIDE.md`, both referenced throughout this file; they live only on the maintainer's machine. The `aether-update` and `rivulet-tvos-uikit` skills referenced above are also absent — `.claude/` is gitignored with nothing force-added. If a referenced doc or skill is missing in your environment, say so and proceed carefully rather than guessing its contents.

### Developer setup & Make wrappers

The toolchain is pinned so local and CI stay in sync: `Brewfile` lists the dev
tools (swiftlint, swiftformat, pre-commit, xcbeautify, gh) and `.xcode-version`
pins Xcode. `make bootstrap` installs both, then wires the pre-commit hook.

`Makefile` targets are thin wrappers over the `xcodebuild` commands above, and
the CI/lint tracks call the same targets so behavior can't drift:

```bash
make bootstrap     # brew bundle + pre-commit install (one-time)
make lint          # swiftlint (config/baseline auto-discovered)
make format        # swiftformat in place
make format-check  # swiftformat --lint (no writes)
make test          # xcodebuild test on the tvOS sim via Rivulet.xctestplan
make build         # xcodebuild build for the tvOS sim
```

`make test` uses the `Rivulet.xctestplan` test plan; SCHEME/DESTINATION/TESTPLAN
are variables at the top of the Makefile.

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
| Aether subtitle overlay | `Views/Player/Aether/AetherSubtitleOverlayView.swift` |
| Subtitle pipeline | `Services/Plex/Playback/Subtitles/SubtitleManager.swift` |
| Focus memory | `Services/Focus/FocusMemory.swift` |
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
