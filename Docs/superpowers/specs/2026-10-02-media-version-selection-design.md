# Media version selection

Status: design approved 2026-10-02. Implementation has not started. Tracks issue #302.

## Scope

A movie or episode can carry more than one file: Plex returns several entries in `Media`, Jellyfin several `MediaSources`. This spec covers the case where those files are the same content at different quality (a 4K file and a 1080p file of one film). Today every surface plays the first entry the server returns.

Out of scope:

- Plex Editions (`editionTitle`). Each edition is its own library item with its own rating key and watch state, so it already shows as a separate tile.
- Libraries where Plex merged different content into one item (an extended cut grouped with the broadcast cut, Part 1 grouped with Part 2). These still work: they appear in the picker like any other versions and Play takes the higher ranked one.
- Stacked multi-part files. Playback keeps using `Part[0]` as it does today.
- Remembering a choice, and switching versions from inside the player. See Later.

## Behavior

1. Play plays the best version, ranked as below. This applies to every entry point: detail Play, tile Play/Pause, Continue Watching, hero Play, season Play, deep links, Top Shelf and Siri.
2. Movie and episode detail pages show a Versions button when the item has two or more versions. Select opens a list of the versions, best first. Picking one plays it.
3. The tile long-press menu shows "Play Version…" on movie and episode tiles that have two or more versions. It opens the same list.
4. A pick applies to that play only. Nothing is stored. The next Play ranks again.
5. Up Next and auto-advance keep the resolution of the version that was playing. If the user picked the 1080p file, the next episode plays its 1080p file when it has one.
6. A picked version resumes from the item's resume point, the same way Play does on that surface. Plex and Jellyfin both store the resume point per item, and the versions hold the same content, so the offset is valid on any of them.

## Ranking

One shared ranking, in a new `Rivulet/Models/Media/VersionRanking.swift`, used by the Plex player path and by every `MediaProvider`.

Order, highest first:

1. Resolution tier: 4K, 1080, 720, 576, 480/SD. Taken from the provider's resolution label (`videoResolution`) when present, else from the video track height with the thresholds `MediaSource.qualityBadges()` already uses (1600 and up is 4K, 800 to 1599 is 1080, and so on). The tier logic moves out of the private `resolutionLabel` so badges and ranking share it. Jellyfin sends no resolution label, so it always ranks by height.
2. Dynamic range: Dolby Vision, HDR10+, HDR10, HLG, SDR.
3. Bitrate. A missing bitrate counts as zero.

Ties keep the server's order (stable sort).

The ranking compares a small key of (tier, range, bitrate). The key is built from either a `MediaSource` or a `PlexMedia`; for `PlexMedia` the range comes from `PlexMediaMapper.videoTrack` on `Part[0]`'s streams. The ranked list is de-duplicated by version id, because `PlexMediaMapper.detail` flattens `Media` × `Part` and a stacked file produces several `MediaSource`s with the same id.

A version choice is one of:

- `.best`: the top ranked version.
- `.source(id)`: the version with that id (Plex `Media.id`, Jellyfin `MediaSource.Id`), falling back to `.best` when the id is gone.
- `.matchingTier(tier)`: the best version in that resolution tier, falling back to `.best` when no version has that tier. Used by Up Next.

## Version labels

Plex leaves `Media.title` empty on every multi-version item measured, so labels are built from the file's properties, joined with " · ":

resolution, dynamic range badge (DV / HDR / HLG, omitted for SDR), video codec, audio, file size

Resolution, range and audio come from `qualityBadges()`. The codec name comes from a short map (hevc → HEVC, h264 → H.264, av1 → AV1, vp9 → VP9, mpeg2video → MPEG-2, mpeg4 → MPEG-4, vc1 → VC-1, anything else uppercased). File size uses `PlayerInfoSheetStyle.fileSize`. When two rows produce the same label, both get the file name (last path component, extension dropped) appended.

Illustrative, for the two Sweeney Todd files measured: `1080p · HEVC · AAC 5.1 · 5.7 GB` and `480p · MPEG-4 · MP3 2.0 · 730 MB`. The exact audio text depends on `AudioTrack.qualityLabel`.

## UI

### Detail pages

