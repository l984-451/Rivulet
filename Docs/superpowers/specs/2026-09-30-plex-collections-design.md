# Plex Collections: Design

Date: 2026-09-30
Status: Draft, revised after the written-spec review
Issues: #321 (collections in Movie and TV libraries), #240 (collections pinned to Home), #56 (a movie's collection on its detail page)

## 1. Goal and issues addressed

Rivulet has no way to open a Plex collection. A `.collection` tile routes into
`PreviewCarouselViewController`, and its Play button hands the collection's ratingKey
to the player. `PlexNetworkManager.getCollectionItems` has no callers,
`PlexProvider.collectionItems(matching:in:)` returns `[]`, and search drops collections
(the `types` set in `PlexHomeViewController`'s search filter, ~1047).

This spec adds five pieces on the UIKit surfaces:

1. **Collection page.** A poster grid of one collection's members.
2. **Collections row** in each Movie and TV library (#321).
3. **Titles / Collections switch** in the library sort header. It swaps the library grid to collections (#321).
4. **Collections on Home** (#240). P1 is Plex's own promoted collection hubs, which Home already renders. P2 is Rivulet-local pins.
5. **"In this collection" row** on the movie detail page (#56). The SwiftUI row from `abf5ea9` stopped fetching at `c09e82e`. `c0b0bf7` then deleted it along with `MediaDetailView`.

## 2. Decisions

### User decisions (final)

| Decision | Detail |
|---|---|
| Scope | Build all five pieces. |
| Library row order | Hero, then Continue Watching, then Recently Added, then **Collections**. |
| Where P2 pins render | Inside the owning library's block on Home. |
| Collection page header | Title only. |
| Pins in Settings > Home Rows | Listed, each with an Unpin action. |
| Pin action for a library not pinned to Home | Hidden. |
| Server `collectionMode` pref | **Ignored.** It only controls how an `includeCollections=1` grid folds titles into their collections. Rivulet never requests that inline grid (rejected, see Non-goals). Every surface here reads `/library/sections/{id}/all?type=18` or `/library/collections/{rk}/children`, and the pref does not act on either one. |

### Conflicts between the code maps, resolved

| Topic | Options in the maps | Chosen | Why |
|---|---|---|---|
| Children pager | New `getCollectionChildren` (collection page map) vs fixing `getHubItems` to return `totalSize` (pins map, API map) | Fix `getHubItems` and reuse it with hubKey `/library/collections/{rk}/children` | One fix covers three things. It gives the page a real total for slot sizing, it pages P2 rows, and it repairs P1 collection rows that stop after about one extra page today. The fix is two edits, not one token: return `totalSize`, and keep the hub key's own query (§5.1). |
| Listing endpoint | New `getLibraryCollections` on `/library/sections/{id}/collections` (row map, switch map) vs the existing `getLibraryItemsWithTotal(type: 18)` (API map) | Existing `getLibraryItemsWithTotal(type: 18)`, no sort, filtered at the call site | The two endpoints return the same fields. Only tvOS consumes the list, and CLAUDE.md moves code into RivuletCore only when a slice needs it. That keeps one more edit out of `PlexNetworkManager.swift`, which carries another session's uncommitted Live TV hunks. |
| Empty-collection filter | `childCount > 0` only (switch map); plus a machineIdentifier predicate on two new model fields (row map); plus a size-0 probe of every smart collection (API map) | `childCount > 0` only | Costs zero requests and drops all 41 empty collections on section 1. The 4 remaining false positives (8 across both sections) are smart collections orphaned by a server migration on this one server. They open to the page's empty state. §12 records the default (no code). |
| Who owns the collection list | VC-local `[MediaItem]` (row map) vs VC-local `[PlexMetadata]` (switch map); fetched in `refreshThisLibraryHubs` vs `viewDidLoad` | VC-local `[PlexMetadata]`, fetched in `refreshThisLibraryHubs` | The grid stores `PlexMetadata?`, and the row maps through `mapToMediaItems`. Fetching beside the hubs gives the list the hubs' refresh triggers, which is the only mid-session path for a collection Kometa adds. An unchanged list costs the request and nothing else (§5.4). |
| Tile menu on a collection tile | `[]` (row map, switch map) vs Open plus Pin/Unpin (pins map) | Pin to Home / Unpin from Home only, in library mode; `[]` elsewhere | P2 needs an entry point. Select already opens the collection, so an Open action repeats it. |
| Detail row source | `/related`'s `collection.related` hub (detail map) vs Collection tag id, then lookup, then children (API map) | `/related` hub | The detail page already makes this call. Plex has already picked the collection and ordered its members. The change also fixes two live Related defects (§5.6). `MediaItemDetail.collections` stays `[String]`, since nothing reads it. |
| Collection lookup for the trailing tile | `/library/sections/{sid}/collections?index=` (detail map) vs `/library/all?type=18&index=` (API map) | `/library/all?type=18&index={tagId}`, requested only when the collection hub reports `more` | Section-free, 869 bytes, verified for tag 61303. A collection of 12 or fewer shows every member already, so it costs no extra request. |
| Detail tile to collection page | New `onShowCollection` callback through `ExpandedDetailContainerView` (detail map) vs a guard in `presentStandaloneDetail` (page map) | The guard. Every tile keeps using `onShowRelatedDetails` | No new callback plumbing. The carousel arms its shelf-row restore before presenting, and the page's `onDismiss` closure re-runs it (§5.2). |
| Collection page header | Add subtitle and summary labels to `HubHeaderView` (page map) | Title only, `HubHeaderView` unchanged | This matches the Watchlist page. `HubHeaderView.configure` documents that row headers show no amounts, and the view is shared by every row header. Title only is a user decision (§2). |
| `showLibraryCollections` toggle | Add one (row map) | Not added | No decision asks for it (YAGNI). |
| `smart` field on `PlexMetadata` | Add (row map, API map) | Not added | Nothing reads it once the filter is `childCount` only. |
| Presenting from `presentStandaloneExpandedDetail` | Guard it too (page map) | Not guarded | Hero Info and tile-menu More Info never carry a collection once the collection tile menu drops More Info. |

### Other design decisions

- The collection page is `HomeMode.collection(MediaItem)` on `PlexHomeViewController`, presented modally. It is not a sidebar route and not a separate VC.
- No new `HomeSectionKind`. Every new row is a `.hub` (kind `.recentlyAdded`) or the existing `.grid`.
- The Titles / Collections state lasts for the session only. It is not written to `UserDefaults`.
- Collections state uses the server's default order (titleSort, Kometa's curation) with no sort control and no A-Z bar.

## 3. Non-goals

- **Video playlists.** A separate follow-up spec.
- **Inline `includeCollections=1` grid tiles** (collections mixed into the titles grid).
- **A per-library Collections sidebar tab.**
- **iOS UI.** RivuletCore changes stay platform-neutral and compile in both targets. The iOS app gets no new screen.
- **Writing Plex's Home layout** from Rivulet. `/hubs/sections/{id}/manage` is owner-only; P1 is read-only here.
- Collections in Search, sorting or an A-Z bar in Collections state, reordering pins, a count or year span in the collection page header.

## 4. Measured Plex facts

PMS 1.43.4, Movies section 1 unless noted. GET only, except the one P1 promotion noted below.

**Listing**
- 112 collections against 1,016 movies. `/library/sections/1/collections` returns all 112 in 71KB, 35ms. `/library/sections/1/all?type=18` returns the same fields with `totalSize`, paging and sort.
- Default order is titleSort. Kometa's `!010_` prefixes put Newly Released, the IMDb lists and the genre collections first.
- Both endpoints page only when `X-Plex-Container-Start` is sent with `X-Plex-Container-Size`. Size alone returns everything and no `totalSize`.
- `sort=titleSort:desc`, `addedAt:desc` and `random` are honoured. Rating and release-date sorts are silently ignored. `sort=mediaHeight:desc` returns HTTP 200 with an **empty** list.
- Server-side `childCount` filters (`childCount>=1`, `!=0`) are ignored; `totalSize` stays 112.
- `/firstCharacter?type=18` counts collections (sum 112, 46 under `#` because of the prefixes), empty ones included.
- 40 of 112 are smart. `smart` is the **string** `"1"` and is absent when false. `minYear`/`maxYear` are strings (33/112). `collectionSort` is `"2"` on 3/112. `art` is present on 12/112 movie collections and 0/8 TV.
- TV section 2 has 8 collections, all under `#`.

**Emptiness**
- 41 of 112 report `childCount` 0, Kometa separators like "Genre Collections" among them. Every one spot-checked (Batman, Die Hard, 28, Genre Collections, The Dark Knight, smart Talk Show Movies and Travel Movies) returns 0 children.
- Of the 71 with `childCount > 0`, 67 match their children `totalSize`. The other 4 are Plex Popular (20), Popular (16), Top Rated (126) and Oscars (179). All four are smart, and their `content` URI names machineIdentifier `4c8844eb...` while `/identity` reports `48ebbb1a...`. They are orphans of a server migration with a frozen `childCount`. Popular (rk 96342) reports 16 and `/children` returns 0. TV has 4 more of the same kind.
- A `children?X-Plex-Container-Start=0&X-Plex-Container-Size=0` probe returns 54 bytes with `totalSize` in 10 to 35ms.

**Children**
- `/library/collections/{rk}/children` needs Start with Size. Size=5 alone returned all 416 Action Movies (1,005,040 bytes). Start=0&Size=5 returned 5 items and `totalSize` 416.
- Order follows the collection's `collectionSort`, and `sort=` is ignored. James Bond (rk 9144) comes back Dr. No (1962) through No Time to Die (2021). IMDb Top 250 comes back in its custom rank.
- TV collections' children are shows.
- `/library/metadata/{rk}/children`, which `getChildren` and `PlexProvider.children(of:)` use, returns the 4 Bond films for a manual collection and **0 for a smart one**.
- `/library/sections/{id}/all?collection={tagId}`, which `getCollectionItems` uses, returns title order and 0 for a smart collection.

**Artwork**
- A custom poster is `/library/metadata/{rk}/thumb/{ts}` (Bond: 2000x3000). Without one, `thumb` is `/library/collections/{rk}/composite/{ts}?width=400&height=600` (16/112 movie, 4/8 TV). The composite returns a 400x600 JPEG when the collection has items and 404 when it is empty.
- `PlexMediaMapper.artworkURL` appends `?X-Plex-Token=` to that path, and the double `?` returns 401. The `&` form returns 200 image/jpeg. Three legitimate section 1 collections have no custom poster (Cinderella, The Hobbit, Marvel Studios).

**Hubs and promotion (P1)**
- Collection hubs in `/hubs/sections/{id}` have hubIdentifier `custom.collection.{section}.{rk}.{rk}` and key `/library/collections/{rk}/children`.
- `POST /hubs/sections/{id}/manage?metadataItemId=` defaults all three promote flags to true. After collection 9144 was promoted, `/hubs/sections/1` returned its hub with `promoted=true, size=4`, and `/hubs/promoted` included it. The test entry was deleted right afterwards (`DELETE /hubs/sections/1/manage/custom.collection.1.9144`), which is why later probes do not see it. QA promotes a collection again in Plex.
- With Start and Size, `/library/collections/{rk}/children`, `/library/sections/1/all` and `/hubs/sections/1/continueWatching/items` all return `totalSize`. `getHubItems` returns `MediaContainer.size` instead.
- Many hub keys carry their own query (`/hubs/sections/1?count=24`): `movie.recentlyadded.1` is `/library/sections/1/all?sort=addedAt:desc`, a genre hub is `...?unwatched=1&genre=80&audienceRating>=7.0`, and `tv.recentlyaired.2` is `/library/sections/2/all?type=4&sort=originallyAvailableAt:desc`. `getHubItems` assigns `components.queryItems = [Start, Size]`, which replaces that query. Start=24 on section 1 then returned the library in title order ("The Adventures of Huck Finn", ...) with `totalSize` 1016, and on section 2 it returned shows, `totalSize` 348, for an episode row. Today the `size` return caps that damage at one wrong page. With the query kept, `sort=addedAt:desc` still reports `totalSize` 1016, so Recently Added's true total is every movie.
- Pin removal statuses (2026-09-30): `/library/collections/{rk}/children` answers **404** for a deleted ratingKey and for a ratingKey that is not a collection, with the owner token. With a non-owner Home user's server token (via the same `/api/v2/home/users/{uuid}/switch` Rivulet uses), a shared collection answers 200, a deleted one 404, and any item in a library not shared with that user 404. So 404 means the collection is gone or no longer visible to that profile, and the pin cannot render either way. No user on this server has label restrictions (`restricted` 0, empty `filterMovies`/`filterTelevision` for all 21 shares), so a label-restricted collection is untested; by the same reading a 404 there is also a correct unpin.

**Detail `/related`**
- `/library/metadata/{rk}/related` returns at most one collection hub per section: hubIdentifier `collection.related.{sid}.{sid}`, context `hub.collection.related`, title "<Name> Collection". Members come in the collection's order and include the current movie. `more` is set when the collection holds more than count=12.
- Raiders of the Lost Ark (87157): today's Related row is 12 IMDb Top 250 tiles, Raiders among them. "More by Steven Spielberg" and "More with Harrison Ford" never show. Diamonds Are Forever (55947): Related is the four Bond films, itself included.
- Spider-Man: No Way Home carries 4 collection tags and gets one hub (Avengers). The rule looks like "first tag whose collection has 2 or more members" (moderate confidence).
- A movie's Collection tag id (61303) is not the collection ratingKey (9144). It equals the collection's `index`. `/library/all?type=18&index=61303` returns rk 9144 (869 bytes). Tag 353397 maps to rk 118562.
- Smart collections never appear as Collection tags. Grid-list items carry Collection tags without ids.
- For the show UNTAMED, the first collection hub is the movie-typed "Movies in IMDb Popular Collection" (`collection.related.1.1`).

**Model decoding**
- Today's `PlexMetadata` decodes every collection payload. A test declaration of `smart: Int?` throws `typeMismatch` at `Metadata[0].smart` and loses the whole container. Any collection field added later must be `String?`.

## 5. Architecture

### 5.1 Shared API and model

`RivuletCore/Plex/PlexNetworkManager.swift` (no `#if os`, compiles in both targets):
- **`getHubItems`**, two edits that ship together:
  - Return `container.MediaContainer.totalSize ?? container.MediaContainer.size`. Today `loadMoreIfNeeded` in `PlexHomeViewController` seeds `totalSize` from the page count and ends a row after about two pages, so a 416-item row stops at 48.
  - Keep the hub key's own query: `components.queryItems = (components.queryItems ?? []) + [Start, Size]` (plus `identifier` for `/hubs/items`), the merge `PlexMediaMapper.playableURL` already does. Returning `totalSize` alone would turn today's one wrong page into an unbounded one: every Recently Added, genre and top-unwatched row would page through the whole library in title order (§4).
  - Pull the URL construction into a `nonisolated static func hubItemsURL(serverURL:hubKey:hubIdentifier:start:count:) -> URL?` so it can be unit-tested (§9).
  - Together these make `getHubItems` the collection-children pager. Collection keys carry no query, so the merge does not affect them.
- **`getRelatedItems`**: return the raw `[PlexHub]` (`MediaContainer.Hub`, or top-level `Metadata` wrapped in one hub as a fallback) in place of the flattened, deduped, capped list. Its only caller is `PlexProvider.relatedItems`, and the flatten, dedupe and 12 cap move there. iOS and the tests do not call it.
- **Delete `getCollectionItems`.** It has no callers, returns title order, and returns nothing for smart collections.
- **Add `getCollection(serverURL:authToken:tagId:) async throws -> PlexMetadata?`**: `GET /library/all?type=18&index={tagId}`, returns `Metadata?.first`. Only the detail row's trailing tile uses it, and only when the collection hub has `more == true` (`PlexHub.more` already decodes).

Listing reuses `getLibraryItemsWithTotal(serverURL:authToken:sectionId:start: 0, size: 1000, type: 18)` with no `sort`. The call site filters `($0.childCount ?? 0) > 0`. A `// ponytail:` comment names the 1000 ceiling: a library with more collections would be truncated, and the upgrade is paging on `totalSize`.

`PlexMetadata`: no change. `childCount`, `index`, `thumb` and `art` already decode.

`Rivulet/Services/MediaProvider/Plex/PlexMediaMapper.swift`:
- **`artworkURL`**: pick the separator with `path.contains("?") ? "&" : "?"`. Paths without a query are unchanged. `PlexDataStore` (~1866) already builds its token URLs this way.

`Rivulet/Services/MediaProvider/MediaProvider.swift`:
- Replace `collectionItems(matching:in:)` (dead stub) and `relatedItems(for:)` with `related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent`. `MediaItemRef` carries only `providerID` and `itemID`, so the kind has to be passed for the type check in §5.6; `BelowFoldContentLoader` already has `item.kind`. The result types are `RelatedContent { items: [MediaItem]; collection: CollectionRow? }` and `CollectionRow { title: String; members: [MediaItem]; collection: MediaItem? }`. There is one conformer (`PlexProvider`) and one stub (`StubMediaProvider` in `RivuletTests/Unit/HomeComposerTests.swift`).

### 5.2 Collection page

`HomeMode.collection(MediaItem)` on `PlexHomeViewController`. The item carries `ref.itemID` (the collection ratingKey), `title` and artwork. `HomeMode` has no `Equatable`, so the associated value costs nothing, and external users (`PlexHomeUIKitBridge`, `PlexHomeRoot`, `TVSidebarView`, `SearchContainerViewController`) use `if case` or build a specific case.

**Sections.** One `.grid` section titled with the collection title. `HomeSectionData.grid(items:)` gains `title: String? = nil` and sets `headerStyle: title == nil ? .swiftUIInfiniteRow : .swiftUIWatchlist`. `makeGridSectionLayout` already reserves a `HubHeaderView` supplementary for a titled grid section, but the style comes from `headerStyle`, which the builder hardcodes to `.swiftUIInfiniteRow` today. Without the second change the header would render in the 34pt row style. `computeSections` gets
`if case .collection(let item) = mode { return gridItems.isEmpty ? [] : [.grid(items: mapGridSlots(gridItems), title: item.title)] }`,
the Watchlist pattern. The header is therefore first dequeued after page 0 arrives. The single section is `topSectionIndex` 0.

**Data.** `loadGridPage(containing:)` widens its `guard case .library` so that collection mode calls
`getHubItems(hubKey: "/library/collections/\(rk)/children", start:, count: gridPageSize)`.
It sends no sort, because the server applies `collectionSort`. The sparse slots, `gridGeneration`, slot sizing from `totalSize` and `reconfigureGridSlots` are reused unchanged. Never route a collection through `getChildren` or `PlexProvider.children(of:)`.

Page 0's outcome needs its own state, because an empty `gridItems` reads the same after a failure, after an empty answer and while the request is in flight. A collection-mode `private var pageZero: PageZeroState = .loading` (`.loading`, `.loaded`, `.failed(String)`) is set by `loadGridPage`'s page-0 success and catch, and reset to `.loading` by the retry.

**Mode branches.** The compiler lists the 11 `switch mode` sites. The focus and `performMenuAction` items below are `if case .collection` checks it will not list.
- `emptyStateMessage`: "This collection is empty."
- `showHomeHero`: `false`, like `.watchlist`.
- `viewDidLoad`: `view.backgroundColor = .black`, because `BlurFadeAnimator` assumes an opaque page. Then load page 0. No alphabet index.
- `updateHomeState`, driven by `pageZero`: `.loading` shows the loading state with the focus anchor visible (see Menu below); `.failed` shows `.error(message:)` with Try Again; `.loaded` with no items shows the empty state; `.loaded` with items shows content. The anchor is hidden in every state except loading, so it never competes with the grid or the state view's button.
- Focus on content: `loadGridPage` applies the snapshot while the collection view is still hidden, so no grid cell exists when `updateHomeState` un-hides it, and a request made then finds no cell and moves nothing. In collection mode the content branch therefore calls `collectionView.layoutIfNeeded()`, takes `cellForItem(at: IndexPath(item: 0, section: 0))`, and passes it to `UIFocusSystem.focusSystem(for: view)?.requestFocusUpdate(to:)` followed by `updateFocusIfNeeded()`. The page already holds focus on the anchor, so the request is honoured. `RootShellViewController`'s `.contentBecameFocusable` handler no-ops once the library tab holds focus, so the page cannot rely on it.
- `observeDataStore` `.plexDataNeedsRefresh`: `reloadLoadedGridPages()`, a new helper that re-requests the loaded pages in place (`let pages = gridPagesRequested; gridPagesRequested = []; pages.forEach { loadGridPage(containing: $0 * gridPageSize) }`). Slots are positional, so the focused tile reconfigures and is never deleted. This covers playback and detail-page watch changes, which post the notification.
- `performMenuAction`: in collection mode, also call `reloadLoadedGridPages()` after the server call. Mark as Watched from a member's tile menu never posts `.plexDataNeedsRefresh` (the method calls `refreshHubs()` and `refreshLibraryHubs()` only), so without this the grid keeps stale watched badges. The library titles grid has the same gap today; this spec does not change it.
- `observeDataStore` publisher switch: join the `.discover, .search, .watchlist: break` arm.
- `selectHeroItemsIfNeeded`, `heroItemsVisibleOnHome`, `upgradeHeroFromTMDB`, `resolveHeroWithHubFallback`: join the existing no-hero arms.

The `stateView.onAction` retry sets `pageZero = .loading`, calls `updateHomeState()` and reloads page 0 in collection mode, where it would otherwise call `dataStore.refreshHubs()`. The loading branch also calls `setNeedsFocusUpdate()` in collection mode, so focus moves from the vanished Try Again button back to the anchor. `updateAmbientIfNeeded` must not fall back to `dataStore.homeItems` in collection mode. It seeds from the collection's own backdrop (`heroBackdropRequest()`) when there is one (12/112 have art), otherwise from the first loaded child.

**Presentation.** In collection mode `init(mode:)` sets `modalPresentationStyle = .overFullScreen` and `transitioningDelegate` to a stored `BlurFadeTransitioningDelegate`. UIKit holds the delegate weakly (the `PersonDetailViewController` precedent). The shell has no navigation controller, and every drill-in (`PersonDetailViewController`, `MediaItemDetailPageViewController`, the standalone carousel detail) is presented this way. A new `var onDismiss: (() -> Void)?` fires from `viewDidDisappear` when `isBeingDismissed`.

**Focus anchor (step 1, not a fallback).** In collection mode the page adds a zero-size `PreviewFocusAnchorView` (the carousel's class, internal and reusable as is) to its view. The top of `preferredFocusEnvironments` returns it while `pageZero == .loading`. The presentation therefore moves focus into the page on its first frame, the way the carousel's anchor and the person page's bio panel do, instead of leaving it on the library tile underneath. Why this is required is under Menu below.

**Routing.** One static on `PlexHomeViewController`:

```swift
@discardableResult
static func openCollectionIfNeeded(_ item: MediaItem,
                                   from presenter: UIViewController,
                                   onDismiss: (() -> Void)? = nil) -> Bool
```

It returns false unless `item.kind == .collection`. Otherwise it walks `presentedViewController` to the top. If the walk passes a `PlexHomeViewController` in `.collection` mode with the same ratingKey, it calls `dismiss(animated: true)` on that page, which unwinds everything above it, and returns true. This breaks the loop of collection page, member detail, that detail's trailing collection tile, and the same collection page again, which would otherwise stack two modals per lap. Otherwise it presents the page from the top controller and returns true. Two call sites, each as the first line:
- `PlexHomeViewController.presentPreview(forSection:indexPath:)`: grid taps, every shelf row (via `handleShelfTap`), and search (via `handleSearchTap`).
- `PreviewCarouselViewController.presentStandaloneDetail(_:)`: below-fold Related and the new detail row. When the item is a collection, the carousel first calls `expandedDetail.restoreShelfRowFocusIfNeeded()`, then passes `onDismiss: { [weak self] in self?.restoreBelowFoldFocusAfterReturn() }`.

The pre-present arm is required. `restoreBelowFoldFocusAfterReturn` has never fired in practice: a standalone detail's Menu path is a bare `dismiss(animated: true)`, and the carousel calls its own `onDismiss` only from the two non-standalone morph paths. The method came in with commit `c36832a` ("TEMP"), so the collection page is its first real caller. Its `setNeedsFocusUpdate` is ignored unless the carousel contains focus, and the carousel sets `restoresFocusAfterTransition = false`, so on dismissal the engine runs a fresh resolution first. Unarmed, that resolution falls back to the shelf host's `lastFocusedIndexPath`, and the nested row restarts at item 0: focus goes to the first member and the row scrolls back to its start. Armed before presenting (the row and tile exist then, and the carousel cannot resolve focus while the modal is up), the fresh resolution consumes `armedShelfRestoreCell`, and `onDismiss` re-arms, updates and clears it. The member standalone detail keeps today's behaviour: its restore does not fire, and fixing that is outside this spec.

The Play key already ignores collections (`playableItem` returns nil for `.collection`). `tileMenuSections(for:isContinueWatching:shelfLocation:)` gets an early `.collection` branch (§5.5). Today the generic menu offers Watch from Beginning, which sends the collection ratingKey to `playItem`.

**Menu.** The library PHVC underneath stays registered with `MenuPressInterceptor` while the page is up: it registers in `viewDidAppear` and resigns only in `viewWillDisappear`, which an `.overFullScreen` presenter never gets. Handlers are offered newest first, so the library is asked before `RootShellViewController`. If focus stayed on the tapped library tile during loading, the library's `handleMenuBack` would pass its containment check, and `StagedMenuBack.shouldReturnToTop` would pass too, because the tile always sits below the hero (the Collections row or the grid). It would run `returnToTopRow()` under the modal and swallow the press. The hidden library would jump to its hero, and the next Menu would reach the shell and expand the covered sidebar (`cfb44f1`). Arrows would scroll the hidden library, and Select would present a carousel over the loading page. The anchor prevents all of it. With focus on the anchor or on a grid tile, the page's own `handleMenuBack` declines (the anchor is outside its collection view, and every grid tile is in `topSectionIndex`), the library and the shell decline on containment, and the system dismisses the modal, the same path `PersonDetailViewController` takes with no Menu code. A separate header section would sit at index 0, and Menu would return-to-top forever without ever dismissing. That is why the header is a supplementary. If a device shows otherwise, add `MediaItemDetailPageViewController`'s `.menu` tap-to-dismiss.

**Focus back on the library.** This relies on the system's post-dismiss restore to the tapped tile, which hero Info and More Info already use. If device testing loses the tile, the fallback is to set `pendingPreviewRestore` before presenting and run `applyPendingPreviewRestoreIfNeeded()` from `onDismiss`. That path already scrolls the cell into existence before `preferredFocusEnvironments` names it.

Not wired: `presentStandaloneExpandedDetail` (see §2) and the Top Shelf deep link (never sees collections).

### 5.3 Library Collections row

- `private var libraryCollections: [PlexMetadata] = []` on `PlexHomeViewController`. One fetch serves the row and the switch.
- **Fetch** in `refreshThisLibraryHubs`: start an `async let` of `getLibraryItemsWithTotal(type: 18)` before the hubs call and await it before `applySnapshot`. Assign only on success. A failed fetch keeps the previous list and never sets `libraryHubsError`. Filter `childCount > 0` and keep server order. The list refreshes on the hubs' triggers: launch after the cache paint, and `.plexDataNeedsRefresh`.
- **On each successful fetch**, compare the new ratingKey sequence with the old one. `.plexDataNeedsRefresh` fires on every player exit, and the list almost never changes there, so an equal list skips the two steps below. The grid follows its own rule in §5.4, which compares against the grid's copy rather than the old list. Different:
  - Call `refreshSortHeaderCount()`. The header's item id never changes, so `applySnapshot` never re-vends it, and page 0 of the titles grid usually configures the header first, with an empty list. Without this call the switch stays hidden (or stays shown after the list empties) until the cell is dequeued again.
  - Update pin titles: `HomeCollectionPins.updateTitles(from: libraryCollections, libraryUUID:)` rewrites a stored pin whose collection was renamed in Plex, and writes nothing when no title differs.
- **Not in `PlexDataStore.projectLibraryItems`.** That projection is written to disk, and Home's `projectAllLoadedItems` re-projects every library without this data, so the row would need a carry-over path. The row therefore has no warm-launch cache and arrives with the network refresh, below the hero, CW and recent rows.
- **Keep the focused tile still when the row appears.** Every other library row paints from cache, so this is the one section routinely inserted into a live page, above the genre rows, the sort header and the grid. The page drives its own scroll (`isScrollEnabled = false`) and moves `contentOffset` only on focus changes, so a row inserted above the focused one pushes the focused tile down a full poster row, often off screen. When the apply in `refreshThisLibraryHubs` inserts or removes the Collections row and focus sits in a section after its slot, note the focused cell's `frame.minY` before the apply, call `collectionView.layoutIfNeeded()` after it, and add the change in `minY` to `contentOffset.y`. The page owns its offset, so a direct write is safe. The same path covers a list that goes from empty to non-empty mid-session.
- **Rendering**: `HomeSectionID.libraryCollections = HomeSectionID(raw: "collections")`. Each library key has its own cached VC, so the id cannot collide.
  `.hub(id: .libraryCollections, title: "Collections", items: mapToMediaItems(libraryCollections), isContinueWatching: false, hubKey: nil, hubIdentifier: nil, totalSize: libraryCollections.count)`.
  That gives `PosterCell` tiles, which already hide progress and watched badges for `.collection`, the shelf tap into `presentPreview`, and no pagination, because `loadMoreIfNeeded` bails on a nil `hubKey`.
- **Placement** in `computeLibrarySections`, after the Recent and Discovery gates. Insert the row once, immediately after the last surviving hub that is `isContinueWatching` or `isRecentRow`, or at index 0 of the hub rows when there is none. Measured server orders are section 1: inprogress, recentlyreleased, recentlyadded, genre... and section 2: inprogress, recentlyaired ("Recently Released Episodes", matched by title), recentlyadded. So the row sits after Recently Added. With Recent Rows off it follows Continue Watching. With neither it comes first after the hero. An admin can reorder library hubs in Plex's Manage Recommendations (and a P1 promotion adds a `custom.collection` hub), so a non-essential hub may come before CW or Recently Added. Keying on the last essential hub keeps the decided order in that case; keying on the first non-essential hub would put Collections above CW. The index rule is a small `nonisolated static` so it can be tested.
- The row is omitted when the list is empty. Only movie and show libraries reach `.library` mode (music goes to `MusicHomeView`), so no type guard is needed.
- Library Recommended `custom.collection.*` hubs are unaffected. They show a collection's members, not collection tiles, and Discovery Rows still gates them.
- `observeUserDefaults` needs no change.

### 5.4 Titles / Collections switch

**Control** (`Rivulet/Views/Media/Library/UIKit/MediaLibrarySortControl.swift`):
- Add a second `SortButton`, `viewButton`, as a cycle pill showing the current state: "Titles" or "Collections". Select flips it. It gets `SortButton`'s glass focus, select debounce and press overrides for free. `SortButton.configure(sortName:)` gains a `symbol:` parameter whose default is today's `arrow.up.arrow.down`.
- Layout: `viewButton` pins to the trailing edge, with `sortButton` to its left, so the focused switch never moves when `sortButton` hides. Keep the title-overrun constraint against the leftmost visible button. The cost is the other direction: when the switch first appears (the list arrives), a focused `sortButton` shifts left by the switch's width. That happens at most once per list arrival and is accepted.
- `configure(title:count:sortName:)` gains `collections: Bool?`. `nil` hides the switch, meaning the library has no non-empty collection. `false` shows "Titles" with "N items". `true` shows "Collections" with "N collections" and sets `sortButton.isHidden = true`, which also removes it from the focus graph.
- `preferredFocusEnvironments` returns `[sortButton, viewButton]`, so programmatic focus falls through to the switch when the sort button is hidden.
- Wire `onViewTapped` through the `.sortHeader` cell provider in `PlexHomeViewController`. Pass `collections: libraryCollections.isEmpty ? nil : gridShowsCollections`. The provider reads this only when the cell is dequeued or reconfigured, which is why a changed list calls `refreshSortHeaderCount()` (§5.3).

**Grid** (`PlexHomeViewController`):
- `private var gridShowsCollections = false`. The shell caches one controller per library tab, so the state survives tab switches and resets on relaunch.
- `setGridShowsCollections(_ on: Bool)`:
  1. `resetGrid()`, the block pulled out of `applySort`. It bumps `gridGeneration` so in-flight titles pages are discarded, clears `gridItems`, `totalGridCount`, `gridPagesRequested` and `pendingGridFocusItem`, and sets `collectionView.remembersLastFocusedIndexPath = false`. `applySort` calls it too.
  2. If on: `gridItems = libraryCollections`, `totalGridCount = libraryCollections.count`, synchronously.
  3. `applySnapshot(animated: false)`, `refreshSortHeaderCount()`, `reconfigureGridSlots(0..<gridItems.count)`. The reconfigure is required: the `grid-N` ids are the same in both states, so an apply alone leaves the old posters on screen.
  4. If off: `loadGridPage(containing: 0)`.
  5. `loadAlphabetIndex()`.
- `loadGridPage` gains `!gridShowsCollections` in its library-mode guard, so `willDisplay`'s look-ahead paging goes inert. `loadAlphabetIndex` gains `!gridShowsCollections` in its existing `guard case .library` line, which comes after the four reset lines. The reset must still run: it sets `alphabetIndex = nil` and hides the strip with `isHidden`, which the geometric occlusion rule requires. A guard placed above the reset would keep the titles table, show the strip on the first grid focus, and jump by title offsets in a collections grid.
- While the switch is on, each successful list fetch compares the grid's own ratingKeys (`gridItems`) with the new list. `setGridShowsCollections` is not called here; `resetGrid()` is for user toggles only.
  - Equal: nothing.
  - New list empty: `setGridShowsCollections(false)`, back to Titles.
  - Different while focus is in the grid section (`focusedSectionForHandoff == gridSectionIndex`) or while this controller has a presented collection page: leave `gridItems` alone. The `grid-N` ids are positional, so a swap under focus would silently show a different collection on the focused tile or on the tile the open page returns to. The next fetch compares again and catches up.
  - Different otherwise: assign `gridItems` and `totalGridCount`, `applySnapshot(animated: false)`, and `reconfigureGridSlots(0..<gridItems.count)`.
- Order is the server default. `gridSort` is never forwarded, because `sort=mediaHeight:desc` returns an empty list.
- **Focus**: the swap makes no focus request. The reconfigure re-vends the same header cell, so focus stays on the switch. Down enters the grid by geometry, and the existing `.grid` branch turns `remembersLastFocusedIndexPath` back on. Any later programmatic move into the grid uses `UIFocusSystem.requestFocusUpdate(to:)`.

### 5.5 Collections on Home

**P1 (Plex promotion): no new code.** `PlexDataStore.projectHomeItems` renders every promoted hub of each library pinned to Home and passes `hub.key` through, so a promoted collection hub arrives as a row. `loadMoreIfNeeded` pages it through `getHubItems`, which the §5.1 fix makes correct past 48. Promotion happens in Plex. Because the manage endpoint defaults all three promote flags to true, the collection also shows as a row on its library page. That is Plex behaviour.

**P2 (Rivulet pins)**

*Store.* `enum HomeCollectionPins` sits in `Rivulet/Services/Plex/HomeRowSettings.swift`, beside `HomeRowSettings`:
- `nonisolated struct Pin: Codable, Hashable, Sendable { ratingKey: String; libraryUUID: String; title: String }`. The target builds with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, so an unannotated struct would be MainActor-isolated, and the `nonisolated static` projection decision and the `TaskGroup` loader could not read its derived keys. This matches `HomeItemID`, `CachedHomeHub` and `PlexHub`.
- Derived keys: `id = "\(libraryUUID)/\(ratingKey)"`, `rowIdentifier = "rivulet.pin.collection.\(ratingKey)"`, `childrenKey = "/library/collections/\(ratingKey)/children"`.
- Storage: a JSON array under `homeCollectionPins`, suffixed `_user_{selectedPlexUserId}` the way `hiddenKey` is.
- API: `pins`, `isPinned(ratingKey:libraryUUID:)`, `pin(_:)`, `unpin(ratingKey:libraryUUID:)`, `updateTitles(from:libraryUUID:)` (§5.3), and its own `changedNotification`.
- Rescope two comments that state the never-adds rule: `HomeRowSettings`' header ("can never invent") and gate 1 of `PlexDataStore.librariesPinnedToHome`'s doc ("see `HomeRowSettings` for the same rule at row granularity"). The hide list still subtracts only, and local pins are the one user-created exception. Pins never add a library, so gate 1's own rule stands.

*Why library uuid.* `PlexAuthManager.selectedServer`, and with it the machine id, is nil after a warm launch that restores only URL and token. `PlexLibrary.uuid` is non-optional. Matching on uuid scopes pins to the current server and leaves pins for a deleted or unshared library inert.

*Data.* `PlexDataStore` gets `private var pinnedCollectionItems: [String: [PlexMetadata]]`, keyed by `Pin.id`. `nil` means not fetched this session; `[]` means fetched and empty. `onProfileSwitched` and the reset path clear it next to `libraryHubs.removeAll()`.

*Loader* `loadPinnedCollections(serverURL:token:)`:
- Takes only pins whose `libraryUUID` matches a video library in `librariesPinnedToHome`. This filter is load-bearing. Without it, one server's pins are requested against another server, get a 404, and are pruned.
- Fetches in parallel (`TaskGroup`) with `getHubItems(hubKey: pin.childrenKey, start: 0, count: 24)`.
- Success writes the items. `PlexAPIError.httpError(404, _)` unpins silently: PMS answers 404 for a deleted collection and for one the profile can no longer see (§4), so the pin could never render again. Any other error keeps the last-known items. A collection that empties answers 200 with no items; the pin stays, costs one small request per load, and renders nothing until it refills.
- Called from `loadLibraryHubsIfNeeded`'s task after its final `projectAllLoadedItems()`, in its own `Task`: `loadPinnedCollections`, then `projectHomeItems()`. The existing projection, which paints Home's promoted rows and every library page, never waits on a pin fetch (up to the 30s request timeout), and neither do callers awaiting the load task. That one site covers launch, the #315 content-added poll and `refreshLibraryHubs`.
- An observer for `HomeCollectionPins.changedNotification` calls `projectHomeItems()` right away, so an unpin vanishes at once, then the loader, then `projectHomeItems()` again. The existing `HomeRowSettings` observer stays projection-only, so hide toggles never fetch.

*Projection.* Inside `projectHomeItems`' loop over `librariesPinnedToHome`, after that library's promoted hubs, handle each of the library's pins in pin order:
- **P1 wins:** skip the pin when a promoted hub's `key == pin.childrenKey`.
- **Loaded, non-empty:** append `makeCachedHub(id: "hub:\(pin.rowIdentifier)", title: pin.title, isContinueWatching: false, hubKey: pin.childrenKey, hubIdentifier: pin.rowIdentifier, metas:)`.
- **Not fetched yet:** carry over the row already in `homeItems` with that id. `projectHomeItems` runs from the CW poll before the loader finishes, and `setHomeItems` re-persists whatever it gets. Without the carry-over, one early projection would wipe the pin from the warm-launch cache (the #236 trap).
- **Fetched, empty:** omit the row.

This decision is a `nonisolated static` over plain values, like `shouldCarryOverRecentlyAddedRow`, so it can be tested. The row identifier never matches `isContinueWatchingFamily`. Pins appear in Settings > Home Rows only as Unpin actions, never as hide toggles (§8), so the decision has no hidden branch.

A pin whose collection has emptied is omitted from Home, and its tile is gone from the library row and grid (the `childCount > 0` filter), so the tile menu cannot reach its Unpin. Settings > Home Rows still lists it (§8). Keeping it is correct for a collection that refills (a smart "Newly Released").

*Tile menu.* In library mode, the `.collection` branch of `tileMenuSections` returns `[[Pin to Home]]` or `[[Unpin from Home]]`. The library comes from `mode`, since a `MediaItem` carries no section id: `dataStore.libraries.first { $0.key == key }?.uuid`. The branch returns `[]` when:
- the library is not pinned to Home (there is no block to render into), or
- `dataStore.libraryHubs[key]` already holds a promoted hub whose key is the collection's children key (Plex already puts it on Home).

The choice is a `nonisolated static func collectionPinAction(isLibraryPinned: Bool, promotedChildrenKeys: Set<String>, childrenKey: String, isPinned: Bool) -> PinAction?` (`.pin`, `.unpin`, or nil for no menu), so a wrong result, which would hide Unpin or offer a Pin that never renders, is caught by a test (§9).

`presentTileMenu` ignores empty sections. The branch covers the Collections row (`presentShelfTileMenu`) and the Collections grid (`handleGridLongPress`). Outside library mode a collection gets `[]`.

### 5.6 Detail "In this collection" row

**Split.** `PlexProvider.related(for:kind:)` calls `getRelatedItems` once and splits the hubs with a pure `nonisolated static` that takes the hubs, the current ratingKey and the kind:
- The collection hub is the first hub whose `hubIdentifier` starts with `collection.related.` **and** whose `type` equals `kind.rawValue`, for `.movie` ("movie") and `.show` ("show") only. Any other kind gets no collection hub. The type check stops UNTAMED's movie hub from reaching a show.
- Every other `collection.related.*` hub is dropped.
- The current ratingKey is removed from the members.
- The remaining hubs are flattened, deduped and capped at 12 as Related, as today.
- When the collection hub has `more == true`, the static also returns the `tagId`, parsed from the hub's `key` (`/library/sections/1/all?type=1&tagId=61303&...`) with `URLComponents`. `related(for:kind:)` then calls `getCollection(tagId:)` and maps the result through `PlexMediaMapper.item` to a `.collection` item for the trailing tile. Without `more`, the row already holds every member, so there is no tile and no request. If the lookup fails, the row shows without the trailing tile.

The split fixes two live defects. Today a movie appears in its own Related row, and a 12-member collection hub fills Related completely (Raiders).

**Loader.** `BelowFoldContentLoader`: `BelowFoldContent` gains `collection: CollectionRow?`, filled from the same `related(for: item.ref, kind: item.kind)` call. Delete the stale header comment that says collection items are intentionally omitted.

**View.** `BelowFoldCollectionView`:
- A `.collection` section kind and a `.collectionShelf` item, mirroring `.related` and `.relatedShelf`.
- Layout: `case .related, .collection:` share `homeShelfHostSection`, `relatedLift` included, because a movie with no trailers or extras makes this row the primary peek row.
- Cells: pull the `.relatedShelf` body into one helper (items, header title, optional trailing item, onSelect) used by both shelves, so they cannot drift. The trailing tile is `PosterCell.configure(item:)` with the collection item. `.collection` joins the empty-header group.
- `ingest` and `ingestEpisodesOnly` store and clear the collection next to the related items.
- **Watch state.** `refreshWatchState` re-fetches only episodes today (`eps = []` for a movie, and it returns), and the carousel's hero refresh goes through `updateItemInPlace`, which does not rebuild the below-fold. So a member watched from the row would keep its old glyph: Diamonds Are Forever, Goldfinger tile, play to the end, Menu twice, and Goldfinger still shows unwatched. For `.movie` and `.show` items, `refreshWatchState` also re-runs `provider.related(for:kind:)` under the same refresh and load tokens, swaps the fresh members and Related items into their stores, and re-configures the two shelf host cells with a content token hashed from ratingKey plus watch state. `ShelfRowCell.configure` then reloads the visible row under a cross-dissolve, the path Home's rows already take for an advanced progress bar, and a token that did not move changes nothing. Related gets the same repaint, which also closes its existing gap.
- `applySnapshot` order: Trailers, Extras, **Collection**, Related, Cast, About, Info.
- The header is Plex's hub title ("James Bond Collection").

**Selection.** Every tile, members and the trailing collection tile alike, calls `onShowRelatedDetails`, which leads to `presentStandaloneDetail`. A member opens the standalone detail. The collection tile hits `openCollectionIfNeeded`. `ExpandedDetailContainerView` gets no new callback.

**Required fix.** `restoreShelfRowFocusIfNeeded` picks `visibleCells.first` with a non-nil `lastFocusedItemIndex`. `ShelfRowCell` clears that value only in `prepareForReuse`, so with two shelf rows the wrong row can win. Resolve the row from `FocusScrollControlledCollectionView.lastFocusedIndexPath` through `cellForItem(at:) as? ShelfRowCell`.

**Shows.** The type match picks the show-typed hub. The kind check limits the row to movies and shows, and episodes and seasons carry no Collection tags anyway. §12 keeps it on show pages by default.

## 6. Data flow

```
Library page (HomeMode.library)
  refreshThisLibraryHubs
    ├─ getLibraryHubs ──────────────► libraryHubs[key] → projectLibraryItems → hub rows
    └─ getLibraryItemsWithTotal(type:18) → filter childCount>0 → libraryCollections
          ├─► Collections row (.hub, spliced after CW + recent rows)
          └─► Titles/Collections switch → gridItems = libraryCollections

Tap on a .collection tile (row, grid, detail trailing tile)
  presentPreview / presentStandaloneDetail
    └─ openCollectionIfNeeded → present PHVC(mode: .collection(item)) .overFullScreen
          └─ loadGridPage → getHubItems("/library/collections/{rk}/children", Start+Size)
                              → gridItems (sparse, sized from totalSize)

Home (P1 + P2)
  loadLibraryHubsIfNeeded (launch, #315 poll, refreshLibraryHubs)
    ├─ getLibraryHubs per pinned library → promoted hubs (P1 collection hubs included)
    └─ then, in its own Task: loadPinnedCollections → getHubItems(childrenKey, 0, 24)
         → pinnedCollectionItems → projectHomeItems
  projectHomeItems: per library block → promoted hubs, then pins (P1 dedupe,
                    carry-over) → setHomeItems
  Tile menu Pin/Unpin → HomeCollectionPins → changedNotification → project, load, project

Detail
  BelowFoldContentLoader → provider.related(for:kind:) → getRelatedItems (hubs)
    → split: collection hub (type match, minus self) + Related (flatten, cap 12)
    → getCollection(tagId:) for the trailing tile, only when the hub has more
```

## 7. Error, empty and stale states

| Surface | Case | Behaviour |
|---|---|---|
| Collection page | Page 0 in flight | Loading state. Focus sits on the zero-size anchor (§5.2), so Menu dismisses the page and arrows and Select reach nothing underneath. |
| | Page 0 fails | Page dropped from `gridPagesRequested`; `pageZero = .failed`; error state with Try Again, which resets `pageZero` to `.loading` and reloads page 0. |
| | No children (smart Popular: `childCount` 16, 0 returned; migration orphans) | "This collection is empty." with its focusable action. |
| | Later page fails | Slots stay placeholders; scrolling back retries (existing). |
| | Watch state changes | Playback and detail changes post `.plexDataNeedsRefresh`, and a member's tile-menu change runs through `performMenuAction`; both call `reloadLoadedGridPages()`. |
| Library row | Fetch fails | Previous list kept; no error surfaced; hub rows unaffected. |
| | No non-empty collections | No row, no switch. |
| | Collection added mid-session | Appears on the next `refreshThisLibraryHubs`; the focused tile stays put if the row is new (§5.3). |
| Switch | List refreshed while on | Equal list: nothing. Changed list: grid refilled in place, or held while focus is in the grid or a collection page is open. A list that empties returns to Titles. |
| | Collections to Titles | Grid empty until titles page 0 arrives, the same gap `applySort` has today. |
| P2 pins | Not fetched yet | Cached row carried over. |
| | 404 | Pin removed silently. PMS answers 404 for a deleted collection and for one the profile can no longer see (§4). |
| | Other error | Last-known items kept. |
| | Empty children | Row omitted; pin kept and still listed in Settings > Home Rows, where it can be unpinned (§8). |
| | Library deleted, unshared, or on another server | Pin inert; never fetched or pruned. |
| | Profile switch | Items cleared; pins read from the new profile's key. |
| P1 and P2 rows | Kometa changes membership without adding library items | The #315 recentlyAdded stamp does not move. Rows refresh on `.plexDataNeedsRefresh` or relaunch. Accepted. |
| Detail | `/related` fails | No Collection or Related row (today's behaviour). |
| | Collection lookup fails | Row shows without the trailing tile. |
| | Collection of 12 or fewer (`more` unset) | Row shows every member, no trailing tile, no lookup. |
| | Watch state changes | `refreshWatchState` re-runs `related(for:kind:)` and repaints the Collection and Related rows in place (§5.6). |
| | No collection hub | No row. |
| Artwork | Composite of an empty collection | 404, `PosterCell` placeholder. Only orphans reach a tile, given the filter. |

## 8. Settings rows

- **No new toggle.** The Collections row, the switch and pins have no on/off setting. If one is wanted later, add `toggle("collectionsRow", "Collections Row", key: "showLibraryCollections", default: true)` to the Library block of `SettingsPageModels`, a `"collectionsRow"` descriptor in `SettingsDescriptors`, and a reader in `computeLibrarySections` next to `showLibraryRecentRows`.
- **Stored keys.** These have no settings row.
  - `homeCollectionPins` / `homeCollectionPins_user_{id}`: written by the tile menu and by `updateTitles`; read by `HomeCollectionPins`, `PlexDataStore.loadPinnedCollections`, `projectHomeItems`, `tileMenuSections` and `SettingsPageModels.homeRows`.
- **Settings > Home Rows** (`SettingsPageModels.homeRows`), user-decided: pins are listed, each with an Unpin action.
  - The toggle list drops identifiers with the `rivulet.pin.` prefix in its `visible.compactMap`, so a pin never appears as a hide toggle. A pin has no "pinned but hidden" state, and `HomeRowSettings` never sees its identifier.
  - After the toggles: `.header("Pinned Collections")`, then one row per pin whose `libraryUUID` matches a library in `store.libraries` (the current server), in pin order: `SettingsRowItem(id: "pinnedCollection_\(pin.id)", title: pin.title, kind: .action(destructive: true, handler: { vc in HomeCollectionPins.unpin(ratingKey: pin.ratingKey, libraryUUID: pin.libraryUUID); (vc as? SettingsPageViewController)?.reloadRows() }))`. The group is omitted when there are no such pins.
  - Listing every pin on the current server, not only the rows Home draws, is what makes an emptied pin and a pin whose library was later removed from Home reachable.
  - Descriptor: `SettingsDescriptors` maps the `pinnedCollection_` prefix to one `"pinnedCollection"` descriptor, the way `homeRow_` maps to `homeRowItem`. Copy: "A collection you pinned to Home from its tile menu. Select to unpin it." Rows stay title-only.
  - The `homeRows`, `showAllHomeRows` and `homeRowItem` descriptors and the page's "one toggle per row Plex currently offers Home" comment stay true: the toggles still cover only Plex rows. Show All does not touch pins.

## 9. Testing

**Unit tests (RivuletTests; new files join the target automatically)**
1. `PlexMediaMapper.artworkURL`: a path with a query yields exactly one `?` and ends in `&X-Plex-Token=...`. A path without a query is unchanged.
2. Related split (the `PlexProvider` static):
   - Fixture hubs mirror the measured Raiders response: `collection.related.1.1` (movie, `more` true, contains the current key), `collection.related.2.2` (show), `movie.same.director`, `movie.same.actor.0`.
   - Expected: the collection is 1.1 minus the current key, Related excludes both collection hubs, and `tagId` parses to 61303.
   - A second case: a show item picks the show-typed hub.
   - A third case: an episode or season kind gets no collection hub.
   - `more` unset: no `tagId` is parsed and no lookup is planned.
3. Collections row index (the `computeLibrarySections` static), over rows given as (isCW, isRecent):
   - `[CW, recent, recent, genre]` gives 3.
   - `[genre]` gives 0.
   - `[CW, recent]` gives 2.
   - `[]` gives 0.
   - `[genre, CW, recent]` gives 3.
   - `[custom.collection, CW, recent, genre]` gives 3.
4. Pin row decision (the `PlexDataStore` static), beside `HomePromotedHubRowsTests.swift`:
   - P1 duplicate: omit.
   - Loaded and non-empty: render.
   - Not fetched: carry over.
   - Fetched and empty: omit.
5. Update `StubMediaProvider` in `HomeComposerTests.swift` to `related(for:kind:)`, or the target stops compiling.
6. `PlexNetworkManager.hubItemsURL` (the `nonisolated static` from §5.1):
   - `/library/sections/1/all?sort=addedAt:desc` at start 24 keeps `sort=addedAt:desc` and adds Start and Size.
   - `/library/collections/9144/children` gains only Start and Size.
   - `/hubs/items` with an identifier adds `identifier`. Without one the builder returns nil, and `getHubItems` keeps today's empty result for that case.
7. Collection pin action (`collectionPinAction`): library not pinned gives nil; promoted children key gives nil; otherwise `isPinned` picks `.unpin` or `.pin`.

The network call inside `getHubItems` stays device-checked, because `PlexNetworkManager.shared` has no injectable session. The URL it builds is covered by test 6.

**Device verification.** The Simulator does not reproduce the tvOS focus engine faithfully (CLAUDE.md), so any focus or Menu result from it is provisional.
- Collection page:
  - It opens from the library row, the Collections grid and the detail trailing tile.
  - Menu dismisses it from any tile.
  - During the loading window: Menu dismisses the page, the library underneath keeps its scroll position (no return to its hero), and the sidebar does not expand (the `cfb44f1` class). Down and Select move nothing and open nothing underneath.
  - Focus enters the grid when page 0 arrives after the transition.
  - Focus returns to the tapped library tile.
  - Returning to a detail page from its trailing collection tile restores focus to that tile, with the row still scrolled to its end.
  - From a collection page, open a member, then that member's trailing tile for the same collection: the stack unwinds to the existing page instead of adding a second one.
- Paging:
  - Action Movies (416) pages past slot 60.
  - The P1 James Bond row and a large pinned row page past 48.
  - Recently Added and a genre row page in their own sort and filter past 48, and a TV Recently Released Episodes row keeps paging episodes. Continue Watching paging is unchanged. This is the regression check for the `getHubItems` fix.
- Library row:
  - Focused on a genre row before the refresh completes, the focused tile stays in place when the Collections row appears.
  - With a hub moved above Continue Watching in Plex's Manage Recommendations, the row still follows CW and Recently Added.
- Switch:
  - It toggles both ways and focus stays on it. Down enters the grid.
  - With the hero and Discovery Rows off, so the header is on screen at load, the switch appears when the list arrives.
  - The sort button and the A-Z bar are gone in Collections state.
  - Remembered-path check: focus titles slot ~500, toggle to Collections, press Menu to the sidebar, press Right back in.
- Pins:
  - Pin: the row appears in the library's Home block. Unpin: it disappears at once.
  - A warm relaunch keeps the row.
  - The pin is listed under Pinned Collections in Settings > Home Rows, not among the toggles. Select unpins it, the entry leaves the list, and the Home row is gone on return.
  - A collection promoted in Plex offers no Pin action.
- Artwork: Cinderella, The Hobbit and Marvel Studios show their composite posters.
- Detail:
  - Diamonds Are Forever shows the Bond row in release order, without itself.
  - Raiders now shows the Spielberg and Harrison Ford rows.
  - The trailing tile opens the page. A collection of 12 or fewer shows no trailing tile.
  - Watch a member from the row to the end and return: its glyph updates without leaving the page.
- Build both schemes. `build-ios.yml` runs on the RivuletCore changes, and the `getRelatedItems` signature change must compile for iOS. Run `swiftlint lint --strict`.

## 10. Rollout order

Each step ships on its own. Each user-facing step gets one bullet in `WhatsNewView.changelogs`, keyed `"<version> (<build>)"` from the real release tag.

| Step | Contents | Depends on | Changelog |
|---|---|---|---|
| 0a | `artworkURL` separator fix + test | nothing | none on its own; folded into step 2 |
| 0b | `getHubItems` returns `totalSize ?? size` and keeps the hub key's query; `hubItemsURL` static + test | nothing | "Long rows on Home, including collections from Plex, now keep loading as you scroll." |
| 1 | Collection page with its focus anchor and `pageZero` state, `openCollectionIfNeeded` in both funnels (same-page guard, carousel pre-present arm), `reloadLoadedGridPages` from `performMenuAction`, collection tile menu returns `[]` | 0b (grid sizing reads `totalSize`) | "Collections now open to a page of their titles." |
| 2 | Library Collections row | 1, 0a | "Movie and TV libraries show a Collections row." |
| 3 | Titles / Collections switch | 1, 2 (shared list) | "Switch a library's grid between titles and collections." |
| 4 | P2 pins: store, loader, projection, tile menu, the Pinned Collections group in Settings > Home Rows, pin-title refresh | 0b, 2 or 3 (entry point) | "Pin a collection to Home from its tile menu." |
| 5 | Detail row, related split with `kind`, `getCollection` gated on `more`, watch-state repaint, `restoreShelfRowFocusIfNeeded` fix | 1 for the trailing tile only | "Movie pages show the rest of the movie's collection." |

Step 4's prerequisite measurement is done (§4): 404 means deleted or no longer visible, so the unpin rule in §5.5 stands.

Steps 0b and 5 edit `RivuletCore/Plex/PlexNetworkManager.swift`, which carries uncommitted Live TV hunks from another session. Stage by hunk (`git add -p`) and commit the index. A pathspec commit takes the whole working-tree file.

## 11. Risks

- **`getHubItems` fix changes every paginated row.** Rows that stop after two pages today will page to their true filtered total, which for Recently Added is the whole library in added order (§12 default). Keeping the key's query is what stops them paging the unfiltered library in title order (§4). `PlexHomeViewController` is the most-fixed UIKit browse surface (19 fixes). Re-test Continue Watching: its `/items` endpoint returned size 0 and `totalSize` 9 at offset 24. Moderate-high confidence that today's behaviour is a bug.
- **Loading-window focus.** While page 0 is in flight the grid is hidden. Without the anchor (§5.2), focus would stay on the library tile, and the first misfire would be the library's own staged back: it is still registered, is asked before the shell, and would swallow Menu with `returnToTopRow()` under the modal; the next Menu would expand the covered sidebar. The anchor is built in step 1. Its behaviour is unverified on device, so §9 checks Menu, Down and Select during loading.
- **Return-to-tile focus** depends on the tapped view surviving. A hub refresh while the page is up can re-vend the tile. The `pendingPreviewRestore` escalation in §5.2 fixes it. The Collections grid does not swap under an open page (§5.4).
- **Below-fold restore is new ground.** `restoreBelowFoldFocusAfterReturn` has never fired before this spec (§5.2). The pre-present arm is reasoned from the code, not observed; §9 checks it.
- **`.overFullScreen`** keeps the library compositing under the opaque page. That is acceptable for a modal and matches every other drill-in.
- **Remembered focus path after a swap.** It is unverified whether turning `remembersLastFocusedIndexPath` off clears a stored path that names a titles slot beyond the collection count. Device check in §9.
- **Migration-orphaned smart collections** (4 movie, 4 TV on this server) pass the `childCount` filter, show a 404 composite, and open to an empty page. §12 default: delete them in Plex, no code.
- **`/related` is undocumented.** One collection hub per section is high confidence. The pick rule is moderate. The `index` lookup is empirical on 1.43.4, and the row degrades to no trailing tile when it fails.
- **Kometa lists become "the collection"** for many titles (IMDb Top 250, IMDb Popular), which fills the row with unrelated films.
- **Related changes visibly.** Collection members and the cross-type collection hub leave it, so Related gets shorter or different for many titles. Intended.
- **No warm-launch cache for the library row.** It appears when the refresh completes. The focused-cell offset correction in §5.3 keeps a tile below it from being pushed off screen.
- **Library VCs are cached per tab and survive a profile switch.** `libraryCollections`, like `gridItems`, reflects the previous profile until the next refresh. This matters only for label-restricted managed users.
- **A late pin fetch after a profile switch** can arrive after the clear. It is harmless unless the new profile pinned the same collection. Add a generation check only if seen.
- **Collection list ceiling** of 1000 per library (§5.1).
- **Shared-file edits.** Two steps touch `PlexNetworkManager.swift` while it holds another session's uncommitted edits.

## 12. Open questions

None block the plan. The three questions from review were answered (§2): title-only header, pins listed in Settings > Home Rows with Unpin, no Pin action for a library not pinned to Home.

### Defaults taken (override in review if wrong)

- **Orphaned smart collections:** no code. The 8 on this server (Plex Popular, Popular, Top Rated, Oscars, and 4 in TV) are leftovers of a server migration; delete them in Plex. Revisit the machineIdentifier predicate only if other users report empty collection pages.
- **Detail row title:** Plex's hub title ("James Bond Collection").
- **Trailing collection tile on the detail row:** only when the hub reports `more` (over 12 members).
- **Current movie in its own collection row:** excluded.
- **Which collection:** Plex's pick, even when it is a Kometa list such as IMDb Top 250.
- **Shows:** the row also appears on show pages, since it costs no code.
- **Search:** collections stay filtered out.
- **`showLibraryCollections` toggle:** not added.
- **Order in Collections state:** server order only.
- **Collection tile actions:** Pin/Unpin only. The collection page itself has no Pin action; pin from the tile.
- **Dead below-fold code** (`BelowFoldItem.related(String)`, `RelatedPosterCell`, `relatedByID`, the `.related` branch of `didSelectItemAt`): deleted in step 5.
- **How far Recently Added pages:** to its true total in added order, on scroll only. Today it appends one page of the whole library in title order, so this is a fix.
