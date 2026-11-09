# Photo library improvements

Date: 2026-11-09. Status: design.

## Why

A user who curates a large photo library on the same server as their films asked
for more than "press Play for a slideshow": shuffle, sorting, and the library
options the film and TV libraries have. Plex's own clients never did photos
well, so people run a second server app just to show photos on the TV. Rivulet
already reads photo libraries on all three servers (tvOS only), so most of what
a photo person wants is a client job on data the servers already hand over.

The maintainer does not use photos. The target is a hypothetical user with tens
of thousands of photos in nested albums, who wants to put photos on the TV for a
room of people and find a particular moment.

## Goals

1. **Photos on every app.** tvOS, iOS and Mac, on Plex, Jellyfin and Emby. This
   ends the "Photos are tvOS only" standing exception in `CLAUDE.md`.
2. **Slideshow and Shuffle from any grid**, without opening a photo first.
3. **Sort** (Date Taken, Date Added, Name; either direction) and a **Show** filter
   (All, Photos, Videos), remembered per library.
4. **Slideshow settings**: interval, transition, and whether clips play.
5. **Favorites** on all three servers, with a Favorites view.
6. **An info pane** in the viewer: date and time, camera, lens, exposure, size,
   file name, and the place on a small map.
7. **A map** of a library's photos (Plex and Jellyfin).
8. **Memories**: "On This Day" and "Photos from <year>", shown as a row of the
   large two-across cards at the top of a library's root.

## Non-goals

- Star ratings. Only Plex shows them anywhere; Jellyfin stores a rating no client
  shows and sets "liked" as a side effect (measured). Favorites cover the need.
- Plex Places and auto-tags. Both were empty on a Plex Pass server with GPS-tagged
  photos (measured), so nothing can rely on them.
- Editing, deleting, uploading, sharing, faces, people.
- A photo row on Home. Memories live in the library. A Home row is a later,
  separate decision.
- HEIC on Plex and Jellyfin: neither server indexes it. Emby does (measured), and
  Emby HEIC photos simply work.
- A Music-style sidebar inside the photo library. A photo server has two browse
  dimensions (folders and dates), not four, so a second sidebar beside the
  shell's would nest navigation for three filters.

## Anti-goals (a failure even if it works)

- A photo leaks into Home, Search, Continue Watching, Top Shelf or the detail
  page. `PhotoItem` stays its own type and is never mapped into a `MediaItem`.
- The library's first screen gets slower. The memories row, the map data and the
  favorites view load after the grid, never in front of it.
- A server request in an app folder. All photo server code stays in
  `RivuletCore/MediaProvider/<Server>/…PhotoProvider.swift`.
- Coordinates in the repo. The test photos carry the owner's real GPS. Fixtures
  and tests use invented coordinates; no log or Sentry event carries a location.

## What exists today

- `RivuletCore/MediaProvider/PhotoProvider.swift`: one requirement,
  `photoPage(in:folder:page:)`. Plex, Jellyfin and Emby adopt it in
  `…/Plex/PlexPhotoProvider.swift`, `…/Jellyfin/JellyfinPhotoProvider.swift`,
  `…/Emby/EmbyPhotoProvider.swift`.
- `RivuletCore/Models/Photos/PhotoItem.swift`: folder, photo or clip; title, date,
  thumbnail and full-size URLs, and a `MediaItem` for clips.
- `Rivulet/Views/Photos/PhotoListing.swift`: one folder level's paged contents,
  shared by grid and viewer. Foundation only, so it can move to RivuletCore as is.
- tvOS UIKit: `PhotoLibraryViewController` (a stack of grids, Menu steps back),
  `PhotoGridViewController` (folders then media, six across),
  `PhotoViewerViewController` (focusless, `DirectionalInputBinding`, fixed 4 s
  slideshow that skips clips and runs only from inside the viewer).
- Order is hardcoded per provider: Plex `originallyAvailableAt:desc`, Jellyfin and
  Emby `DateCreated` descending.