- `MediaDetailChromeView.rebuildActionButtons` (carousel and standalone detail) and `MediaItemDetailPageViewController.makeActionRow` (episode page) add a circle button, SF Symbol `square.stack`, after Info.
- The version count is known only once `MediaItemDetail` loads, so the button is added in `applyDetail` on both surfaces. It never appears on shows or seasons.
- Select presents `TileMenuPopupViewController` with one section of rows, best first, a `TileMenuHeader` titled "Play Version", and the button's frame as `sourceFrame`. Each row uses `play.fill`. The first row takes focus, which the popup already does.
- Picking a row calls a new `onPlayVersion: (String) -> Void` on the chrome view, wired through `PreviewCardView` to the carousel. The episode page's `onPlay: (MediaItem) -> Void` becomes `(MediaItem, String?) -> Void`; its two creators (`PlexHomeViewController` and the carousel's below-fold episode path) pass the id on.
- Any view controller that presents the picker and overrides `pressesBegan` must already guard `presentedViewController == nil` (see the presses rule in CLAUDE.md). Check the carousel and the episode page during testing.

### Tile menu

- `MediaItem` gains `versionCount: Int?`, nil meaning unknown. It is optional so cached `MediaItem` JSON without the key still decodes.
- Plex: `PlexMediaMapper` sets it to the number of distinct `Media` ids. Library `/all` and the search hubs return the full `Media` array (measured), so no extra request is needed.
- Jellyfin: Jellyfin's `BaseItemDto` has a `MediaSourceCount` field that list requests can ask for through `Fields`. It has not been checked on 12.1. If the field is absent, Jellyfin tiles leave `versionCount` nil and skip the menu row; the detail page still works because it counts `mediaSources`.
- `PlexHomeViewController.tileMenuSections` and `providerTileMenuSections` add "Play Version…" for movies and episodes when `versionCount >= 2`.
- Select dismisses the tile menu, fetches `fullDetail`, and presents the same picker from the same tile frame. A pick calls `playItem(_:fromBeginning:sourceID:)`.

## Playback

### Plex path

The Plex player reads the first `Media` in more than 40 places: `UniversalPlayerViewModel`, `ContentRouter.buildDirectPlayURL`, `CardInfoView`, `PlaybackDiagnostics`, `HLSManifestEnricher` and the `PlexMetadata` helpers (`hasHDR`, `hdrFormatDisplay`, `primaryVideoStream`, and others). The view model moves the chosen version to the front of `metadata.Media`, so all of those reads stay correct without edits. Replacing each read with a selected-media accessor was rejected because the `PlexMetadata` helpers are shared with surfaces outside the player.

- `UniversalPlayerViewModel.init(metadata:…)` gains `preferredMediaID: String? = nil`. Nil means `.best`.
- New view model state: `playingMediaID` and `playingMediaServerIndex` (default 0).
- One view model function applies a choice to a server-ordered `Media` array: it ranks, picks, records the id and the version's index in server order, and moves the version to index 0. It is called everywhere the view model assigns `Media` from the server:
  - init, when `Media` is present;
  - `fetchFullMetadataIfNeeded` (the fill at `metadata.Media = fullMetadata.Media`);
  - `fetchMarkersIfNeeded` (the overwrite at `metadata.Media = media`), with `.source(playingMediaID)` so a refresh keeps the version that is playing;
  - the Up Next swap (`metadata = preloadedNextMetadata ?? next`), with `.matchingTier` of the outgoing version.
- The selection math is a pure static function so it can be unit tested without a view model.
- Next-episode preload builds its direct-play URL from `Media.first.Part.first.key`. It applies the same `.matchingTier` choice first, so the preloaded URL and the swapped metadata name the same file.
- HLS fallback: `PlexNetworkManager.buildHLSDirectPlayURL` hardcodes `mediaIndex=0`. It gains `mediaIndex: Int = 0`, and `buildRivuletHLSURL` passes `playingMediaServerIndex`. `PlexNetworkManager` is in RivuletCore; a defaulted parameter needs no platform branch and leaves iOS callers unchanged. The other `mediaIndex=0` builders in that file are called only from tests and stay as they are.
- Callers that build the view model gain an optional id: `PlexHomeViewController.presentPlayer(for:fromBeginning:)` and `playItem`, and the carousel's `playMediaItem` → `presentPlayer(ratingKey:resumeOffset:)` → `present(playItem:…)`. The deep link builder in `TVSidebarView` keeps the default.

### Provider path (Jellyfin and later sources)

The protocol already passes `sourceID` through `resolveStream`, `transcodeStream`, `progressReporter` and `playbackExtras`. Every caller passes nil today.

