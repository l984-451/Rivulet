# Rivulet iOS port

The iOS app is a separate target named `Rivulet iOS`. This preserves the
shipping tvOS target and its focus-driven UIKit surfaces while the phone and
tablet experience is migrated feature by feature.

## Direction

- Share platform-neutral models, networking, persistence, authentication, and
  playback policy through `RivuletCore/`, a buildable folder compiled into both
  app targets. Move a file there when a slice actually needs it.
- Keep platform navigation and interaction separate. tvOS remains focus-first;
  iOS is touch-first and uses a tab/navigation-stack shell.
- **Shared code carries no `#if os(...)`.** A shared file that needs a platform
  branch belongs in `Rivulet/` or `RivuletiOS/` instead. CLAUDE.md's Platform
  Boundary section is the full rule and lists what qualifies.
- Port in vertical slices so the iOS target stays buildable after every step.

There is exactly one Plex client. `PlexNetworkManager`, `PlexAuthManager` and
`Models/Plex/` live in `RivuletCore/` and both apps compile them;
`RivuletiOS/Plex/` holds only presentation glue — `IOSPlexSession` (the iOS
content store and view-facing facade, the counterpart of tvOS
`PlexDataStore`) and `IOSPlexAdapters` (display accessors on the shared
models). The POC's duplicate client (`IOSPlexAPI` / `IOSPlexModels`) is
deleted; do not reintroduce a second decoder for a Plex endpoint. Platform
identity (`PlexAPI.platform` / `deviceName`) and the auth manager's content
handoffs (`onAuthenticated` / `onSignedOut`) are host-injected at launch, not
platform-conditional.

## Initial slices

1. App target and touch-first navigation shell. **Done.**
2. Extract Plex identity, Keychain storage, and server discovery into shared
   core; make the Connect Plex flow functional on iOS. **Done.**
3. Share the home/library view models and build native iOS shelves and detail
   navigation. **Initial movie/TV slice done.**
4. Add generic M3U/XMLTV source entry and a touch-native EPG-only guide.
   **Done.**
5. Bring across playback routing and add touch-native player chrome.
   **Live M3U and Plex VOD playback via AetherEngine are done.**
6. Port search data, music, and remaining settings. **Plex video search,
   profile artwork and marker settings are done; music and advanced profile
   switching remain.**

## Plex iOS slice

- Plex PIN sign-in, Keychain-backed tokens, server discovery/selection and
  local/remote/relay connection probing.
- Home hubs, movie/TV libraries, poster grids, search and nested
  show/season/episode detail navigation.
- Direct-file Plex playback through AetherEngine with resume and Plex timeline
  progress reporting.
- Touch OSD based on the tvOS player: scrubber, centered play/pause, audio,
  subtitles and marker information. Double-tap either side of the video to
  seek by the user-configurable interval.
- Plex intro/recap/credits/commercial marker buttons and matching auto-skip
  preferences (`autoSkipIntro`, `autoSkipRecap`, `autoSkipCredits`,
  `autoSkipAds`).
- Optional IntroDB community marker fallback using the same confidence cutoff
  and synthetic marker IDs as tvOS. Only IMDb ID and episode coordinates are
  sent to IntroDB; Plex credentials are not shared.
- System caption appearance remains shared through `CaptionAppearance`, and
  AVFoundation media selection remains in use when Aether chooses its native
  backend.
- Apple TV-style dark hero surfaces are used on Home, library and detail pages;
  Home and library heroes use SwiftUI's native paged `TabView` carousel.
  Continue Watching crops 16:9 source art into consistent 4:3 cards with
  clear-logo overlays; poster rails use fixed 2:3 cards and one-line ellipsis
  titles.
- The bottom menu uses Apple's native five-item tab bar. The user can choose
  and order up to five destinations in Settings; Settings remains available
  from the account menu even when it is not assigned a tab.

## Build

Select the `Rivulet iOS` scheme in Xcode and choose an iPhone or iPad
destination. The original `Rivulet` scheme continues to build the tvOS app.