- iOS and Mac: the providers and `BrowseStore` already know `LibraryKind.photos`;
  there is no photo surface. The builder confirms how those apps treat a photo
  library today (hidden, or opened as something else) before adding one.

## What the servers provide (measured 2026-11-09)

Measured with curl against the main PMS (1.43.4, section "Rivulet Photo Test"),
`jellyfin-test` (12.1) and `emby-test` (4.10.2). Server details are in
`.claude/test-servers.md`.

| | Plex | Jellyfin | Emby |
|---|---|---|---|
| EXIF | `Media` attributes on the item request only (`/library/metadata/<id>`), not on lists: `make`, `model`, `lens`, `aperture` ("f/1.6"), `exposure` ("1/5"), `iso` | On list with no `fields`: `CameraMake`, `CameraModel`, `ExposureTime` (seconds), `FocalLength`, `IsoSpeedRating`, `Aperture` (APEX: f = 2^(A/2)) | None, even with explicit `Fields` |
| GPS | `Geolocation.Coordinates{latitude,longitude}` only with `includeGeolocation=1`, on `/library/sections/N/all` too | `Latitude`, `Longitude`, `Altitude` on list | None |
| Favorite | `PUT /:/rate?key=K&identifier=com.plexapp.plugins.library&rating=10`, `rating=-1` clears; filter `userRating=10`. Not the video 3-star rule. | `POST`/`DELETE UserFavoriteItems/{id}?userId=`; `filters=IsFavorite` | `POST`/`DELETE Users/{u}/FavoriteItems/{id}`; `filters=IsFavorite` |
| Sorts | `originallyAvailableAt`, `addedAt`, `titleSort`, `random` | `PremiereDate`, `DateCreated`, `SortName`, `Random` | same names as Jellyfin |
| Random paging | Consistent: 0 of 12 three-page runs repeated a photo; each `start=0` reshuffles | Repeats: 12 of 12 runs | Repeats: 12 of 12 runs |
| Date range | `originallyAvailableAt>=YYYY-MM-DD&originallyAvailableAt<=<day after the last day>` (`<=` excludes the named day) | `minPremiereDate`, `maxPremiereDate` | `MinPremiereDate`, `MaxPremiereDate` |
| Years present | `/library/sections/N/year?type=13` | `/Years?parentId=…&includeItemTypes=Photo` | builder measures `/Years` |
| Memories | No endpoint. Hub `photo.random.year.N` = "Photos from <year>", a different year per call | none | none |

Plex also groups photos into dated "moments" (`/all?cluster=N`) and lists
`photo.recent.favorites.N` as `/all?type=13,12&userRating=10&sort=updatedAt:desc`.
Neither is needed by this design.

## The design

### 1. Core

Everything below that is not a view is in RivuletCore.

- **Move `PhotoListing` to `RivuletCore/Photos/`** unchanged, then extend it.
- **A query on the seam.** `photoPage` takes a `PhotoQuery` (sort field, direction,
  show filter, favorites-only, date range) instead of hardcoded order. Each
  provider maps it to its parameters from the table above. The default query
  reproduces today's order exactly.
- **Date Taken on Jellyfin and Emby is `DateCreated`.** Measured: both servers set
  `DateCreated` to the EXIF capture time when a photo has one (photo-5:
  `DateCreated` equals its `DateTimeOriginal`) and to the file date when it does
  not, while `PremiereDate` is null without EXIF. So `DateCreated` is "taken, else
  file date", which is what the Date Taken label promises and what today's order
  already uses. Neither server has a separate added date, so **Date Added is a
  Plex-only sort** and the menu omits it elsewhere. Memories use the
  `PremiereDate` range filters on purpose: a photo with no camera date has no
  real anniversary.
- **Scope.** Every query and action covers what the grid shows: at the library
  root that is the whole library (the root already lists every photo
  recursively), inside an album that album's own photos and clips. Sort and Show
  apply to photos and clips; albums stay sorted by name. Shuffling an album
  together with its sub-albums is out of scope.
