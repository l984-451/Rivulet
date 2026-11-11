# Photo Library Improvements Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Photos on tvOS, iOS and Mac with slideshow, shuffle, sort, filter, favorites, an info pane, memories and a map, on Plex, Jellyfin and Emby.

**Architecture:** The seam (`PhotoProvider`), the item type, the paged listing, preferences, memories and map loading all live in `RivuletCore/Photos/` and `RivuletCore/MediaProvider/<Server>/…PhotoProvider.swift`. Each app adds only views: tvOS UIKit under `Rivulet/Views/Photos/UIKit/`, iOS SwiftUI under `RivuletiOS/Photos/`, Mac SwiftUI under `RivuletMac/Photos/`.

**Tech Stack:** Swift 6, UIKit (tvOS), SwiftUI (iOS, Mac), MapKit, XCTest.

**Spec:** `Docs/superpowers/specs/2026-11-09-photo-library-improvements-design.md` (read it first; this plan argues from it).

## Global Constraints

- No `#if os(...)` under `RivuletCore/` (lint rule `platform_conditional_in_shared_code`).
- No SwiftUI on a tvOS UIKit surface; tvOS photo views stay UIKit.
- `PhotoItem` is never mapped into a `MediaItem`; photos never reach Home, Search, Continue Watching, Top Shelf or the detail page.
- No server request code in `Rivulet/`, `RivuletiOS/` or `RivuletMac/`.
- No real coordinates, names or file paths from the test servers in tests, fixtures, logs or Sentry. Use invented values.
- Every user-facing string goes through the String Catalog (`String(localized:)`, `String.LocalizationValue` funnels); no em dashes in UI text.
- Every new setting key has a reader; synced keys are listed in `SyncCatalog`.
- Do not commit from a subagent. The coordinating session commits once per goal (A to F below), staging explicit paths only; the checkout is shared with other sessions.
- Do not touch `Rivulet/Views/Settings/UIKit/EmbySettingsContent.swift` or `JellyfinSettingsContent.swift` (another session's uncommitted work).
- No changelog entries (only on the maintainer's request).
- Build checks: tvOS `xcodebuild -scheme Rivulet -destination 'id=DE7A544B-4E50-49DA-9B78-65E969F63531' build`; iOS `xcodebuild -scheme "Rivulet iOS" -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`; Mac `xcodebuild -project Rivulet.xcodeproj -scheme "Rivulet Mac" -destination 'platform=macOS,arch=arm64' build CODE_SIGNING_ALLOWED=NO`. Tests: `xcodebuild test -scheme Rivulet -destination 'id=DE7A544B-4E50-49DA-9B78-65E969F63531' -only-testing:RivuletTests/<Class>`. Lint: `swiftlint lint --strict`.
- Measured server facts are in the spec's table; re-measure against the test servers (`.claude/test-servers.md`) before changing a provider's request shape.

## Review Focus

1. A library with albums but no photos, no favorites, no past years, or no coordinates: no blank card, empty row or empty map; each memory and the Map card simply do not appear.
2. On This Day on February 29, and on February 28 of a non-leap year: Feb 29 photos from leap years appear only on Feb 29; nothing crashes building the range.
3. Changing Sort or Show while a page is loading: the old page is dropped, the grid shows only the new order.
4. Client shuffle on Jellyfin or Emby when pages overlap: every photo appears exactly once.
5. A favorite toggle the server rejects: the heart and the Favorites view return to the old state, and the grid and viewer sharing the listing agree.

---

## Goal A: Photos on every app (commit after Task 4)

### Task 1: Core seam, query, details, listing

**Files:**
- Create: `RivuletCore/Photos/PhotoQuery.swift`, `RivuletCore/Photos/PhotoDetails.swift`, `RivuletCore/Photos/FixedPhotoProvider.swift`
- Move: `Rivulet/Views/Photos/PhotoListing.swift` → `RivuletCore/Photos/PhotoListing.swift` (git mv)
- Modify: `RivuletCore/MediaProvider/PhotoProvider.swift`, `RivuletCore/Models/Photos/PhotoItem.swift`, the three `…PhotoProvider.swift`, `RivuletCore/Models/Plex/PlexModels.swift` (`PlexMedia` EXIF fields, `PlexMetadata.Geolocation`), Jellyfin `JFItem` and Emby `EmbyItem` (EXIF, GPS, `FileName`/`Path` fields if absent), `Rivulet/Views/Folders/UIKit/FolderListViewController.swift` (replace private `SinglePhotoProvider` with `FixedPhotoProvider`)
- Test: `RivuletTests/Unit/Photos/PhotoQueryMappingTests.swift`, `PhotoDetailsTests.swift`, extend `PhotoListingTests.swift`, `PlexPhotoMapperTests.swift`, `JellyfinPhotoMapperTests.swift`, `RivuletTests/Unit/Emby/EmbyPhotoFolderTests.swift`

**Interfaces (produced, used by every later task):**

```swift
nonisolated struct PhotoQuery: Hashable, Sendable, Codable {
    enum Sort: String, Codable, CaseIterable, Sendable { case dateTaken, dateAdded, name }
    enum Show: String, Codable, CaseIterable, Sendable { case all, photos, videos }
    var sort: Sort = .dateTaken
    var ascending = false
    var show: Show = .all
    var favoritesOnly = false
    var shuffled = false
    /// Inclusive days, read in the device's zone.
    var takenBetween: ClosedRange<Date>?
    static let `default` = PhotoQuery()
}

nonisolated struct PhotoCoordinate: Hashable, Sendable { let latitude: Double; let longitude: Double }

nonisolated struct PhotoDetails: Hashable, Sendable {
    var takenAt: Date?; var make: String?; var model: String?; var lens: String?
    var fNumber: Double?; var exposureSeconds: Double?; var iso: Int?; var focalLength: Double?
    var width: Int?; var height: Int?; var fileName: String?
    var cameraLine: String? { get }     // "Apple iPhone Air"; model alone when it starts with make
    var exposureLine: String? { get }   // "f/1.6 · 1/5 s · ISO 3200 · 6 mm", missing parts dropped, nil if all missing
    static func fNumber(apex: Double) -> Double        // 2^(A/2), rounded to 1 decimal
    static func fNumber(plex: String) -> Double?       // "f/1.6" -> 1.6
    static func exposureSeconds(plex: String) -> Double? // "1/5" -> 0.2, "2" -> 2
    static func exposureText(_ seconds: Double) -> String // < 1: "1/N s" with N = round(1/s); else "2 s"
}

// PhotoItem gains (defaults keep existing initialisers compiling):
var isFavorite = false
var coordinate: PhotoCoordinate?
var details: PhotoDetails?

protocol PhotoProvider: Sendable {
    /// Plex [.dateTaken, .dateAdded, .name]; Jellyfin and Emby [.dateTaken, .name].
    var photoSorts: [PhotoQuery.Sort] { get }
    /// Plex true (server `sort=random` pages consistently); Jellyfin, Emby false.
    var shufflesPhotosOnServer: Bool { get }
    /// Plex, Jellyfin true; Emby false.
    var hasPhotoLocations: Bool { get }
    func photoPage(in library: MediaLibrary, folder: MediaItemRef?, query: PhotoQuery, page: Page) async throws -> PhotoPage
}

@MainActor final class PhotoListing {   // moved, Foundation only
    init(folder: MediaItemRef?, query: PhotoQuery = .default, source: @escaping Source)
    var query: PhotoQuery { get set }   // set reloads (loadFirst)
    var library: MediaLibrary? { get }  // from the last source() call
    // existing API unchanged: folders, media, isLoading, error, hasMore, onChange, loadFirst(), loadMore()
}
struct FixedPhotoProvider: PhotoProvider { init(items: [PhotoItem]) } // one page, ignores query except shuffled
```

Provider mapping (from the spec's measured table):
- Plex sort: dateTaken `originallyAvailableAt`, dateAdded `addedAt`, name `titleSort`; `:desc` unless ascending; shuffled `random`. Show: all `13,12`, photos `13`, videos `12`. favoritesOnly `userRating=10` (root with `clusterZoomLevel=1`, no albums). takenBetween `originallyAvailableAt>=YYYY-MM-DD&originallyAvailableAt<=YYYY-MM-DD`. Always `includeGeolocation=1` on the media request (measure the 200-item payload with and without; if it more than doubles, move it to Task 8's item request and note it). Map `Media[0]` make, model, lens, aperture, exposure, iso, width, height, `Part[0].file` last path component; `userRating == 10` is favorite; `Geolocation.Coordinates`.
- Jellyfin: dateTaken `DateCreated`, name `SortName`; `sortOrder` Ascending/Descending; shuffled keeps the user sort (the listing shuffles). Show: `includeItemTypes` `Photo,Video` / `Photo` / `Video`. favoritesOnly `filters=IsFavorite&recursive=true`, no albums. takenBetween `minPremiereDate`/`maxPremiereDate` (ISO day, end of day inclusive). Map `CameraMake`, `CameraModel`, `ExposureTime`, `FocalLength`, `IsoSpeedRating`, `Aperture` (APEX), `Width`, `Height`, `Path` last component, `Latitude`/`Longitude`, `UserData.IsFavorite`, `DateCreated` as `takenAt`.
- Emby: as Jellyfin with Emby's capitalised parameter names; details only `width`, `height`, `FileName`, `takenAt`; no coordinate. `UserData.IsFavorite`.
- Albums are fetched only for the default-shaped query (no favoritesOnly, no takenBetween, not shuffled) and stay sorted by name.

Listing shuffle (Jellyfin, Emby): when `query.shuffled && !provider.shufflesPhotosOnServer`, each appended page of media is shuffled before it joins `media` (the `seen` set still drops repeats). Folders are dropped from a shuffled listing.

- [ ] **Step 1: Write the failing tests.** `PhotoQueryMappingTests`: for each provider, the query items for `.default` equal today's (Plex `sort=originallyAvailableAt:desc`, `type=13,12`, `clusterZoomLevel=1` at root; Jellyfin `sortBy=DateCreated,SortName`, `sortOrder=Descending`; Emby `SortBy=DateCreated,SortName`, `SortOrder=Descending,Ascending`), and one case each for name ascending, show videos, favoritesOnly, takenBetween 2025-10-01...2025-11-30, shuffled (Plex `sort=random`; Jellyfin unchanged sort). Expose each provider's item builder as a `static func photoQueryItems(_ query: PhotoQuery, folder: MediaItemRef?, page: Page) -> [URLQueryItem]` so the test needs no network. `PhotoDetailsTests`: `fNumber(apex: 1.3561438531849228) == 1.6`, `fNumber(plex: "f/1.6") == 1.6`, `exposureSeconds(plex: "1/5") == 0.2`, `exposureText(0.0125) == "1/80 s"`, `exposureText(2) == "2 s"`, `cameraLine` for make "Apple" model "iPhone Air" is "Apple iPhone Air", for make "Canon" model "Canon EOS R5" is "Canon EOS R5", `exposureLine` with only ISO 125 is "ISO 125". Mapper tests: a Plex fixture with `Media` EXIF, `userRating: 10`, `Geolocation{latitude: 10.5, longitude: -20.25}` maps every field; a Jellyfin fixture likewise; an Emby fixture gives nil coordinate and nil camera fields. `PhotoListingTests`: `test_queryChangeDropsInFlightPage` (slow fake provider: set `query` mid-load, the old page never appears), `test_clientShuffleKeepsEachPhotoOnce` (fake provider returning overlapping pages of 1...10 with `shufflesPhotosOnServer = false`: media ids sorted equal 1...10, no duplicates).
- [ ] **Step 2: Run them; expect compile failures.** `xcodebuild test … -only-testing:RivuletTests/PhotoQueryMappingTests -only-testing:RivuletTests/PhotoDetailsTests -only-testing:RivuletTests/PhotoListingTests`
- [ ] **Step 3: Implement** the types, the move, the three providers, `FixedPhotoProvider`, and update the two tvOS callers (`PhotoLibraryViewController`, `FolderListViewController`) to the new signature with `.default`.
- [ ] **Step 4: Run all `RivuletTests/Photos*`, Plex, Jellyfin, Emby photo tests; expect PASS.** Build tvOS, iOS and Mac.
- [ ] **Step 5: Live check.** Against main PMS section 27, jellyfin-test library `89531ed55880a118468218376691ae3d`, emby-test parent 9: each sort, show and favoritesOnly returns the expected items (curl or a temporary test you delete). Record nothing location-bearing.

### Task 2: Photo libraries reach iOS and Mac

**Files:**
- Modify: `RivuletCore/MediaProvider/HomeFeed.swift` (`ServerRows` and `Assembled` gain `photoLibraries: [MediaLibrary]`, from `provider.libraries()` filtered to `.photos`, never fetched for rows), `RivuletCore/Client/BrowseStore.swift` (`@Published private(set) var photoLibraries: [MediaLibrary]`, set beside `libraries`, cleared where `libraries` is cleared)
- Create: `RivuletCore/Photos/PhotoListingModel.swift`
- Test: extend the existing `HomeFeed` assemble tests (find with `grep -rl "assemble(" RivuletTests`)

**Interfaces (produced):**

```swift
@MainActor final class PhotoListingModel: ObservableObject {   // SwiftUI wrapper for iOS and Mac
    let listing: PhotoListing
    @Published private(set) var folders: [PhotoItem]
    @Published private(set) var media: [PhotoItem]
    @Published private(set) var isLoading: Bool
    @Published private(set) var failed: Bool
    init(listing: PhotoListing)          // subscribes to onChange, mirrors state
    func loadMoreIfNeeded(after item: PhotoItem) // within 30 items of the end
}
/// The source a library's listing reads, shared by iOS and Mac.
@MainActor static func PhotoListing.source(for library: MediaLibrary) -> PhotoListing.Source
```
`source(for:)` resolves `MediaProviderRegistry.shared.provider(for: library.providerID) as? any PhotoProvider`, as `TVSidebarView` does today; move that lookup here and have tvOS call it too.

- [ ] **Step 1: Failing test:** `assemble` keeps a `.photos` library out of `libraries` and in `photoLibraries`, in server order.
- [ ] **Step 2: Run; expect FAIL.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run; expect PASS; build all three apps.**

### Task 3: iOS photo surfaces

**Files:**
- Create: `RivuletiOS/Photos/IOSPhotoLibraryView.swift` (grid page for a library or folder), `RivuletiOS/Photos/IOSPhotoViewer.swift` (full-screen pager)
- Modify: the iOS library list that renders `browse.libraries` (`IOSPlexLibrariesView`, find it from `IOSPlexLibraryView.swift`) to add a Photos section from `browse.photoLibraries`; `IOSPlexLibrarySplitView.detail`, `IOSRootView.swift:58` and `IOSNavigationContract.swift:94` route a `.photos` library to `IOSPhotoLibraryView(library:)`

**Interfaces:** consumes `PhotoListingModel`, `PhotoListing.source(for:)`, `ProviderPlayer` equivalent on iOS for clips (the path `IOSPlexLibraryView` uses to play a `MediaItem`).

Behaviour: adaptive grid (`GridItem(.adaptive(minimum: 110), spacing: 2)` square thumbnails, albums first as titled squares); tapping an album pushes the same view for that folder; tapping a photo opens `IOSPhotoViewer` as a full-screen cover. Viewer: `TabView(.page)` over `listing.media`, each page a `ScrollView` zoomable to 4x by pinch, double-tap toggles 1x/2.5x, single tap toggles chrome (close button, title and date, slideshow button). A clip page shows its thumbnail and a play button that plays it. Slideshow as tvOS today (fixed interval until Task 5). Images load through the iOS image cache the rest of the app uses (`IOSArtworkCache`).

- [ ] **Step 1: Build iOS; run on an iPhone simulator signed into the main Plex and jellyfin-test.** Open each photo library: albums, photos, a folder, the viewer, pinch, a clip.
- [ ] **Step 2: Check it on emby-test (HEIC photos show).**

### Task 4: Mac photo surfaces

**Files:**
- Create: `RivuletMac/Photos/MacPhotoLibraryView.swift`, `RivuletMac/Photos/MacPhotoViewer.swift`
- Modify: the Mac sidebar that lists `browse.libraries` to add photo libraries; `RivuletMac/Shell/MacRootView.swift:193` and `:224` route `.photos` to `MacPhotoLibraryView`
- Modify: `CLAUDE.md` (drop "Photos are tvOS only." from Standing exceptions; Photos section says all three apps), `RivuletMac/README-MAC.md` (file map)

Behaviour: as iOS, with the Mac's grid metrics (`MacMetrics`) and image loader. Viewer: arrow keys page, Space toggles slideshow, Escape closes, the window's full screen works, scroll-to-zoom with pinch on a trackpad.

- [ ] **Step 1: Build Mac; run; open each server's photo library; page with arrows; play a clip.**
- [ ] **Step 2: `swiftlint lint --strict` passes.**
- [ ] **Step 3: Commit Goal A** (explicit paths; `git show --stat` contains only this work): `Photos on iOS and Mac; photo queries in core`

---

## Goal B: Slideshow, Shuffle, Sort, Show and slideshow settings (commit after Task 6)

### Task 5: Preferences, tvOS header and settings

**Files:**
- Create: `RivuletCore/Photos/PhotoPreferences.swift`
- Modify: `RivuletCore/Sync/SyncCatalog.swift` (exact keys `photoSlideInterval`, `photoSlideTransition`, `photoSlidePlaysClips`; prefix family `photoLibraryQuery.` handled like `mediaLibrarySort.`)
- Modify: `Rivulet/Views/Photos/UIKit/PhotoGridViewController.swift` (header becomes `PhotoGridHeaderView` with title and a button row), `PhotoViewerViewController.swift` (interval, transition, clips, shuffle start), `PhotoLibraryViewController.swift`
- Modify: `Rivulet/Views/Settings/SettingsModels.swift` (`SettingsPage.photos`), `UIKit/SettingsPageModels.swift` (Photos row on root, Photos page), `SettingsDescriptors.swift` (three descriptors)
- Test: `RivuletTests/Unit/Photos/PhotoPreferencesTests.swift`, extend `SyncCatalogTests` (find with grep)

**Interfaces (produced):**

```swift
enum PhotoPreferences {
    enum Transition: String, CaseIterable, Sendable { case dissolve, panAndZoom }
    static let intervals: [TimeInterval] = [3, 5, 10, 20]
    static var slideInterval: TimeInterval { get set }   // key photoSlideInterval, default 5, snaps to intervals
    static var transition: Transition { get set }        // key photoSlideTransition, default .dissolve
    static var playsClips: Bool { get set }              // key photoSlidePlaysClips, default true
    static func query(for library: MediaLibrary) -> PhotoQuery          // key "photoLibraryQuery.<providerID>.<libraryID>", JSON string; favoritesOnly/shuffled/takenBetween never stored
    static func setQuery(_ query: PhotoQuery, for library: MediaLibrary)
}
```

tvOS behaviour: header row of four buttons under the title: Slideshow (`play.fill`), Shuffle (`shuffle`), Sort (menu: the provider's `photoSorts` with checkmark, then Newest First / Oldest First), Show (menu: All, Photos, Videos). Sort and Show are `UIButton` with `menu` and `showsMenuAsPrimaryAction = true`, styled as Music's (`MusicBrowseViewController.refreshMenus`, `MusicChrome`). Choosing one saves through `PhotoPreferences.setQuery` and sets `listing.query`. Slideshow opens the viewer at index 0 running; Shuffle opens it on a new `PhotoListing(folder:, query: listing.query with shuffled = true)` running. Play/Pause on a focused tile opens the viewer there running. Header buttons are reachable with Up from the first row (a `UIFocusGuide` if the engine does not find them). Viewer: interval from preferences; `.panAndZoom` animates the image view from scale 1.0 to 1.08 with a small drift across the interval, reset on each slide; with `playsClips`, a slide that is a clip presents the player and the show resumes on the next item when the player is dismissed (`ProviderPlayer.play(_:fromBeginning:from:onDismiss:)`); verify the player closes itself at a clip's end, and if it shows a post-video screen instead, close it from `.ended` through the same path. Settings > Photos: Slideshow Interval (`.cycle` 3 s, 5 s, 10 s, 20 s), Transition (`.cycle` Dissolve, Pan and Zoom), Play Clips in Slideshow (`.toggle`).

- [ ] **Step 1: Failing tests:** `PhotoPreferencesTests`: defaults (5, `.dissolve`, true); a stored 7 reads as 5 (nearest); `setQuery` then `query(for:)` round-trips sort, ascending and show but returns `favoritesOnly == false` and `shuffled == false` even if set. `SyncCatalog.isSynced("photoLibraryQuery.plex:abc.27") == true`, `isSynced("photoLibraryQuery.") == false`, the three exact keys true.
- [ ] **Step 2: Run; expect FAIL. Step 3: implement. Step 4: run; PASS.**
- [ ] **Step 5: Simulator check (provisional for focus):** header reachable, each menu changes the grid, Shuffle on a Jellyfin library shows each photo once over a full loop, settings rows change the running show. Grep each new key: more than one hit each.

### Task 6: iOS and Mac header and settings

**Files:** `RivuletiOS/Photos/IOSPhotoLibraryView.swift`, `IOSPhotoViewer.swift`, the iOS settings form (`RivuletiOS/Settings/`, add a Photos section), `RivuletMac/Photos/*`, the Mac settings window (`RivuletMac/Settings/`, add a Photos section).

Behaviour: toolbar with Slideshow, Shuffle, and one `Menu` holding Sort (provider's sorts plus direction) and Show, reading and writing `PhotoPreferences`. Settings: the same three controls as tvOS (Picker for interval and transition, Toggle for clips). Viewers honour all three preferences.

- [ ] **Step 1: Build iOS and Mac; check each control on the simulator and the Mac.**
- [ ] **Step 2: Commit Goal B:** `Photos: slideshow, shuffle, sort and filter on every app`

---

## Goal C: Favorites (commit after Task 7)

### Task 7: Favorites everywhere

**Files:**
- Modify: `RivuletCore/MediaProvider/PhotoProvider.swift` (`func setPhotoFavorite(_ favorite: Bool, for ref: MediaItemRef) async throws`), the three providers (Plex: `networkManager.setRating(…, rating: favorite ? 10 : nil)`, i.e. `rating=10` / `-1`; Jellyfin and Emby call their existing `setFavorite(_:for:)`), `RivuletCore/Photos/PhotoListing.swift` (`func setFavorite(_ favorite: Bool, at index: Int)`, optimistic, rolls back on throw, `Change.updated(media: Int)`)
- Modify tvOS: `PhotoCell.swift` (heart badge `heart.fill`, bottom trailing, when `isFavorite`), `PhotoGridViewController.swift` (long press → `TileMenuPopupViewController` with "Favorite"/"Unfavorite"; needs a simultaneous-permissive long-press recognizer as Home's), `PhotoLibraryViewController.swift` (push a Favorites grid: `PhotoListing(folder: nil, query: .init(favoritesOnly: true) merged with the saved sort/show)`, title "Favorites")
- Modify iOS and Mac: badge on tiles, context menu Favorite/Unfavorite, a heart button in the viewer chrome, a Favorites entry (a toolbar button at the library root until Task 10 adds the card)
- Test: extend `PhotoListingTests`

- [ ] **Step 1: Failing tests:** `test_setFavoriteUpdatesThenRollsBack` (fake provider that throws: `media[i].isFavorite` true then false, two `.updated(media: i)` changes), `test_setFavoriteSucceeds` (stays true, provider received `(true, ref)`).
- [ ] **Step 2: Run; FAIL. Step 3: implement. Step 4: PASS.**
- [ ] **Step 5: Live check on all three servers:** favorite a photo in the app, it appears in the Favorites grid, the server shows it (Plex `userRating=10`), unfavorite clears it. Clear every favorite you set.
- [ ] **Step 6: Commit Goal C:** `Photos: favorites`

---

## Goal D: Info pane (commit after Task 8)

### Task 8: Info pane on every app

**Files:**
- Create: `Rivulet/Views/Photos/UIKit/PhotoInfoPaneView.swift`, `RivuletCore/Photos/PhotoInfoLines.swift`
- Modify: `PhotoViewerViewController.swift`; iOS and Mac viewers
- Test: `RivuletTests/Unit/Photos/PhotoInfoLinesTests.swift`

**Interfaces:**

```swift
enum PhotoInfoLines {
    /// Display lines in order: date and time, camera, lens, exposure, "4032 × 3024", file name. Empty parts omitted.
    static func lines(for item: PhotoItem, locale: Locale = .current, timeZone: TimeZone = .current) -> [String]
}
```

tvOS: Down (press and swipe, through the existing `DirectionalInputBinding`, adding `.down`) opens the pane over the bottom third with a dark material; it holds the lines, a 320 × 180 `MKMapSnapshotter` image centred on the coordinate with a pin (only when `coordinate != nil`), and one focusable Favorite button. While the pane is open the slideshow stops, Left and Right still page (the pane updates), Up or Menu closes it. The Menu tap recognizer closes the pane before it closes the viewer. iOS: an info button opens a sheet with the same lines and a `Map` view. Mac: Command-I toggles an inspector with the same.

- [ ] **Step 1: Failing tests:** an Emby-shaped item (date and size only) gives exactly two lines; a full Jellyfin-shaped item gives six lines in order with exposure line "f/1.6 · 1/80 s · ISO 125 · 6 mm" (focal length rounded to whole mm).
- [ ] **Step 2: FAIL; Step 3 implement; Step 4 PASS.**
- [ ] **Step 5: Simulator check on each server; Menu with the pane open closes only the pane.**
- [ ] **Step 6: Commit Goal D:** `Photos: info pane`

---

## Goal E: Memories and the large card (commit after Task 10)

### Task 9: Memories in core

**Files:**
- Create: `RivuletCore/Photos/PhotoMemories.swift`
- Modify: `PhotoProvider.swift` (`func photoYears(in library: MediaLibrary) async throws -> [Int]`; Plex `/library/sections/<id>/year?type=13`, Jellyfin `Years?parentId=<lib>&recursive=true&includeItemTypes=Photo`, Emby: measure `Years` on emby-test first; if absent, derive from one request of `MinPremiereDate`-less photo dates sorted ascending and descending (first and last year) and list the span)
- Test: `RivuletTests/Unit/Photos/PhotoMemoriesTests.swift`

**Interfaces:**

```swift
nonisolated struct PhotoMemory: Hashable, Sendable {
    enum Kind: Hashable, Sendable { case onThisDay, year(Int), favorites, map }
    let kind: Kind
    let title: String            // "On This Day", "Photos from 2019", "Favorites", "Map"
    let cover: PhotoItem?        // nil only for .map
    /// What opening it lists: fixed items (On This Day) or a query.
    enum Content: Hashable, Sendable { case items([PhotoItem]), query(PhotoQuery), map }
    let content: Content
}
enum PhotoMemories {
    static let onThisDayYears = 10
    /// One inclusive day per earlier year present, newest first, at most `cap`. Feb 29 only in leap years.
    static func onThisDayRanges(today: Date, years: [Int], calendar: Calendar, cap: Int = onThisDayYears) -> [ClosedRange<Date>]
    /// A past year present in `years`, never the current one, the same for every call on one calendar day.
    static func featuredYear(today: Date, years: [Int], calendar: Calendar) -> Int?
    /// Order: On This Day, Photos from <year>, Favorites, Map. Each only when non-empty; Map only when hasPhotoLocations and a probe finds a coordinate.
    @MainActor static func load(provider: any PhotoProvider, library: MediaLibrary, today: Date) async -> [PhotoMemory]
}
```

`load` runs in parallel: years; On This Day ranges (one `photoPage` per range, limit 50, `takenBetween`, then merged newest year first); the featured year's first page limit 1 for its cover; favorites limit 1; for Map, one page of 50 with `show: .photos` looking for any coordinate. Any failure drops that memory, never the row.

- [ ] **Step 1: Failing tests:** `onThisDayRanges` for 2026-11-09 with years [2026, 2025, 2020, 2019] gives Nov 9 of 2025, 2020, 2019 in that order; for 2028-02-29 with [2027, 2024, 2023] gives only 2024-02-29; for 2027-02-28 with [2024] gives 2024-02-28 (not Feb 29); cap 2 of 5 years keeps the two newest. `featuredYear`: same day returns the same year across 100 calls; never 2026 on a 2026 date; nil for [2026]. `load` with a fake provider having no favorites and no coordinates returns only the kinds with content.
- [ ] **Step 2: FAIL; Step 3 implement; Step 4 PASS.**

### Task 10: The memories row on every app

**Files:**
- Modify: `Rivulet/Views/Media/UIKit/MediaRowMetrics.swift` (`static let feature: Tile`)
- Create: `Rivulet/Views/Photos/UIKit/PhotoMemoryCell.swift`
- Modify: `PhotoGridViewController.swift` (a `memories` section first, root only, orthogonal scrolling, hidden when empty), `PhotoLibraryViewController.swift` (opening a memory pushes a grid: `.items` through `FixedPhotoProvider`, `.query` through a listing with that query, `.map` to Task 11's map)
- Create iOS `RivuletiOS/Photos/IOSPhotoMemoriesRow.swift`, Mac `RivuletMac/Photos/MacPhotoMemoriesRow.swift`

The tile: first measure the Apple TV app's large two-across row lockup in the tvOS simulator (TV app, a row of two wide cards; screenshot at 1920 × 1080, record artwork size, gap, focus growth, and title placement). Then `feature = Tile(art: CGSize(width: gridWidth(columns: 2), height: measured or (width * 9 / 16).rounded()), lockup: .card, growth: measured)`, with the measurement in its doc comment. The cell draws the cover photo filled, a bottom gradient, and the memory title over it, as measured. iOS and Mac: a horizontally scrolling row of 16:9 cards about two-thirds of the content width on iPhone, 420 pt wide on iPad and Mac, title over the image.

- [ ] **Step 1: Measure; record the numbers in the plan's task notes and the Tile comment.**
- [ ] **Step 2: Build all apps; check the row on main PMS (On This Day appears on a date matching a test photo: use a fake `today` only in a DEBUG launch argument if needed, removed before commit), jellyfin-test, emby-test.**
- [ ] **Step 3: Commit Goal E:** `Photos: memories row with On This Day and Photos from a year`

---

## Goal F: Map (commit after Task 11)

### Task 11: Map on every app

**Files:**
- Create: `RivuletCore/Photos/PhotoMapLoader.swift`, `Rivulet/Views/Photos/UIKit/PhotoMapViewController.swift`, `RivuletiOS/Photos/IOSPhotoMapView.swift`, `RivuletMac/Photos/MacPhotoMapView.swift`
- Test: `RivuletTests/Unit/Photos/PhotoMapLoaderTests.swift`

**Interfaces:**

```swift
@MainActor final class PhotoMapLoader {
    init(provider: any PhotoProvider, library: MediaLibrary, pageSize: Int = 1000)
    /// Pages through every photo with `show: .photos`, keeping those with a coordinate; calls back after each page.
    func load(onPage: @escaping ([PhotoItem]) -> Void) async
}
```
Cached per library for the app session (a static dictionary keyed by provider and library id).

- [ ] **Step 1: tvOS spike first.** A throwaway `MKMapView` full screen in the simulator: can the Siri Remote touch surface pan and click-pinch zoom (`isScrollEnabled`, `isZoomEnabled`)? Record the result. If yes, build the full map; if no, build the fallback list (places grouped by coordinates rounded to 2 decimals, each a row with an `MKMapSnapshotter` image and the photo count), and say so in the commit.
- [ ] **Step 2: Failing test:** the loader keeps only items with coordinates across three fake pages and stops when `nextPage` is nil.
- [ ] **Step 3: FAIL; implement; PASS.**
- [ ] **Step 4: Views.** Annotations with `clusteringIdentifier = "photo"` showing a thumbnail; selecting a single photo opens the viewer on it, a cluster opens a grid of its members (`FixedPhotoProvider`). iOS and Mac use SwiftUI `Map` with the same behaviour. The map frames all points on open.
- [ ] **Step 5: Check on main PMS and jellyfin-test; Map card absent on emby-test.**
- [ ] **Step 6: Final:** full `RivuletTests` run, all three builds, `swiftlint lint --strict`, whole-branch review, add device rows to `Docs/DEVICE_CHECKS.md` (header focus, info pane, memories card focus, map remote input). Commit Goal F: `Photos: map`. Do not push.
