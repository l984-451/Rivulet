# Rivulet for Mac: notes for feature agents

Native SwiftUI + AppKit app. Logic lives in `RivuletCore/` (shared with iOS and tvOS, no `#if os`), GUI in
`RivuletMac/`. Parity target: everything `RivuletiOS/` offers except Downloads (iOS only).
Each feature owns the files listed below; do not edit another feature's file, extend through the contract.

## Navigation contract (`Shell/MacNavigation.swift`)

- `MacRoute`: `.detail(MediaItem)`, `.hub(MediaHub)` (See All), `.playlist(MediaPlaylist)`, `.library(MediaLibrary)`.
  `MacRootView` maps each case to its view once. A new page type is a new case plus one line there.
- `MacSidebarItem`: `.home .search .liveTV .favorites .library(_) .playlists(providerID:)`.
- Environment closures, set by `MacRootView`:
  - `@Environment(\.macOpen)`: `macOpen(.detail(item))` pushes on the current row's stack.
  - `@Environment(\.macSelect)`: `macSelect(.search)` switches sidebar row.
  - `@Environment(\.macOpenAccount)`: presents the account sheet.
- Each sidebar row has its own `NavigationStack` and path; a server or profile switch (`browse.sessionGeneration`) resets all.

## Environment objects

`PlexSession` (`plex`), `BrowseStore` (`plex.browse`, every server's content, via `MediaProviderRegistry`),
`MacPlaybackController`. The Settings scene gets the same three. Sheets inherit them on macOS.

## Playing

`@EnvironmentObject MacPlaybackController`: `play(item, fromBeginning:, sourceID:, queue:)`, `close()`, `playbackError`.
Setting a request makes `macPlaybackHost` cover the window with `MacPlayerView(request:onClose:)`
(`Player/`). The player agent owns that view, `Player/MacPlaybackCommands.swift` (the Playback menu) and the
session behind it. Routing to copy: `IOSPlaybackController.startItem` in `RivuletiOS/Player/IOSPlaybackController+Provider.swift`
(Plex session vs `ProviderBackend`, local vs remote); shared backends are in `RivuletCore/Client/`
(`PlexSession+Playback`, `PlayerBackend`, `ProviderBackend`). Only `Rivulet*/AetherPlayer.swift` may import AetherEngine.

## Item actions

`@Environment(\.macActions)` (`MacActions`, `Shell/MacActions.swift`): play, playFromBeginning, playQueue, shuffleLibrary,
shuffleShow, addToPlaylist, open, setWatched, setWatchlisted, setFavorite, playExtra, refreshMetadata, delete, `preparingID`.
`.macContextMenu(item)` or `MacItemMenu(item:)` gives the right-click menu. No download actions.

## Components (`Shell/MacComponents.swift`, `Shell/MacArtworkCache.swift`)

`MacImage(url:)`, `MacItemArtwork(item:kind:width:aspectRatio:)`, `MacResolvedLogo`, `.macWatchState(item)`, `.macTileHover()`,
`.macPill()`, `MacPosterCard(item:width:showsCaption:)`, `MacContinueCard(item:width:)`, `MacTileButton(item:) { }`
(click opens detail, right-click menu), `MacShelfHeader`, `MacRail(title:hub:kind:items:badge:) { item, width in }`,
`MacShelfView(hub:)`, `MacPosterGrid(items:loadMore:)` / `(slots:slotAppeared:)`, `MacServerFailureBanner`, `MacErrorView`,
`MacAccountAvatar`, `MacAccountButton`, `MacFeaturePlaceholder`, `MacMetrics`. Images load through `MacArtworkCache`
(`cachedImage(for:)`, `image(for:)`); `ClientHost.prefetchImage` is wired to it.

## Files by feature, with the iOS source to port

| Area | Mac file | iOS source |
|---|---|---|
| Home | `Home/MacHomeView.swift`, `MacHubGridView.swift` | `Plex/Home/IOSPlexHomeView`, `IOSPlexHeroFeed`, `IOSPlexHomeHero`, `IOSPlexHubGridView`, `Plex/Components/IOSThemeVideoBackdrop`, `IOSPlexAmbientBackdrop` |
| Library | `Library/MacLibraryView.swift` | `Plex/Library/IOSPlexLibraryView` (Recommended + Browse, sort via `IOSLibrarySorts`) |
| Photos | `Photos/MacPhotoLibraryView.swift` (grid, folders, clips), `MacPhotoViewer.swift` (arrows, Space slideshow, Esc, pinch) | `RivuletiOS/Photos/`; listing in `RivuletCore/Photos/` |
| Playlists | `Library/MacPlaylistViews.swift` | `Plex/Library/IOSPlexPlaylistViews` |
| Favorites | `Library/MacFavoritesView.swift` | `Plex/Library/IOSFavoritesView` |
| Detail | `Detail/MacDetailView.swift` | `Plex/Detail/IOSPlexDetailView`, `IOSPlexDetailSections` |
| Search | `Search/MacSearchView.swift` | `Search/IOSPlexSearchView` |
| Player | `Player/MacPlayerView.swift`, `MacPlaybackCommands.swift` | `Player/` (`IOSPlaybackController`, `IOSPlayerChrome`, `IOSCaptionOverlay`, `IOSNowPlaying`), `Plex/IOSPlexPlayerView` |
| Live TV | `LiveTV/MacLiveTVView.swift` | `LiveTV/` (all seven files; shared logic in `RivuletCore/LiveTV/LiveClient.swift`) |
| Settings, Account | `Settings/MacSettingsView.swift`, `MacAccountView.swift`, `MacSignInViews.swift` | `Settings/IOSAccountView`, `IOSHomeSettings`, `IOSSettingsPages`, `IOSLiveTVSettingsView`, `IOSServerSignInView`, `Shell/IOSAccountViews` (`IOSPlexConnectionSheet`) |
| What's New | `Settings/MacWhatsNew.swift` | `Settings/IOSWhatsNew` (Mac entries keyed from the Mac tag) |
| Shell | `Shell/MacRootView.swift`, `MacProfilePicker.swift`, `MacCommands.swift` | `IOSRootView`, `Shell/IOSAccountViews` |

## Rules

- Strings: `String(localized:)` / SwiftUI literals; `RivuletMac/Localizable.xcstrings` (source `en`).
- New settings keys that should sync must be added to `RivuletCore/Sync/SyncCatalog`. Mac-only keys: `MacSettingsKeys`.
- Logic that is not view code goes to `RivuletCore/`, not here. No Downloads UI (`BrowseStore.canDownload` is true for Plex; ignore it).
- `rivulet://` links: `RivuletLink` is in `RivuletCore/Links/` (also compiled into Top Shelf); `MacRootView` resolves them with `RivuletLinkResolver`.
- Offline progress is dropped on the Mac (`NoOfflineHost`).