- **Shuffle** is a `PhotoListing` mode, not a sort the grid shows. Plex asks the
  server for `sort=random` and pages normally (measured consistent). Jellyfin and
  Emby: the listing loads pages in the user's sort and plays them in an order
  shuffled on the client, reshuffling each page as it arrives so the show can
  start at once. ponytail: shuffles within the loaded set, so the first minutes
  favour the first pages; upgrade to loading every id first if users notice.
- **`PhotoItem` gains** `isFavorite`, `coordinate` (lat/long, optional) and
  `details` (camera make and model, lens, aperture as an f-number, exposure as a
  fraction string, ISO, focal length, pixel size, file name). Each mapper fills
  what its server sends; Emby leaves EXIF and coordinates nil. Plex list requests
  add `includeGeolocation=1`; the builder measures the payload change on a page
  of 200 and drops it to the item request if it is large.
- **Favorites** are a protocol requirement, `setFavorite(_:for:)`, one
  implementation per provider. The UI updates optimistically on the one tile and
  rolls back on failure. This is a single photo's flag, not the Continue Watching
  case `CLAUDE.md` forbids. On Plex a favorite is `rating=10` and unfavorite is
  `rating=-1`, so unfavoriting clears any rating another Plex client set, and a
  photo rated five stars elsewhere shows as a favorite. That matches Plex's own
  "Recently Favorited Photos" hub, so it is accepted with no read before write.
- **The Favorites view** is one flat, library-wide grid: the same grid controller
  with `favoritesOnly` and no albums, recursive on every server (Jellyfin and
  Emby `filters=IsFavorite` with `recursive=true`, measured; Plex
  `/all?type=13,12&userRating=10` at the root with `clusterZoomLevel=1`). It
  has the same header actions, and Menu steps back to the root.
- **Memories** are a pure function plus queries:
  - "On This Day": photos whose date taken has today's month and day in an earlier
    year. Ask for the years the library has, then one date-range request per past
    year for today's date, in parallel, capped at the 10 most recent years.
    Shown only if non-empty.
  - "Photos from <year>": one past year chosen at random from the years present,
    excluding the current year, stable for the day (seeded by date) so the row
    does not change on every visit.
  - "Favorites": shown when the library has at least one.
  The date math (leap day, time zones, which years) is pure and unit-tested.
- **Preferences** (sort, filter per library; slideshow interval, transition,
  clips) are `UserDefaults` keys listed in `SyncCatalog` so they sync. Per-library
  keys use the per-server family form the catalog already supports.

### 2. tvOS

- **Grid header** (`PhotoGridHeaderView` becomes a real header): title, then a
  button row: Slideshow, Shuffle, Sort, Show. Sort and Show are `UIButton.menu`
  with `showsMenuAsPrimaryAction`, as Music's Sort and Filter are
  (`MusicBrowseViewController.refreshMenus`). Play/Pause anywhere on the grid
  starts a slideshow from the focused photo.
- **Library root** gains, above the albums, a **memories row** of large cards
  (below). The root also offers Favorites and Map as cards in that row when they
  apply, so they cost no extra chrome.
- **Large card.** A new `MediaRowMetrics.Tile`, two across:
  `gridWidth(columns: 2)` (860 pt) by 16:9, `lockup: .card`. This is the large
  row lockup from the Apple TV app that Rivulet has not used yet. Its geometry
  (growth, title placement, whether the title sits on the art) is measured against
  the Apple TV app before building, the way every other tile was. Art is one photo
  from the set; the title is the memory's name ("On This Day", "Photos from 2019",
  "Favorites", "Map").
- **Viewer.** Down opens the info pane over the bottom of the photo: date and
  time, camera line, exposure line, size, file name, a small map image from
  `MKMapSnapshotter` when there is a coordinate, and a Favorite button. Up or Menu closes it. The
  pane is the viewer's only focusable content, so the focusless binding stays as
  it is while the pane is closed. Slideshow uses the settings interval and
  transition; with "Play Clips" on, a clip plays to its end inside the show and
  the show resumes after it.