- Contract change on `MediaProvider.resolveStream`: a nil `sourceID` returns the best version by `VersionRanking`. `JellyfinProvider.playbackInfo` replaces `?? sources.first` with the ranking. `PlexProvider.resolveStream` gets the same change so the contract holds for every provider, although Plex video does not go through it.
- `ProviderPlayback.prepare(item:provider:)` gains `version: VersionChoice = .best`.
  - `.best` keeps today's concurrent detail and stream requests, passing nil.
  - `.source(id)` passes the id.
  - `.matchingTier` waits for `fullDetail`, picks from `detail.mediaSources`, then resolves that id. Only Up Next uses it, and Up Next prepares during the countdown.
- `ProviderPlayer.play(_:fromBeginning:from:onDismiss:)` gains `sourceID: String? = nil`.
- `UniversalPlayerViewModel.preparedNextProviderPlayback` passes `.matchingTier` of the playing `stream.source`.

## Measured facts

From the maintainer's Plex Media Server 1.43.4 on 2026-10-02:

- 3 movies and 75 episodes have two `Media` entries. Sweeney Todd (1080p HEVC 5.7 GB and SD MPEG-4) and Mission: Impossible Dead Reckoning (two 1080p HEVC files, 7.1 at 3.6 GB and 5.1 at 3.1 GB) are true quality duplicates.
- `Media.title` is empty on all of them.
- The universal transcoder picks the version by `mediaIndex`, in the server's order. On Sweeney Todd, `mediaIndex=0` returned the 1080p media (id 260721) and `mediaIndex=1` the SD media (id 22249).
- Server order is not quality order. Anne of Green Gables lists its 2.3 Mbps file before its 4.2 Mbps file at the same resolution.
- Library `/all` and `/hubs/search` include the full `Media` array per item.
- No movie in the 1,025-item movie library has `editionTitle`.

## Files touched

| Area | File |
|---|---|
| Ranking, choice, labels | `Rivulet/Models/Media/VersionRanking.swift` (new), `MediaSource.swift` (tier extraction) |
| Model | `MediaItem.swift` (`versionCount`), `PlexMediaMapper.swift`, Jellyfin mapper and list `Fields` |
| Plex player | `UniversalPlayerViewModel.swift`, `RivuletCore/Plex/PlexNetworkManager.swift` |
| Provider player | `MediaProvider.swift` (doc contract), `JellyfinProvider.swift`, `PlexProvider.swift`, `ProviderPlayback+Prepare.swift` |
| Detail UI | `MediaDetailChromeView.swift`, `PreviewCardView.swift`, `PreviewCarouselViewController.swift`, `MediaItemDetailPageViewController.swift` |
| Tile menu | `PlexHomeViewController.swift` |
| Changelog | `WhatsNewView.swift` |

## Testing

Unit tests (`RivuletTests/Unit/`):

- Ranking: tier beats range, range beats bitrate, nil bitrate, cropped 1920×800 ranks as 1080, Jellyfin-style sources with no resolution label, stable ties, duplicate ids from a stacked file collapse to one.
- Choice: `.source` with a missing id falls back to best; `.matchingTier` with no match falls back to best.
- Plex selection function: chosen version moves to index 0, the recorded server index is its original position, and re-applying `.source` to a fresh server-ordered array keeps the same version.
- Labels: composition, and file names appended on a collision.
- `PlexNetworkManagerURLTests`: `buildHLSDirectPlayURL` with `mediaIndex: 1` emits `mediaIndex=1`.

On device (the Simulator does not reproduce focus behavior faithfully):

1. Sweeney Todd: Play plays the 1080p file (check the player info FILE section).
2. Sweeney Todd: Versions → SD plays the SD file. Menu out, Play again plays 1080p.
3. Force the HLS fallback with the SD version picked; the server transcodes the SD file.
4. An Office episode: pick the 720p version, let Up Next advance; the next episode plays its 720p file.
5. Long-press a multi-version movie tile: "Play Version…" appears and works. A single-version tile has no such row.
6. Menu from the picker returns focus to the Versions button, and arrow presses inside the picker do not move the page behind it.
7. Jellyfin: the test server has no multi-version items. Add a second file to one movie's folder, named after the folder with a suffix such as ` - 1080p`, which Jellyfin groups as a version and repeat steps 1, 2 and 5.

Estimate: about 1.5 days, most of it in the Plex player path and device testing.

## Later

- Bitrate selection or automatic transcoding for weak connections comes before in-player version switching. A quality setting may cover most of what #302's reporter wants from a version pick.
- In-player version switching from the info panel.
- A remembered choice per item or per show, if remote users end up picking the same lower version every time.