- **Favorites on tiles**: long press opens the tile menu
  (`TileMenuPopupViewController`, as Home's tiles do) with Favorite/Unfavorite;
  favorites carry a small heart badge.
- **Map**: a full-screen `MKMapView` with clustered pins. Selecting a cluster
  opens a grid of its photos. Map data loads every photo's coordinate for the
  library in pages, in the background, and caches it per library for the session.
  `MKMapView` and `MKClusterAnnotation` are in the tvOS 27.2 SDK (checked in the
  headers). Whether the Siri Remote pans and zooms it well enough is unknown; the
  builder spikes this first, and if it does not, the tvOS map becomes a list of
  places grouped by rounded coordinate with a `MKMapSnapshotter` image each.
- **Settings > Photos**: Slideshow Interval (3, 5, 10, 20 s; default 5), Transition
  (Dissolve, Pan and Zoom; default Dissolve), Play Clips in Slideshow (default On).
  Each row gets a descriptor in `SettingsDescriptors.swift`, and each key a reader.

### 3. iOS

- Photo libraries open a SwiftUI grid (adaptive columns) with the same header
  actions in a toolbar: Slideshow, Shuffle, and one menu for Sort and Show.
- The viewer is a paging full-screen view: swipe between photos, pinch and
  double-tap to zoom, tap to show or hide the chrome, the info pane as a sheet,
  Favorite in the chrome. Clips play through the existing iOS player.
- Memories row: the iOS app's own large card style, horizontally scrolling.
- Map: SwiftUI `Map` with clustered annotations.
- Settings: the three slideshow rows in the Account sheet's settings form.

### 4. Mac

- Same structure as iOS on `RivuletMac`'s shell: a grid, a viewer with arrow keys,
  Space for slideshow, the system full-screen, Command-I for info, F for
  Favorite, and a context menu on tiles.
- Map and memories as on iOS. Settings in the Mac settings window.

### Server gaps, stated in commits

- Emby: no info pane EXIF (date and size only), no coordinates, so no map card
  and no map in the pane.
- Plex and Jellyfin: HEIC photos are absent (server does not index them).

## Order of work

Each step ships on its own and keeps the apps working.

1. Core: move `PhotoListing`, add `PhotoQuery`, map sorts and filters per provider,
   default reproduces today. Tests for the mappings.
2. Photos on iOS and Mac at today's tvOS feature level (grid, folders, viewer,
   slideshow, clips).
3. Header actions on all three apps: Slideshow, Shuffle, Sort, Show. Slideshow
   settings.
4. Favorites: seam requirement, three implementations, tile action, badge,
   Favorites view.
5. Info pane, with `PhotoItem.details` and coordinates.
6. Memories row and the large card (measure the Apple TV app first).
7. Map (tvOS spike first).

## Testing

- Unit tests on the pure parts: query to parameters per provider, APEX to
  f-number, exposure formatting, On This Day years and date ranges (leap day, the
  first of January, a library with one year), the daily seed, client shuffle
  keeps every photo exactly once.
- Mapper tests from recorded responses with invented coordinates and names.
- Live checks against the three test servers for each provider change, as the
  existing photo work was measured.
- tvOS focus and remote behaviour (header row, info pane, map panning) is
  device-checked; a simulator pass is a first look only. Anything shipped unseen
  on a device gets a row in `Docs/DEVICE_CHECKS.md`.

## Left to the builder

- Exact header button styling on each app, within each app's existing patterns.
- The client shuffle's internals and the map's page size and cache.
- Info pane layout and wording, the heart badge's look.
- Whether Plex coordinates ride the list request or the item request, by payload
  measurement.
- The fallback tvOS map presentation if the spike fails.

## Calls made without the user (check these)

- Favorites instead of star ratings.
- Memories live in the library root; Home gets no photo row.
- Favorites and Map as cards in the memories row rather than header buttons.
- Slideshow default interval 5 s (today 4 s), Play Clips default On (today clips
  are skipped).
- On This Day capped at the 10 most recent years.
- Date Added offered on Plex only.
- Slideshow, Shuffle, Sort and Show cover one level: the whole library at the
  root, one album's own photos inside it.
- Favorites is a flat library-wide grid.
- Plex unfavorite clears any rating set elsewhere.
