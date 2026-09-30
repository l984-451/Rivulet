# Plex Collections Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Rivulet open Plex collections: a collection page, a Collections row and a Titles / Collections grid switch in each Movie and TV library, collections pinned to Home, and a movie's collection row on its detail page.
**Architecture:** The collection page is `PlexHomeViewController` in a new `.collection` mode, presented modally with the blur fade and paged through `getHubItems`, which is fixed first to keep each hub key's own query and return the real total. A library page fetches its collection list once (`type=18`) and feeds both the Collections row and the grid switch; Home pins are a small per-profile store in `HomeRowSettings.swift` that `PlexDataStore` fetches and projects inside each library's Home block. The detail row comes from splitting the `/related` response the detail page already requests into a collection row and Related.
**Tech Stack:** Swift 6 (tvOS 26, default MainActor isolation), UIKit with diffable data sources and compositional layout, the Plex Media Server HTTP API (measured on PMS 1.43.4), XCTest, SwiftLint custom rules.
**Spec:** /Users/bain/git/Swift Projects/Rivulet/Docs/superpowers/specs/2026-09-30-plex-collections-design.md

## Global Constraints

- Platform: tvOS 26+, Swift 6. Target build setting SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor: any pure static, struct or enum that a test or a TaskGroup child touches off the main actor is declared `nonisolated`.
- UIKit only on primary surfaces; no SwiftUI added to PlexHomeViewController, MediaLibrarySortControl, BelowFoldCollectionView, Settings.
- RivuletCore/ (compiled into BOTH tvOS and iOS targets) never contains `#if os(...)` (lint rule platform_conditional_in_shared_code). Any RivuletCore change must build the `Rivulet iOS` scheme too.
- One Plex client: new endpoints go in RivuletCore/Plex/PlexNetworkManager.swift, never a second decoder elsewhere.
- Plex paging: X-Plex-Container-Size is ignored unless X-Plex-Container-Start is sent with it.
- New PlexMetadata fields for collections must be `String?` (smart and minYear/maxYear are strings on the wire; an Int? declaration throws and loses the whole container). This plan adds none.
- Never send stream or artwork URLs (they carry tokens) to Sentry or logs.
- Settings rows are title-only; descriptive copy goes in SettingsDescriptors; every stored key needs a reader.
- Prose and user-facing copy: no em dashes or en dashes anywhere (code comments included). Commit messages short and plain (public repo).
- Dash check, used by every task's lint step: `git diff -U0 -- <modified files> | grep '^+' | grep -nE $'\xe2\x80\x93|\xe2\x80\x94'` prints nothing (the pattern is spelled in bytes so this plan holds no dash characters). `git diff` never shows an untracked file, so a file the task creates is checked directly: `grep -nE $'\xe2\x80\x93|\xe2\x80\x94' <new file>` prints nothing.
- Mark deliberate ceilings with a `// ponytail:` comment naming the ceiling and the upgrade path.
- Tests: XCTest, `import XCTest` + `@testable import Rivulet`, `final class FooTests: XCTestCase`, placed under RivuletTests/Unit/<Area>/ (the group is synchronized; new files join the target with no project edit). The Home and library surface tests live at the RivuletTests/Unit root today, beside `HomePromotedHubRowsTests.swift`, so this plan puts its Home and library tests there and its network and provider tests under `Unit/Services/`. Under Xcode 27 a test that names a type Foundation now also exports (e.g. ProgressReporter) must qualify it as `Rivulet.ProgressReporter`. print() from a tvOS test never reaches the console.
- The synchronized test group also compiles another session's untracked Live TV tests (`LiveAVCaptureTests.swift`, `LiveTunerBusyTests.swift` on 2026-09-30). A build failure in a file this plan does not touch is their work in progress: report it, do not edit it.
- Build and test commands always use a scratch derived data path, because Xcode and other sessions share the default one: `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/<Class>[/<method>]`; builds: `xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd"` and `xcodebuild build -scheme 'Rivulet iOS' -destination 'generic/platform=iOS Simulator' -derivedDataPath "$SCRATCH/dd-ios"`; lint: `swiftlint lint --strict`.
- Every shell call starts with `cd "/Users/bain/git/Swift Projects/Rivulet" && export SCRATCH=<absolute path of your session scratchpad> &&`, including the blocks below that omit it. Shell variables do not carry over between Bash calls, and an unset `SCRATCH` turns `"$SCRATCH/dd"` into `/dd` on the read-only root volume: the build then fails before any test runs, which a Step 2 can mistake for its expected red. Commit gates name the branch literally: this plan runs on `test/integration`, where the user asked for these commits.
- Simulator focus behaviour is provisional; every focus or Menu change carries explicit device verification steps.
- Shared checkout: other sessions edit this working tree concurrently. Commit step, every task: `git add <exact files>` then `[ "$(git branch --show-current)" = test/integration ] && [ "$(git diff --cached --name-only | sort)" = "$(printf '%s\n' <exact files> | sort)" ] && git commit -m "<message>"`. Never `git commit -- <path>` (it commits the working tree, sweeping other sessions' edits), never a bare commit without the equality check, never checkout/reset/stash. If a file you edit also has another session's uncommitted hunks (check `git diff <file>` before editing; RivuletCore/Plex/PlexNetworkManager.swift had some on 2026-09-30), land only your hunks: `git show HEAD:<path> > $SCRATCH/head.swift`, apply your edits to a copy, `diff -u` into a patch with a/ and b/ headers, `git apply --check --cached patch`, `git apply --cached patch`, then the gated commit.
- Release boundaries: Tasks 3 and 4 have no entry point until Task 5 adds the Collections row, and Task 9 alone removes the Related row from titles whose only `/related` hub is their collection, so never tag a release after Task 3 or 4 without Task 5, or after Task 9 without Task 10.
- Changelog: WhatsNewView.changelogs only, via the rivulet-changelog skill at tag time; keys come from the real release tag; never guess a build number.

## Review Focus

1. A member's watch state changes on the collection page (Mark as Watched from its tile menu, or played to the end and back): the tile's badge or progress repaints in place and focus stays on that tile. Pinned by Task 3, Step 6, check 5.
2. A large collection page (Action Movies, 416 members): Down past slot 60 and a 3 second held Down fill every slot in the collection's own order, show no system index dots, and land focus on a tile on release. Pinned by Task 3, Step 6, check 6, plus the two index-bar lines Task 3, Step 3g adds.
3. Menu or Select pressed during the blur-fade in (focus can still sit on the library tile until the transition ends, and on the LAN page 0 arrives mid-transition): Menu dismisses the page or does nothing, the library underneath never jumps to its top row, the sidebar never expands, and Select opens nothing under the page. Pinned by Task 4, Step 3h (the page registers its Menu handler in `viewWillAppear` and drops Menu until `viewDidAppear`) and Step 6, check 6i.
4. A large pinned collection on Home (Action Movies pinned, held Right past tile 48): the row keeps loading in the collection's own order up to its total. Pinned by Task 8, Step 6, check 16.
5. A collection that shrinks while its page is open (a member removed in Plex, a Kometa run, a smart rule), with focus on a slot past the new count, then a reload: no crash, no blank slot, focus moves to a surviving tile and the grid matches the server. Pinned by Task 3, Step 3h (the clamped `end` in `loadGridPage`) and Step 6, checks 7 (one page) and 7b (a shrink past a loaded page's start, the crash case).

## Spec deviations

The plan departs from the spec in five places. Each was checked against the code or the live server, and the spec text has not been amended yet. Where the two disagree, follow the plan. Before tagging a release (Task 11), amend the spec so it matches:

1. **Collection lookup (Task 9).** Spec §2 lookup row, §4 tag fact, §5.1 `getCollection`, §5.6 and §6 say `getCollection(serverURL:authToken:tagId:)` on `/library/all?type=18&index={tagId}`. The plan uses `getCollection(serverURL:authToken:sectionId:tagId:)` on `/library/sections/{sid}/all?type=18&index={tagId}`, and `RelatedSplit` carries `sectionId`, because the section-free lookup returns both collections when Kometa made same-named movie and show collections sharing one tag (measurement in Task 9's header). Spec §9 test 2 should expect tagId 353397 with sectionId "1": Raiders' collection hub is IMDb Top 250, and 61303 is the James Bond tag, whose hub has no `more`.
2. **Same-page walk (Task 4).** Spec §5.2 walks `presentedViewController` up to the top, which can never reach a page below the presenter. The plan walks to the top and then back down through `presentingViewController`, and calls `dismiss` on the matching page only when something is presented over it.
3. **Pin titles (Task 7, Step 3.9).** Spec §5.3 calls `updateTitles` only when the ratingKey sequence changed. A rename keeps the ratingKey, so the plan calls it on every successful fetch; it writes nothing when no title differs.
4. **Pre-present arm (Task 4, Step 3g).** Spec §5.2 arms with `restoreShelfRowFocusIfNeeded()`. The plan arms with `restoreShelfRowFocusIfNeeded(requestingFocus: false)`: the plain call issues a focus request while the shelf still holds focus, and resolving it consumes the row's one-shot tile index before the page takes focus.
5. **Release boundaries (Global Constraints, Task 11).** Spec §10 says each step ships on its own. Steps 1 and 2 (Tasks 3 to 5) ship together, because nothing reaches a collection tile before the Collections row, and step 5 (Tasks 9 and 10) is atomic, because Task 9 alone drops the Related row for titles whose only `/related` hub is their collection.

## File Structure

Created:

| File | Responsibility | Tasks |
|---|---|---|
| `RivuletTests/Unit/HomeCollectionPageTests.swift` | Titled grid section uses the Watchlist header style | 3 |
| `RivuletTests/Unit/CollectionPageRoutingTests.swift` | `openCollectionIfNeeded` routing, presentation style, same-page guard (no second page stacked) | 4 |
| `RivuletTests/Unit/LibraryCollectionsRowTests.swift` | Collections row insertion index | 5 |
| `RivuletTests/Unit/CollectionsGridUpdateTests.swift` | What a refreshed collection list does to a collections grid | 6 |
| `RivuletTests/Unit/HomeCollectionPinsTests.swift` | Pin store persistence, per-profile keys, title refresh, pin row decision | 7 |
| `RivuletTests/Unit/CollectionPinActionTests.swift` | Pin / Unpin / no-menu choice, pin row descriptor | 8 |
| `RivuletTests/Unit/Services/PlexProviderRelatedTests.swift` | `/related` split and the trailing-tile lookup | 9 |

Modified:

| File | Responsibility | Tasks |
|---|---|---|
| `Rivulet/Services/MediaProvider/Plex/PlexMediaMapper.swift` | Artwork URL separator for paths with a query | 1 |
| `RivuletTests/Unit/PlexMediaMapperTests.swift` | Artwork URL tests | 1 |
| `RivuletCore/Plex/PlexNetworkManager.swift` | `hubItemsURL` + `getHubItems` total; raw `getRelatedItems` hubs; `getCollection` replaces `getCollectionItems` | 2, 9 |
| `RivuletTests/Unit/Services/PlexNetworkManagerURLTests.swift` | Hub page URL tests | 2 |
| `Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift` | `.collection` mode, routing, library Collections row, grid switch, pin title refresh, collection tile menu | 3, 4, 5, 6, 7, 8 |
| `Rivulet/Views/Media/PreviewCarousel/UIKit/PreviewCarouselViewController.swift` | Collection tiles from the detail open the collection page | 4 |
| `Rivulet/Views/Media/UIKit/Cells/ShelfRowCell.swift` | `armFocusRestore(on:)`, a tile arm with no focus request | 4 |
| `Rivulet/Views/Media/MediaDetail/UIKit/ExpandedDetailContainerView.swift` | `restoreShelfRowFocusIfNeeded(requestingFocus:)` pass-through | 4 |
| `Rivulet/Views/Media/Library/UIKit/MediaLibrarySortControl.swift` | Titles / Collections switch in the sort header | 6 |
| `Rivulet/Services/Plex/HomeRowSettings.swift` | `HomeCollectionPins` store | 7 |
| `Rivulet/Services/Plex/PlexDataStore.swift` | Pin loader, pin rows in `projectHomeItems`, `pinRowDecision` | 7 |
| `Rivulet/Views/Settings/UIKit/SettingsPageModels.swift` | Pinned Collections group in Home Rows | 8 |
| `Rivulet/Views/Settings/SettingsDescriptors.swift` | Pin row descriptor | 8 |
| `Rivulet/Services/MediaProvider/MediaProvider.swift` | `related(for:kind:)`, `RelatedContent`, `CollectionRow` | 9 |
| `Rivulet/Services/MediaProvider/Plex/PlexProvider.swift` | `related(for:kind:)`, `RelatedSplit`, `splitRelated` | 9 |
| `Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldContentLoader.swift` | Collection row from the same related call | 9, 10 |
| `RivuletTests/Unit/HomeComposerTests.swift` | `StubMediaProvider.related(for:kind:)` | 9, 10 |
| `Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldCollectionView.swift` | `restoreShelfRowFocusIfNeeded(requestingFocus:)` (4); collection shelf, shared shelf helper, watch-state repaint, restore fix (10) | 4, 10 |
| `Rivulet/Views/Media/MediaDetail/UIKit/Cells/BelowFoldCells.swift` | Delete dead `RelatedPosterCell` | 10 |
| `RivuletTests/Unit/BelowFoldContentLoaderTests.swift` | Loader fills the collection row | 10 |
| `Rivulet/Views/Components/WhatsNewView.swift` | Changelog bullets at tag time | 11 |

---

### Task 1: artworkURL separator fix

Spec §5.1 (artworkURL bullet), §9 test 1, §10 step 0a. There is no changelog line for this task on its own. §10 folds it into step 2.

Measured on PMS 1.43.4 (2026-09-30) with Cinderella's composite poster `/library/collections/63794/composite/1581446773?width=400&height=600`:
- Today's URL has two `?`, so the token ends up inside `height`, and PMS answered **401 text/html**.
- With `&` as the separator it answered **200 image/jpeg** (39,380 bytes).
- Bond's custom poster `/library/metadata/9144/thumb/1790714299` has no query and answered 200 either way.

**Files:**
- Modify: `Rivulet/Services/MediaProvider/Plex/PlexMediaMapper.swift` (`artworkURL(_:serverURL:authToken:)`, ~line 77)
- Test: `RivuletTests/Unit/PlexMediaMapperTests.swift` (existing file; add a `// MARK: - Artwork` section at the end)

**Interfaces:**
- Consumes: nothing.
- Produces: `PlexMediaMapper.artworkURL(_ path: String?, serverURL: String, authToken: String) -> URL?`. The signature does not change. The separator becomes `path.contains("?") ? "&" : "?"`.

- [ ] **Step 0: Check for other sessions' edits in the files.** Run `git diff --stat Rivulet/Services/MediaProvider/Plex/PlexMediaMapper.swift RivuletTests/Unit/PlexMediaMapperTests.swift`. Both files were clean on 2026-09-30, so expect no output. If either file has hunks you did not write, Step 7 has to use the patch-from-HEAD procedure (Task 2, Steps 3.0 and 7) for that file.

- [ ] **Step 1: Write the failing test.** Edit `RivuletTests/Unit/PlexMediaMapperTests.swift`.

Find:
```swift
    func test_userState_episodeWatched_isPlayed() {
        var meta = PlexMetadata()
        meta.type = "episode"
        meta.viewCount = 1
        XCTAssertTrue(PlexMediaMapper.userState(meta).isPlayed)
    }
}
```
Replace with:
```swift
    func test_userState_episodeWatched_isPlayed() {
        var meta = PlexMetadata()
        meta.type = "episode"
        meta.viewCount = 1
        XCTAssertTrue(PlexMediaMapper.userState(meta).isPlayed)
    }

    // MARK: - Artwork

    /// A collection with no custom poster carries a composite thumb with its
    /// own query. Measured on PMS 1.43.4: with a second '?' the token lands
    /// inside `height` and the server answers 401; with '&' it answers 200.
    func test_artworkURL_pathWithQuery_appendsTokenWithAmpersand() {
        let url = PlexMediaMapper.artworkURL(
            "/library/collections/63794/composite/1581446773?width=400&height=600",
            serverURL: "https://example.plex.direct:32400",
            authToken: "TOK"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://example.plex.direct:32400/library/collections/63794/composite/1581446773?width=400&height=600&X-Plex-Token=TOK"
        )
        XCTAssertEqual(url?.absoluteString.filter { $0 == "?" }.count, 1)
    }

    func test_artworkURL_pathWithoutQuery_isUnchanged() {
        let url = PlexMediaMapper.artworkURL(
            "/library/metadata/9144/thumb/1790714299",
            serverURL: "https://example.plex.direct:32400",
            authToken: "TOK"
        )
        XCTAssertEqual(
            url?.absoluteString,
            "https://example.plex.direct:32400/library/metadata/9144/thumb/1790714299?X-Plex-Token=TOK"
        )
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails.**
```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/PlexMediaMapperTests
```
Expected result: `** TEST FAILED **`, and only `test_artworkURL_pathWithQuery_appendsTokenWithAmpersand` fails, with two assertion failures:
```
XCTAssertEqual failed: ("Optional("https://example.plex.direct:32400/library/collections/63794/composite/1581446773?width=400&height=600?X-Plex-Token=TOK")") is not equal to ("Optional("https://example.plex.direct:32400/library/collections/63794/composite/1581446773?width=400&height=600&X-Plex-Token=TOK")")
XCTAssertEqual failed: ("Optional(2)") is not equal to ("Optional(1)")
```
`test_artworkURL_pathWithoutQuery_isUnchanged` passes already. It is the regression guard for paths that have no query.

- [ ] **Step 3: Implement.** Edit `Rivulet/Services/MediaProvider/Plex/PlexMediaMapper.swift`.

Find:
```swift
        return URL(string: "\(serverURL)\(path)?X-Plex-Token=\(authToken)")
```
Replace with:
```swift
        // A collection's composite poster carries its own query
        // (`/library/collections/{rk}/composite/{ts}?width=400&height=600`).
        // A second '?' folds the token into `height` and PMS answers 401.
        let separator = path.contains("?") ? "&" : "?"
        return URL(string: "\(serverURL)\(path)\(separator)X-Plex-Token=\(authToken)")
```
This is the pattern `PlexDataStore` (~1869) and `TopShelfMapper` (~83) already use.

- [ ] **Step 4: Run the test and confirm it passes.** Run the same command as Step 2. Expected result: `** TEST SUCCEEDED **`, with every test in `PlexMediaMapperTests` passing, including both new ones.

- [ ] **Step 5: Lint.** No RivuletCore file changed, and `PlexMediaMapper` is tvOS-only, so the tvOS build from Step 4 is enough and the iOS scheme is not needed.
```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && swiftlint lint --strict
# swiftlint is not installed on this Mac as of 2026-09-30; if missing:
cd "/Users/bain/git/Swift Projects/Rivulet" && docker run --rm -v "$PWD":/work -w /work ghcr.io/realm/swiftlint:0.65.0 lint --strict
```
Expected result: 0 violations.

- [ ] **Step 6: Device verification.** Not applicable. This task changes no UI and no focus, and nothing on screen reaches a composite path until the Collections row exists. The on-device check (Cinderella, The Hobbit and Marvel Studios show composite posters, spec §9 Artwork) runs in Task 5, Step 6, check 2.

- [ ] **Step 7: Commit.**
```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && git add Rivulet/Services/MediaProvider/Plex/PlexMediaMapper.swift RivuletTests/Unit/PlexMediaMapperTests.swift && [ "$(git branch --show-current)" = test/integration ] && [ "$(git diff --cached --name-only | sort)" = "$(printf '%s\n' Rivulet/Services/MediaProvider/Plex/PlexMediaMapper.swift RivuletTests/Unit/PlexMediaMapperTests.swift | sort)" ] && git commit -m "Fix artwork URLs whose path has a query"
```
If the equality check fails, stop. Other sessions have staged files. Do not unstage their work.

---

### Task 2: getHubItems keeps the hub query and returns totalSize

Spec §5.1 (the getHubItems bullets and the nonisolated static `hubItemsURL`), §9 test 6, §10 step 0b, §11 first risk. Both edits ship together. Returning `totalSize` without keeping the query would turn today's one wrong page into unbounded paging through the library in title order.

Measured on PMS 1.43.4 (2026-09-30) with real hub keys from `/hubs/sections/{1,2}?count=24`, requesting page 2 (Start=24, Size=24). "Replaced" is today's behaviour, where the key's query is dropped. "Kept" is this fix.

| Hub (identifier) | Key | Kept | Replaced (today) |
|---|---|---|---|
| movie.recentlyadded.1 | `/library/sections/1/all?sort=addedAt:desc` | totalSize 1016, added order | totalSize 1016, title order ("The Adventures of Huck Finn") |
| movie.genre.1.80 | `...?unwatched=1&genre=80&audienceRating>=7.0` | totalSize 61, filtered | totalSize 1016, whole library in title order |
| tv.recentlyaired.2 | `/library/sections/2/all?type=4&sort=originallyAvailableAt:desc` | totalSize 20770, episodes | totalSize 348, shows ("The Artful Dodger") |
| tv.recentlyadded.2 | `/hubs/home/recentlyAdded?type=2&sectionID=2` | totalSize 50 | size 0 (row dead after page 1) |
| tv.inprogress.2 | `/hubs/sections/2/continueWatching/items` | size 1, totalSize 25 | same |
| collection children | `/library/collections/9144/children` | totalSize 4 | same |

Other measurements:
- `audienceRating%3E=7.0`, the form URLComponents sends, returns the same 61 matches as the raw `>=`.
- Today the row stops at 48 because `loadMoreIfNeeded` stores the page `size` (24) as the total.

**Files:**
- Modify: `RivuletCore/Plex/PlexNetworkManager.swift` (new `nonisolated static func hubItemsURL`, rewritten head of `getHubItems`, the `totalSize` line; ~lines 939 to 999). **This file carries another session's uncommitted Live TV hunks** (on 2026-09-30: ~2369 in `tuneChannel`'s status check and ~3186 `PlexLiveTuneError`). Edit a HEAD copy and apply the result as a patch. Never commit the whole working-tree file.
- Test: `RivuletTests/Unit/Services/PlexNetworkManagerURLTests.swift` (existing file; add a `// MARK: - Hub Items URL Tests` section at the end)

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `nonisolated static func hubItemsURL(serverURL: String, hubKey: String, hubIdentifier: String?, start: Int, count: Int) -> URL?` on `PlexNetworkManager`.
  - `func getHubItems(serverURL: String, authToken: String, hubKey: String, hubIdentifier: String? = nil, start: Int = 0, count: Int = 24) async throws -> (items: [PlexMetadata], totalSize: Int?)`. The signature does not change. It now keeps the hub key's own query and returns `MediaContainer.totalSize ?? MediaContainer.size`.
  - The collection page (Task 3) and P2 pins (Task 7) page `/library/collections/{rk}/children` through this. `loadMoreIfNeeded` in `PlexHomeViewController` (~5370) needs no change.

- [ ] **Step 0: Check the other session's hunks.**
```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && git diff RivuletCore/Plex/PlexNetworkManager.swift | grep '^@@'
```
Expect hunks only outside roughly lines 930 to 1020. On 2026-09-30 they were `@@ -2369,16 +2369,17 @@` and `@@ -3185,6 +3186,19 @@`. If a hunk overlaps `getHubItems`, stop and ask the user. Also check that the test file is clean: `git diff --stat RivuletTests/Unit/Services/PlexNetworkManagerURLTests.swift` should print nothing.

- [ ] **Step 1: Write the failing test.** Edit `RivuletTests/Unit/Services/PlexNetworkManagerURLTests.swift`.

Find:
```swift
        XCTAssertNotNil(headers["X-Plex-Platform"])
        XCTAssertNotNil(headers["X-Plex-Device"])
    }
}
```
Replace with:
```swift
        XCTAssertNotNil(headers["X-Plex-Platform"])
        XCTAssertNotNil(headers["X-Plex-Device"])
    }

    // MARK: - Hub Items URL Tests

    // Hub keys are real ones from /hubs/sections/{1,2}?count=24 on PMS 1.43.4
    // (2026-09-30). The token travels in headers, so none appears here.

    private let pageStart = URLQueryItem(name: "X-Plex-Container-Start", value: "24")
    private let pageSize = URLQueryItem(name: "X-Plex-Container-Size", value: "24")

    private func hubQuery(_ url: URL?) -> [URLQueryItem]? {
        url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }
    }

    /// movie.recentlyadded.1. Dropping the key's query paged the whole
    /// library in title order ("The Adventures of Huck Finn" at slot 25).
    func testHubItemsURLKeepsHubKeySort() {
        let url = PlexNetworkManager.hubItemsURL(
            serverURL: testServerURL,
            hubKey: "/library/sections/1/all?sort=addedAt:desc",
            hubIdentifier: "movie.recentlyadded.1",
            start: 24,
            count: 24
        )
        XCTAssertEqual(url?.path, "/library/sections/1/all")
        XCTAssertEqual(hubQuery(url), [URLQueryItem(name: "sort", value: "addedAt:desc"), pageStart, pageSize])
    }

    /// movie.genre.1.80. The '>' goes out percent-encoded; PMS answers
    /// `audienceRating%3E=7.0` with the same 61 matches as the raw form.
    func testHubItemsURLKeepsHubKeyFilters() {
        let url = PlexNetworkManager.hubItemsURL(
            serverURL: testServerURL,
            hubKey: "/library/sections/1/all?unwatched=1&genre=80&audienceRating>=7.0",
            hubIdentifier: "movie.genre.1.80",
            start: 24,
            count: 24
        )
        XCTAssertEqual(hubQuery(url), [
            URLQueryItem(name: "unwatched", value: "1"),
            URLQueryItem(name: "genre", value: "80"),
            URLQueryItem(name: "audienceRating>", value: "7.0"),
            pageStart,
            pageSize
        ])
    }

    func testHubItemsURLCollectionChildrenGainsOnlyPaging() {
        let url = PlexNetworkManager.hubItemsURL(
            serverURL: testServerURL,
            hubKey: "/library/collections/9144/children",
            hubIdentifier: nil,
            start: 0,
            count: 24
        )
        XCTAssertEqual(url?.path, "/library/collections/9144/children")
        XCTAssertEqual(hubQuery(url), [
            URLQueryItem(name: "X-Plex-Container-Start", value: "0"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "24")
        ])
    }

    func testHubItemsURLHubsItemsAddsIdentifier() {
        let url = PlexNetworkManager.hubItemsURL(
            serverURL: testServerURL,
            hubKey: "/hubs/items",
            hubIdentifier: "home.movies.recent",
            start: 24,
            count: 24
        )
        XCTAssertEqual(url?.path, "/hubs/items")
        XCTAssertEqual(hubQuery(url), [pageStart, pageSize, URLQueryItem(name: "identifier", value: "home.movies.recent")])
    }

    /// Plex answers 404 without the identifier; getHubItems returns an empty
    /// page for nil, as it did before.
    func testHubItemsURLHubsItemsWithoutIdentifierIsNil() {
        XCTAssertNil(PlexNetworkManager.hubItemsURL(
            serverURL: testServerURL, hubKey: "/hubs/items", hubIdentifier: nil, start: 0, count: 24))
        XCTAssertNil(PlexNetworkManager.hubItemsURL(
            serverURL: testServerURL, hubKey: "/hubs/items", hubIdentifier: "", start: 0, count: 24))
    }
}
```

- [ ] **Step 2: Run the test and confirm it fails.**
```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/PlexNetworkManagerURLTests
```
Expected result: the test target fails to compile with `error: type 'PlexNetworkManager' has no member 'hubItemsURL'` (once per new test), then `** TEST FAILED **`.

Note: the build compiles the other session's uncommitted Live TV files as well. If it fails in a file this task did not touch (for example `LiveTunerBusy.swift` or `LiveTVAetherPlayerViewController.swift`), that is their work in progress. Report it and do not edit it.

- [ ] **Step 3.0: Make a HEAD copy to edit.** The edits go into a copy of the HEAD blob. The same patch is then applied to the working tree now and to the index at commit time, so the other session's hunks never get staged.
```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && git show HEAD:RivuletCore/Plex/PlexNetworkManager.swift > "$SCRATCH/head.swift" && cp "$SCRATCH/head.swift" "$SCRATCH/mine.swift"
```
Read `$SCRATCH/mine.swift` around lines 936 to 1000 before editing it.

- [ ] **Step 3a: Extract `hubItemsURL` and rewrite the head of `getHubItems`** in `$SCRATCH/mine.swift`.

Find:
```swift
    /// Get more items from a hub using its key (for pagination/infinite scroll)
    /// - Parameters:
    ///   - hubKey: The hub's key path (e.g., "/hubs/sections/1/continueWatching")
    ///   - hubIdentifier: The hub's identifier (e.g., "home.movies.recent") - required when hubKey is "/hubs/items"
    ///   - start: Starting index for pagination
    ///   - count: Number of items to fetch
    /// - Returns: Tuple of (items, totalSize) where totalSize indicates if more items exist
    func getHubItems(
        serverURL: String,
        authToken: String,
        hubKey: String,
        hubIdentifier: String? = nil,
        start: Int = 0,
        count: Int = 24
    ) async throws -> (items: [PlexMetadata], totalSize: Int?) {
        // The hubKey might be a full path like "/hubs/sections/1/continueWatching"
        // or just the section like "hub.movies.recentlyadded"
        let fullPath: String
        if hubKey.hasPrefix("/") {
            fullPath = "\(serverURL)\(hubKey)"
        } else {
            fullPath = "\(serverURL)/\(hubKey)"
        }

        guard var components = URLComponents(string: fullPath) else {
            throw PlexAPIError.invalidURL
        }

        var queryItems = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(count)")
        ]

        // The /hubs/items endpoint requires an identifier parameter to specify which hub
        // Without it, Plex returns 404. See: https://plexapi.dev/api-reference/hubs/get-a-hubs-items
        if hubKey == "/hubs/items" || hubKey.hasSuffix("/hubs/items") {
            if let identifier = hubIdentifier, !identifier.isEmpty {
                queryItems.append(URLQueryItem(name: "identifier", value: identifier))
            } else {
                // No identifier available - this request will fail, so skip it
                print("⚠️ PlexNetworkManager: Cannot paginate /hubs/items without hubIdentifier")
                return (items: [], totalSize: nil)
            }
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
```
Replace with:
```swift
    /// URL for one page of a hub.
    ///
    /// The hub key's own query is kept and the paging parameters are appended.
    /// Many keys ARE their row's definition (`movie.recentlyadded.1` is
    /// `/library/sections/1/all?sort=addedAt:desc`, a genre row carries
    /// `unwatched=1&genre=80&audienceRating>=7.0`), so replacing the query
    /// pages the whole library in title order instead.
    ///
    /// Returns nil for `/hubs/items` without an identifier (Plex answers 404)
    /// or a key URLComponents cannot parse.
    nonisolated static func hubItemsURL(
        serverURL: String,
        hubKey: String,
        hubIdentifier: String?,
        start: Int,
        count: Int
    ) -> URL? {
        // The hubKey might be a full path like "/hubs/sections/1/continueWatching"
        // or just the section like "hub.movies.recentlyadded"
        let fullPath = hubKey.hasPrefix("/") ? "\(serverURL)\(hubKey)" : "\(serverURL)/\(hubKey)"
        guard var components = URLComponents(string: fullPath) else { return nil }

        // Start with Size: Plex ignores X-Plex-Container-Size on its own.
        var queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(count)")
        ]

        // The /hubs/items endpoint requires an identifier parameter to specify which hub
        // Without it, Plex returns 404. See: https://plexapi.dev/api-reference/hubs/get-a-hubs-items
        if hubKey == "/hubs/items" || hubKey.hasSuffix("/hubs/items") {
            guard let hubIdentifier, !hubIdentifier.isEmpty else { return nil }
            queryItems.append(URLQueryItem(name: "identifier", value: hubIdentifier))
        }

        components.queryItems = queryItems
        return components.url
    }

    /// Get more items from a hub using its key (for pagination/infinite scroll)
    /// - Parameters:
    ///   - hubKey: The hub's key path (e.g., "/hubs/sections/1/continueWatching")
    ///   - hubIdentifier: The hub's identifier (e.g., "home.movies.recent") - required when hubKey is "/hubs/items"
    ///   - start: Starting index for pagination
    ///   - count: Number of items to fetch
    /// - Returns: The page's items and the hub's total under its own query
    ///   (`totalSize`, or the page's `size` when the server sends no total).
    ///   `loadMoreIfNeeded` ends the row once it has loaded that many.
    func getHubItems(
        serverURL: String,
        authToken: String,
        hubKey: String,
        hubIdentifier: String? = nil,
        start: Int = 0,
        count: Int = 24
    ) async throws -> (items: [PlexMetadata], totalSize: Int?) {
        guard let url = Self.hubItemsURL(
            serverURL: serverURL,
            hubKey: hubKey,
            hubIdentifier: hubIdentifier,
            start: start,
            count: count
        ) else {
            // Neither case can ever page, so the caller ends the row.
            print("⚠️ PlexNetworkManager: Cannot build a page URL for this hub")
            return (items: [], totalSize: nil)
        }

        let container: PlexMediaContainerWrapper = try await request(
```
The `/hubs/items` check still matches on the key string, as before. A key that carries its own query (and possibly its own `identifier`) is therefore not treated as bare `/hubs/items`, and its query is kept.

- [ ] **Step 3b: Return the real total** in `$SCRATCH/mine.swift`.

Find (it is unique in the file):
```swift
        let totalSize = container.MediaContainer.size
```
Replace with:
```swift
        let totalSize = container.MediaContainer.totalSize ?? container.MediaContainer.size
```

- [ ] **Step 3c: Build the patch and apply it to the working tree.**
```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && F=RivuletCore/Plex/PlexNetworkManager.swift && { diff -u --label "a/$F" --label "b/$F" "$SCRATCH/head.swift" "$SCRATCH/mine.swift" > "$SCRATCH/task2.patch"; true; } && grep '^@@' "$SCRATCH/task2.patch"
```
`diff` exits 1 whenever the files differ, which is why the command wraps it in `{ ...; true; }`. When this plan was dry-run against HEAD `7aa86fb`, the patch had exactly 3 hunks: `@@ -936,35 +936,30 @@`, `@@ -972,19 +967,41 @@` and `@@ -993,7 +1010,7 @@`.
```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && grep -c 'PlexLiveTuneError\|serverMessage' "$SCRATCH/task2.patch"; git apply --check "$SCRATCH/task2.patch" && git apply "$SCRATCH/task2.patch" && git diff RivuletCore/Plex/PlexNetworkManager.swift | grep '^@@'
```
Expect `0` from the grep. The working-tree diff should then show your 3 hunks plus the other session's hunks from Step 0.

If Step 4 or Step 5 forces a code change: run `git apply -R "$SCRATCH/task2.patch"`, make the change in `$SCRATCH/mine.swift`, then repeat this step.

- [ ] **Step 4: Run the test and confirm it passes.** Run the same command as Step 2. Expected result: `** TEST SUCCEEDED **`, with all of `PlexNetworkManagerURLTests` passing, including the 5 new `testHubItemsURL...` tests.

- [ ] **Step 5: Build both schemes and lint.** RivuletCore changed, so both schemes must build.
```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd"
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild build -scheme 'Rivulet iOS' -destination 'generic/platform=iOS Simulator' -derivedDataPath "$SCRATCH/dd-ios"
cd "/Users/bain/git/Swift Projects/Rivulet" && swiftlint lint --strict   # or the docker form from Task 1 Step 5
```
Expected result: `** BUILD SUCCEEDED **` twice, and 0 lint violations. iOS has no `getHubItems` caller, so it only has to compile. The same caveat as Step 2 applies to failures in the other session's files.

- [ ] **Step 6: Device verification (paging regression check, spec §9 Paging).** This changes every paginated row, collections included. Run on the Apple TV against the home PMS. The numbers were measured on 2026-09-30, and titles will drift as the library changes. A tile that is still loading shows the skeleton at the row's tail.
  1. **Movies library, Recently Added:** press Right past tile 48. Tiles keep arriving in newest-added order. Tile 25 must not be "The Adventures of Huck Finn", which is today's title-order page 2. Today the row stops at 48.
  2. **Movies library, a genre row** (the Crime row, `movie.genre.1.80`: unwatched, rated 7+): scroll to the end. It stops at the filtered total (61 on 2026-09-30), and every tile is an unwatched film in that genre. There should be no run of unrelated titles in A to Z order.
  3. **TV library, Recently Released Episodes** (`tv.recentlyaired.2`): scroll past 24 and past 48. The tiles stay episodes, newest air date first. Today tile 25 onward are shows in title order starting "The Artful Dodger".
  4. **TV library, Recently Added** (`/hubs/home/recentlyAdded?type=2&sectionID=2`): it now pages past 24, up to 50 tiles. Today it stops at 24 because page 2 came back empty.
  5. **Home, promoted Recently Added Movies:** pages past 48 in added order.
  6. **Continue Watching is unchanged.** Home CW (34 items measured) shows the same tiles, appends no duplicates, and leaves no skeleton that never resolves. TV library Continue Watching shows 25 tiles and stops, as it does today.
  7. **Unbounded rows:** hold Right on Recently Released Episodes (20,770 total) for about 20 seconds. Scrolling keeps up and the app stays responsive.
  8. **P1 collection row:** in Plex, promote a collection with more than 48 members to Home. Action Movies has 416; James Bond has only 4 on this server. Relaunch Rivulet. The row pages past 48 in the collection's own order. Unpromote it afterwards if you do not want it on Home.
  9. Deferred to later tasks: Action Movies (416) paging past slot 60 on the collection page is Task 3, Step 6, check 6, and a large pinned row paging past 48 is Task 8, Step 6, check 16.

  Paging here is data behaviour, not focus, so a Simulator run is informative. The device run is the one that counts.

- [ ] **Step 7: Commit.** Stage only this task's hunks, from the patch. Never `git add` the working-tree file, which also holds the other session's Live TV hunks.
```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && [ -z "$(git diff --cached --name-only)" ] || { echo "index already has staged changes; stop"; exit 1; }
cd "/Users/bain/git/Swift Projects/Rivulet" && git apply --check --cached "$SCRATCH/task2.patch" && git apply --cached "$SCRATCH/task2.patch" && git add RivuletTests/Unit/Services/PlexNetworkManagerURLTests.swift
cd "/Users/bain/git/Swift Projects/Rivulet" && git diff --cached RivuletCore/Plex/PlexNetworkManager.swift | grep -c 'PlexLiveTuneError'   # expect 0
cd "/Users/bain/git/Swift Projects/Rivulet" && [ "$(git branch --show-current)" = test/integration ] && [ "$(git diff --cached --name-only | sort)" = "$(printf '%s\n' RivuletCore/Plex/PlexNetworkManager.swift RivuletTests/Unit/Services/PlexNetworkManagerURLTests.swift | sort)" ] && git commit -m "Page hub rows by their own query and total"
cd "/Users/bain/git/Swift Projects/Rivulet" && git diff RivuletCore/Plex/PlexNetworkManager.swift | grep '^@@'   # only the other session's hunks remain, still uncommitted
```
Changelog: do not edit `WhatsNewView` in this commit. At tag time, Task 11 adds §10 step 0b's line ("Long rows on Home, including collections from Plex, now keep loading as you scroll."), keyed from the real release tag.

---

### Task 3: Collection page content (HomeMode.collection)

Implements spec §5.2 except presentation, routing, the anchor's `preferredFocusEnvironments` routing and Menu (Task 4). After this task the page renders, pages and recovers correctly when constructed as `PlexHomeViewController(mode: .collection(item))`. Nothing presents it yet, so the collection-page device checks run later (Step 6, checks 5 to 7b, beside Task 4's checks). This task's own device run is a regression check of the library grid, which shares every edited path.

**Files:**
- Modify: `Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift` (`HomeMode`, `HomeSectionData.grid`, stored properties near `stateViewHasFocusableAction` ~480 and `gridPageSize` ~569, `emptyStateMessage` ~627, `showHomeHero` ~638, `viewDidLoad` ~707/~825, `loadGridPage` ~1183, new `reloadLoadedGridPages` after `reconfigureGridSlots` ~1240, `configureStateOverlays` ~1867, `updateHomeState` ~1891, `observeDataStore` ~2602/~2639, `updateAmbientIfNeeded` ~3376, `computeSections` ~3393, `selectHeroItemsIfNeeded` ~3665/~3696, `heroItemsVisibleOnHome` ~3766, `upgradeHeroFromTMDB` ~3874, `resolveHeroWithHubFallback` ~3974, `performMenuAction` ~5319)
- Test: `RivuletTests/Unit/HomeCollectionPageTests.swift` (beside `HomePromotedHubRowsTests.swift`, where the Home tests live)

**Interfaces:**
- Consumes (Task 2, must be committed first): `PlexNetworkManager.getHubItems(serverURL:authToken:hubKey:hubIdentifier:start:count:) async throws -> (items: [PlexMetadata], totalSize: Int?)`, with `totalSize` now meaning `MediaContainer.totalSize ?? MediaContainer.size`. Without Task 2 the grid sizes itself to one page (60 slots) and never pages.
- Produces:
  - `HomeMode.collection(MediaItem)` (`item.ref.itemID` is the collection ratingKey).
  - `HomeSectionData.grid(items: [MediaItem], title: String? = nil) -> HomeSectionData`, `headerStyle: title == nil ? .swiftUIInfiniteRow : .swiftUIWatchlist`.
  - `private enum PageZeroState: Equatable { case loading, loaded, failed(String) }` nested in `PlexHomeViewController`, and `private var pageZero: PageZeroState = .loading`. Task 4 reads it with `case .loading = pageZero`.
  - `private func reloadLoadedGridPages()`.
  - `private let collectionFocusAnchor = PreviewFocusAnchorView()`, added zero-size to `view` in viewDidLoad's `.collection` case (this task owns the `addSubview`), `isHidden` driven by `updateHomeState` (visible only while loading). Task 4 adds only the `preferredFocusEnvironments` routing and Menu behaviour.
  - `loadGridPage(containing:)` now has one common guard (`index >= 0, gridItems.isEmpty || index < gridItems.count, serverURL, token`) followed by a per-mode fetch closure. Task 6 adds a separate `guard !gridShowsCollections else { return }` as the function's first line.

- [ ] **Step 0: Pre-flight (shared checkout)**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
git diff --quiet HEAD -- Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift && echo CLEAN || echo "FOREIGN HUNKS"
git log --oneline -5   # Task 2's getHubItems commit must be present
```

If it prints `FOREIGN HUNKS`, another session has uncommitted edits in the file: make every edit below on a copy of `git show HEAD:<path>` and apply it with the patch path from the global constraints (`diff -u` with a/ b/ headers, `git apply --check --cached`, `git apply --cached`), never by staging the whole file.

- [ ] **Step 1: Write the failing test**

Create `RivuletTests/Unit/HomeCollectionPageTests.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomeCollectionPageTests.swift
//  RivuletTests
//
//  The collection page is PlexHomeViewController in `.collection` mode: one
//  `.grid` section under the collection's title. The supplementary header
//  takes its style from the section's `headerStyle`, so a titled grid must
//  carry the Watchlist page's title style. The untitled library grid keeps
//  the row style it has always had.
//

import XCTest
@testable import Rivulet

@MainActor
final class HomeCollectionPageTests: XCTestCase {

    func test_titledGrid_usesWatchlistHeaderStyle() {
        let section = HomeSectionData.grid(items: [], title: "James Bond Collection")
        XCTAssertEqual(section.id, .grid)
        XCTAssertEqual(section.kind, .grid)
        XCTAssertEqual(section.title, "James Bond Collection")
        XCTAssertTrue(section.headerStyle == .swiftUIWatchlist)
        XCTAssertNil(section.totalSize, "a title-only header carries no count")
    }

    func test_untitledGrid_keepsRowHeaderStyle() {
        let section = HomeSectionData.grid(items: [])
        XCTAssertNil(section.title)
        XCTAssertTrue(section.headerStyle == .swiftUIInfiniteRow)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' \
  -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/HomeCollectionPageTests
```

Expected: compile failure in `HomeCollectionPageTests.swift`: `Extra argument 'title' in call`, then `** TEST FAILED **`. If the build instead fails in a file you did not touch (the checkout carries another session's untracked Live TV tests, which the synchronized test group compiles), stop and report; do not edit those files.

- [ ] **Step 3a: Implement: `HomeMode.collection`**

Find:

```swift
    /// Watchlist surface: no hero, one poster grid of every Plex Watchlist
    /// entry (issue #287). Entries are Discover metadata, so the tiles,
    /// the tap and the tile menu all reuse the Home watchlist row's paths.
    case watchlist
}
```

Replace with:

```swift
    /// Watchlist surface: no hero, one poster grid of every Plex Watchlist
    /// entry (issue #287). Entries are Discover metadata, so the tiles,
    /// the tap and the tile menu all reuse the Home watchlist row's paths.
    case watchlist
    /// Collection page: one Plex collection's members as a poster grid under
    /// the collection's title. `ref.itemID` is the collection ratingKey.
    case collection(MediaItem)
}
```

- [ ] **Step 3b: Implement: titled grid builder**

Find:

```swift
    /// Library mode: the paginated poster grid. `items` carries the
    /// loaded grid items.
    static func grid(items: [MediaItem]) -> HomeSectionData {
        HomeSectionData(
            id: .grid,
            kind: .grid,
            title: nil,
            headerStyle: .swiftUIInfiniteRow,
```

Replace with:

```swift
    /// Paginated poster grid. `items` carries the grid slots. Library mode
    /// passes no title (its sort header names the library); the collection
    /// page passes the collection's title, drawn in the Watchlist page's
    /// title style.
    static func grid(items: [MediaItem], title: String? = nil) -> HomeSectionData {
        HomeSectionData(
            id: .grid,
            kind: .grid,
            title: title,
            headerStyle: title == nil ? .swiftUIInfiniteRow : .swiftUIWatchlist,
```

(`makeGridSectionLayout` already adds the `HubHeaderView` supplementary when `data.title != nil`, and the supplementary provider reads `section.headerStyle`; neither changes.)

- [ ] **Step 3c: Implement: stored properties**

Find:

```swift
    private var stateViewHasFocusableAction = false
```

Replace with:

```swift
    private var stateViewHasFocusableAction = false
    /// Collection page only: a zero-size focus target that holds focus while
    /// page 0 is in flight, so focus never stays on the library tile under
    /// this modal. Visible only in the loading state (see updateHomeState).
    private let collectionFocusAnchor = PreviewFocusAnchorView()
```

Find:

```swift
    private let gridPageSize = 60
```

Replace with:

```swift
    private let gridPageSize = 60
    /// Collection page only: page 0's outcome. An empty `gridItems` reads the
    /// same while the request is in flight, after it failed and after an
    /// empty answer, so updateHomeState reads this instead. Set by
    /// loadGridPage's page 0 success and catch, reset by the retry.
    private enum PageZeroState: Equatable { case loading, loaded, failed(String) }
    private var pageZero: PageZeroState = .loading
```

- [ ] **Step 3d: Implement: `emptyStateMessage` (switch site 1 of 11)**

Find:

```swift
        case .watchlist:
            return "Nothing in your Watchlist yet."
```

Replace with:

```swift
        case .watchlist:
            return "Nothing in your Watchlist yet."
        case .collection:
            return "This collection is empty."
```

- [ ] **Step 3e: Implement: `showHomeHero` (site 2)**

Find:

```swift
        case .watchlist:
            return false  // Watchlist is the grid alone
```

Replace with:

```swift
        case .watchlist:
            return false  // Watchlist is the grid alone
        case .collection:
            return false  // A collection page is its title and grid
```

- [ ] **Step 3f: Implement: `viewDidLoad` background**

Find:

```swift
        view.backgroundColor = .clear

        Perf.event(.homeFirstRender, message: "viewDidLoad start")
```

Replace with:

```swift
        view.backgroundColor = .clear
        // Collection page: presented over the library through
        // BlurFadeAnimator, which assumes an opaque page.
        if case .collection = mode { view.backgroundColor = .black }

        Perf.event(.homeFirstRender, message: "viewDidLoad start")
```

- [ ] **Step 3g: Implement: `viewDidLoad` load (site 3)**

This `switch mode` runs after `configureCollectionView()` and `configureStateOverlays()`, so the anchor is added above every other subview and nothing occludes it.

Find:

```swift
                isLoadingWatchlist = false
                applySnapshot(animated: false)
                updateHomeState()
            }
        }
    }
```

Replace with:

```swift
                isLoadingWatchlist = false
                applySnapshot(animated: false)
                updateHomeState()
            }
        case .collection:
            // Collection page: its members only. No hubs, hero or alphabet
            // bar. The zero-size anchor is the page's focus target while
            // page 0 loads.
            collectionFocusAnchor.frame = .zero
            view.addSubview(collectionFocusAnchor)
            // A 416-member collection is 70 rows: keep tvOS's fast-scroll
            // index bar invisible, as library mode does. It still takes focus
            // on a held Up/Down, which starts the page's own fast scroll.
            collectionView.showsVerticalScrollIndicator = false
            collectionView.indexDisplayMode = .alwaysHidden
            loadGridPage(containing: 0)
        }
    }
```

- [ ] **Step 3h: Implement: `loadGridPage` collection branch and `pageZero`**

Find (the whole function head through the catch):

```swift
    private func loadGridPage(containing index: Int) {
        guard case .library(let key, _) = mode,
              index >= 0,
              gridItems.isEmpty || index < gridItems.count,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        let page = index / gridPageSize
        guard gridPagesRequested.insert(page).inserted else { return }
        let gen = gridGeneration
        let start = page * gridPageSize
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await PlexNetworkManager.shared.getLibraryItemsWithTotal(
                    serverURL: serverURL,
                    authToken: token,
                    sectionId: key,
                    start: start,
                    size: self.gridPageSize,
                    sort: self.gridSort.apiParameter
                )
                guard gen == self.gridGeneration else { return }
                let total = result.totalSize ?? max(self.gridItems.count, start + result.items.count)
```

Replace with:

```swift
    private func loadGridPage(containing index: Int) {
        guard index >= 0,
              gridItems.isEmpty || index < gridItems.count,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        let network = PlexNetworkManager.shared
        let pageSize = gridPageSize
        let fetchPage: (Int) async throws -> (items: [PlexMetadata], totalSize: Int?)
        if case .library(let key, _) = mode {
            let sort = gridSort.apiParameter
            fetchPage = { start in
                try await network.getLibraryItemsWithTotal(
                    serverURL: serverURL,
                    authToken: token,
                    sectionId: key,
                    start: start,
                    size: pageSize,
                    sort: sort
                )
            }
        } else if case .collection(let item) = mode {
            // The members through the hub pager, in the collection's own
            // collectionSort (the server ignores sort=). Never getChildren or
            // PlexProvider.children(of:): /library/metadata/{rk}/children
            // returns nothing for a smart collection.
            let childrenKey = "/library/collections/\(item.ref.itemID)/children"
            fetchPage = { start in
                try await network.getHubItems(
                    serverURL: serverURL,
                    authToken: token,
                    hubKey: childrenKey,
                    start: start,
                    count: pageSize
                )
            }
        } else {
            return
        }
        let page = index / gridPageSize
        guard gridPagesRequested.insert(page).inserted else { return }
        let gen = gridGeneration
        let start = page * gridPageSize
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await fetchPage(start)
                guard gen == self.gridGeneration else { return }
                if page == 0 { self.pageZero = .loaded }
                let total = result.totalSize ?? max(self.gridItems.count, start + result.items.count)
```

Then find (the catch, same function):

```swift
                guard gen == self.gridGeneration else { return }
                self.gridPagesRequested.remove(page)
```

Replace with:

```swift
                guard gen == self.gridGeneration else { return }
                self.gridPagesRequested.remove(page)
                if page == 0 { self.pageZero = .failed(error.localizedDescription) }
```

Then find (the success path, same function; unique in the file):

```swift
                let end = min(start + result.items.count, self.gridItems.count)
```

Replace with:

```swift
                // A reload can land after the grid shrank below this page's
                // start: keep the range empty instead of trapping on start..<end.
                let end = max(start, min(start + result.items.count, self.gridItems.count))
```

Without the clamp a shrink traps in release builds too. Worked case: 130 members, pages 0 to 2 loaded, the collection drops to 115, and `reloadLoadedGridPages` re-requests page 2 (its request guard ran against the old count). PMS answers the out-of-range start with 200, no items and totalSize 115, so the unclamped `end` is 115 and `reconfigureGridSlots(120..<115)` hits `Range requires lowerBound <= upperBound`. Clamped, the write loop skips and `reconfigureGridSlots` returns early on the empty range. The library grid shares the fix.

(`pageZero` is written in library mode too and read only in collection mode. The rest of the success path, slot sizing, `applySnapshot`, `refreshSortHeaderCount` (a no-op without a sort header), `updateHomeState` on page 0 and `reconfigureGridSlots`, is unchanged.)

- [ ] **Step 3i: Implement: `reloadLoadedGridPages`**

Find:

```swift
    // MARK: - Alphabet bar (issue #308)
```

Replace with:

```swift
    /// Re-requests every loaded grid page in place. Slots are positional, so
    /// a focused tile is reconfigured in place unless the collection shrank
    /// below it (loadGridPage clamps that case). The collection page calls
    /// this when a member's watch state may have changed.
    // ponytail: re-requests every loaded page (7 at most for the largest
    // measured collection, 416 members); fetch only visible pages if it shows up.
    private func reloadLoadedGridPages() {
        let pages = gridPagesRequested
        gridPagesRequested = []
        pages.forEach { loadGridPage(containing: $0 * gridPageSize) }
    }

    // MARK: - Alphabet bar (issue #308)
```

- [ ] **Step 3j: Implement: retry path**

Find:

```swift
        stateView.onAction = { [weak self] in
            guard let self else { return }
            Task { await self.dataStore.refreshHubs() }
        }
```

Replace with:

```swift
        stateView.onAction = { [weak self] in
            guard let self else { return }
            // Collection page: Try Again (page 0 failed) and Refresh (empty)
            // both ask for page 0 again. A settled empty page 0 is still
            // marked requested, so forget it first.
            if case .collection = self.mode {
                self.pageZero = .loading
                self.updateHomeState()
                self.gridPagesRequested.remove(0)
                self.loadGridPage(containing: 0)
                return
            }
            Task { await self.dataStore.refreshHubs() }
        }
```

- [ ] **Step 3k: Implement: `updateHomeState` mode arm (site 4)**

Find:

```swift
            hubsEmpty = watchlistService.watchlistItems.isEmpty
        }
```

Replace with:

```swift
            hubsEmpty = watchlistService.watchlistItems.isEmpty
        case .collection:
            // Page 0's own outcome: an empty grid reads the same while the
            // request is in flight, after it failed and after an empty answer.
            switch pageZero {
            case .loading:
                isLoadingHubs = true
                hubsError = nil
            case .loaded:
                isLoadingHubs = false
                hubsError = nil
            case .failed(let message):
                isLoadingHubs = false
                hubsError = message
            }
            hubsEmpty = gridItems.isEmpty
        }
```

- [ ] **Step 3l: Implement: `updateHomeState` loading flag**

Find:

```swift
        let isWaitingForHero = shouldWaitForHeroBeforeContent(hubsEmpty: hubsEmpty)
        stateViewHasFocusableAction = false
```

Replace with:

```swift
        let isWaitingForHero = shouldWaitForHeroBeforeContent(hubsEmpty: hubsEmpty)
        stateViewHasFocusableAction = false
        var showsLoading = false
```

Find:

```swift
        } else if (isLoadingHubs && hubsEmpty) || isWaitingForHero {
            stateView.configure(kind: .loading)
            stateView.isHidden = false
            collectionView.isHidden = true
            backdropView.isHidden = true
        } else if let error = hubsError, hubsEmpty {
```

Replace with:

```swift
        } else if (isLoadingHubs && hubsEmpty) || isWaitingForHero {
            stateView.configure(kind: .loading)
            stateView.isHidden = false
            collectionView.isHidden = true
            backdropView.isHidden = true
            showsLoading = true
        } else if let error = hubsError, hubsEmpty {
```

- [ ] **Step 3m: Implement: `updateHomeState` focus onto the first tile**

Find:

```swift
            if wasUnfocusable {
                NotificationCenter.default.post(name: .contentBecameFocusable, object: nil)
            }
            backdropView.isHidden = !showHomeHero
            ConnectionAlert.presentOnceIfOffline(from: self)
        }
```

Replace with:

```swift
            if wasUnfocusable, case .collection = mode {
                // Collection page: a modal, so the shell's re-drive does
                // nothing for it (its handler no-ops once the library tab has
                // held focus). Page 0's snapshot was applied while the
                // collection view was hidden, so no cell existed until now:
                // lay out, then ask for the first tile explicitly. Focus sits
                // on this page's own anchor, so the request is honoured.
                collectionView.layoutIfNeeded()
                if let cell = collectionView.cellForItem(at: IndexPath(item: 0, section: 0)),
                   let system = UIFocusSystem.focusSystem(for: collectionView) {
                    system.requestFocusUpdate(to: cell)
                    system.updateFocusIfNeeded()
                }
            } else if wasUnfocusable {
                NotificationCenter.default.post(name: .contentBecameFocusable, object: nil)
            }
            backdropView.isHidden = !showHomeHero
            ConnectionAlert.presentOnceIfOffline(from: self)
        }

        // Collection page: the anchor is visible only while page 0 is in
        // flight, so it never competes with the grid or the state view's
        // button. Entering loading again (the retry) re-resolves focus, which
        // moves it off the Try Again button that just vanished.
        if case .collection = mode {
            collectionFocusAnchor.isHidden = !showsLoading
            if showsLoading { setNeedsFocusUpdate() }
        }
```

(The first-tile request runs inside the chain, before the anchor is hidden, so focus moves from anchor to tile in one update.)

- [ ] **Step 3n: Implement: `observeDataStore` (sites 5 and 6)**

Find:

```swift
                    case .library:
                        await self.refreshThisLibraryHubs()
                    }
```

Replace with:

```swift
                    case .library:
                        await self.refreshThisLibraryHubs()
                    case .collection:
                        // Playback and detail-page watch changes: re-request
                        // the loaded pages so badges and progress repaint.
                        self.reloadLoadedGridPages()
                    }
```

Find:

```swift
        case .discover, .search, .watchlist:
            break
```

Replace with:

```swift
        case .discover, .search, .watchlist, .collection:
            break
```

- [ ] **Step 3o: Implement: `updateAmbientIfNeeded` seeding**

Find:

```swift
    private func updateAmbientIfNeeded() {
        guard !ambientView.hasAmbient else { return }
```

Replace with:

```swift
    private func updateAmbientIfNeeded() {
        guard !ambientView.hasAmbient else { return }
        // Collection page: the collection's own art when it has some (12 of
        // 112 on the measured server), else its first loaded member. Never
        // Home's rows, which are not on this page.
        if case .collection(let collection) = mode {
            let member = sectionsSnapshot.first?.items.first?.heroBackdropRequest()
            guard let url = collection.heroBackdropRequest().backdropURL
                    ?? member?.backdropURL ?? member?.thumbnailURL else { return }
            ambientView.setAmbient(url: url)
            return
        }
```

(`MediaItem.heroBackdropRequest().backdropURL` is `artwork.backdrop`, which maps from `art` only, so a collection without art falls through to its member instead of washing with its own composite poster.)

- [ ] **Step 3p: Implement: `computeSections`**

Find:

```swift
        if case .watchlist = mode {
            let items = watchlistService.watchlistItems
            return items.isEmpty ? [] : [.watchlistGrid(items: items)]
        }
```

Replace with:

```swift
        if case .watchlist = mode {
            let items = watchlistService.watchlistItems
            return items.isEmpty ? [] : [.watchlistGrid(items: items)]
        }
        // One titled grid; the header is supplementary, so the grid stays
        // section 0 (`topSectionIndex`) and Menu never stages a return-to-top.
        if case .collection(let item) = mode {
            return gridItems.isEmpty ? [] : [.grid(items: mapGridSlots(gridItems), title: item.title)]
        }
```

- [ ] **Step 3q: Implement: hero switches (sites 7 to 11)**

`selectHeroItemsIfNeeded`, find:

```swift
        case .discover, .search, .watchlist:
            return  // no Plex-hub hero on these surfaces
```

Replace with:

```swift
        case .discover, .search, .watchlist, .collection:
            return  // no Plex-hub hero on these surfaces
```

`selectHeroItemsIfNeeded`, find:

```swift
        case .discover, .search, .watchlist: isTMDBEligible = false
```

Replace with:

```swift
        case .discover, .search, .watchlist, .collection: isTMDBEligible = false
```

`heroItemsVisibleOnHome`, find:

```swift
        case .library, .discover, .search, .watchlist:
```

Replace with:

```swift
        case .library, .discover, .search, .watchlist, .collection:
```

`upgradeHeroFromTMDB`, find:

```swift
            heroType = t
        case .discover, .search, .watchlist:
            return
```

Replace with:

```swift
            heroType = t
        case .discover, .search, .watchlist, .collection:
            return
```

`resolveHeroWithHubFallback`, find:

```swift
        case .discover, .search, .watchlist: return
```

Replace with:

```swift
        case .discover, .search, .watchlist, .collection: return
```

The 11 `switch mode` sites and their collection arms, for the reviewer:

| # | Site | Collection arm |
|---|---|---|
| 1 | `emptyStateMessage` | `case .collection: return "This collection is empty."` |
| 2 | `showHomeHero` | `case .collection: return false` |
| 3 | `viewDidLoad` | `case .collection:` anchor added, index bar hidden, `loadGridPage(containing: 0)` |
| 4 | `updateHomeState` | `case .collection:` driven by `pageZero`, `hubsEmpty = gridItems.isEmpty` |
| 5 | `.plexDataNeedsRefresh` sink | `case .collection: self.reloadLoadedGridPages()` |
| 6 | `observeDataStore` GUID-index sink | joins `case .discover, .search, .watchlist, .collection: break` |
| 7 | `selectHeroItemsIfNeeded` (source) | joins `... .collection: return` |
| 8 | `selectHeroItemsIfNeeded` (TMDB) | joins `... .collection: isTMDBEligible = false` |
| 9 | `heroItemsVisibleOnHome` | joins `case .library, ..., .collection: return items` |
| 10 | `upgradeHeroFromTMDB` | joins `... .collection: return` |
| 11 | `resolveHeroWithHubFallback` | joins `... .collection: return` |

- [ ] **Step 3r: Implement: `performMenuAction`**

Find:

```swift
                try await action()
            } catch {}
            await dataStore.refreshHubs()
```

Replace with:

```swift
                try await action()
            } catch {}
            // Collection page: a member's watch state changed from its tile
            // menu, which posts no .plexDataNeedsRefresh.
            if case .collection = mode { reloadLoadedGridPages() }
            await dataStore.refreshHubs()
```

Then confirm no site was missed:

```bash
grep -n "switch mode\|switch self.mode" Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift
```

Expected: 11 lines, each covered by the table above. The compiler also rejects any non-exhaustive one.

- [ ] **Step 4: Run it to verify it passes**

```bash
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' \
  -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/HomeCollectionPageTests
```

Expected: `Executed 2 tests, with 0 failures` and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Build and lint**

RivuletCore is unchanged in this task, so the iOS scheme needs no build.

```bash
xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd"
swiftlint lint --strict
git diff -U0 -- Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift | grep '^+' | grep -nE $'\xe2\x80\x93|\xe2\x80\x94'
grep -nE $'\xe2\x80\x93|\xe2\x80\x94' RivuletTests/Unit/HomeCollectionPageTests.swift
```

Expected: `** BUILD SUCCEEDED **` with no new warnings in `PlexHomeViewController.swift`; swiftlint reports 0 violations; the dash check prints nothing.

- [ ] **Step 6: Device verification**

On an Apple TV (the Simulator's focus behaviour is provisional). This task restructured `loadGridPage`, which the library grid shares, so checks 1 to 4 run now:
1. Open a Movies library tab. Press Down to the grid. Hold Down past row 10 (slot 60) and again past slot 120. Expected: every row fills with posters; no slot stays a blank card once focus has passed it.
2. Select the sort button and pick a different sort. Expected: the grid reloads from the first tile in the new order, and the count in the sort header is unchanged.
3. With Title sort active, focus the grid and move to the alphabet bar; pick a late letter. Expected: the grid jumps and the tiles there load.
4. Long-press a library grid tile and choose Mark as Watched. Expected: the Home rows update exactly as before (the library grid badge staying stale is today's known gap, unchanged).

Checks 5 to 7b pin this task's collection-page code but need an entry point, so they run on the first build that has Task 5's Collections row, beside Task 4's checks 6a to 6f. Record the results against this task.

5. **Watch state repaints in place (Review Focus 1).** Open James Bond (rk 9144) from the Movies Collections row. Long-press "Live and Let Die" and choose Mark as Watched. Expected: within about a second the tile shows the watched glyph, focus stays on it and the page does not scroll. Choose Mark as Unwatched to restore it. Then Select "Dr. No", press Play in the carousel, play about 30 seconds, press Menu to leave the player, and press Menu again to close the carousel. Expected: Dr. No shows a progress bar on the collection page without the page being reopened, and focus is on Dr. No. Clear the progress in Plex Web afterwards.
6. **Large collection (Review Focus 2).** Open Action Movies (416 members). Press Down row by row past row 10 (slot 60) and again past slot 120. Expected: every row fills with posters in the collection's order, no slot stays a blank card once focus has passed it, and the title header shows once at the top. Then hold Down for about 3 seconds and release. Expected: the rows scroll fast, no system index dots appear at the right edge, and focus is on a grid tile after release. One Menu press then dismisses the page.
7. **Collection shrinks under focus (Review Focus 5).** In Plex Web make a manual collection "AAA Shrink Test" with 5 movies from Movies. Relaunch Rivulet, open Movies, open that collection from the Collections row and focus its 5th tile. In Plex Web remove the 4th movie from the collection. In Rivulet long-press the focused 5th tile and choose Mark as Watched, which re-requests the loaded pages. Expected: no crash; the grid shows 4 tiles in Plex's order with no blank placeholder; focus is on one of the 4 tiles and the Siri Remote moves it. Mark the movie unwatched again and delete the test collection in Plex Web.
7b. **Shrink past a loaded page (Review Focus 5, the crash case).** Check 7 has one page, so it never reaches the clamp. In Plex Web, multi-select 70 movies in Movies and add them to a new manual collection "AAA Shrink Test 2". Relaunch Rivulet, open it from the Collections row, press Down to row 11 so page 1 (slots 60 to 69) loads, and focus slot 65 (row 11, 6th tile). In Plex Web remove 15 members, dropping the count to 55, below page 1's start. In Rivulet long-press the focused tile and choose Mark as Watched. Expected: no crash; the grid ends at 55 tiles with no blank placeholder; focus is on a surviving tile and the Siri Remote moves it. Repeat once with play and exit (Select a tile, Play, Menu out of the player, Menu to close the carousel) in place of Mark as Watched. Mark the movie unwatched and delete the collection in Plex Web.

If check 7 or 7b loses focus entirely (no tile highlighted and arrows do nothing), add this to `loadGridPage`'s success path and rerun both checks. It reuses the alphabet bar's jump machinery (`pendingGridFocusItem`, `focusPendingGridSlot`), which the collection page otherwise never touches. Find:

```swift
                let countChanged = total != self.gridItems.count
```

Replace with:

```swift
                // Collection page: a shrink that deletes the focused slot.
                let focusedSlotLost = TileLongPress.focusedCell(in: self.collectionView)
                    .map { $0.section == self.gridSectionIndex && $0.item >= total } ?? false
                let countChanged = total != self.gridItems.count
```

Then find:

```swift
                self.applySnapshot(animated: false)
                if countChanged || page == 0 {
```

Replace with:

```swift
                self.applySnapshot(animated: false)
                if case .collection = self.mode, focusedSlotLost, total > 0 {
                    self.collectionView.layoutIfNeeded()
                    self.pendingGridFocusItem = total - 1
                    self.focusPendingGridSlot()
                }
                if countChanged || page == 0 {
```

If focus is still lost after that, stop and report; Review Focus 5 is not met and the collection page does not ship.

- [ ] **Step 7: Commit**

```bash
git add Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift RivuletTests/Unit/HomeCollectionPageTests.swift
[ "$(git branch --show-current)" = test/integration ] && [ "$(git diff --cached --name-only | sort)" = "$(printf '%s\n' Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift RivuletTests/Unit/HomeCollectionPageTests.swift | sort)" ] && git commit -m "Home: collection page grid mode"
```

If Step 0 printed `FOREIGN HUNKS`, stage `PlexHomeViewController.swift` through `git apply --cached` of your own patch instead of `git add` for that file, then run the same gated commit.

---

### Task 4: Presenting and routing to the collection page

Spec: §5.2 Presentation, Focus anchor, Routing, Menu, Focus back on the library; §9 collection page device checks; rollout step 1 (routing half).

**Files:**
- Modify: `Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift` (stored properties beside `let mode: HomeMode` ~416, `init(mode:)` ~416, new `viewWillAppear` before `viewDidAppear` ~1422, new `viewDidDisappear` after `viewWillDisappear` ~1441, new `static func openCollectionIfNeeded` plus the call in `presentPreview(forSection:indexPath:)` ~4249, `preferredFocusEnvironments` ~4991, `tileMenuSections(for:isContinueWatching:shelfLocation:)` ~5191, `handleMenuBack` ~5679). Line numbers are from HEAD `7aa86fb` and will have moved after Task 3.
- Modify: `Rivulet/Views/Media/PreviewCarousel/UIKit/PreviewCarouselViewController.swift` (`presentStandaloneDetail(_:)` ~1014)
- Modify: `Rivulet/Views/Media/UIKit/Cells/ShelfRowCell.swift` (`prepareFocusRestore(on:)` ~445)
- Modify: `Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldCollectionView.swift` (`restoreShelfRowFocusIfNeeded()` ~1137)
- Modify: `Rivulet/Views/Media/MediaDetail/UIKit/ExpandedDetailContainerView.swift` (`restoreShelfRowFocusIfNeeded()` ~173)
- Test: `RivuletTests/Unit/CollectionPageRoutingTests.swift` (new, at the Unit root beside the other Home tests)

**Interfaces:**
- Consumes (Task 3): `HomeMode.collection(MediaItem)`; `private enum PageZeroState: Equatable { case loading, loaded, failed(String) }`; `private var pageZero: PageZeroState`; `private let collectionFocusAnchor = PreviewFocusAnchorView()`, already added to `view` by viewDidLoad's `.collection` case; Task 3's `updateHomeState` hiding `collectionFocusAnchor` in every state except loading, and its content branch requesting focus on grid item 0 when page 0 arrives. Existing: `BlurFadeTransitioningDelegate` (MediaItemDetailPageViewController.swift ~759), `PreviewFocusAnchorView` (PreviewCarouselViewController.swift ~1818), `ExpandedDetailContainerView.restoreShelfRowFocusIfNeeded()`, `PreviewCarouselViewController.restoreBelowFoldFocusAfterReturn()`.
- Produces: `var onDismiss: (() -> Void)?` on `PlexHomeViewController`, fired from `viewDidDisappear` when `isBeingDismissed`. `@discardableResult static func openCollectionIfNeeded(_ item: MediaItem, from presenter: UIViewController, onDismiss: (() -> Void)? = nil) -> Bool` on `PlexHomeViewController`. An early `if item.kind == .collection { return [] }` at the top of `tileMenuSections`, under a two-line comment, which Task 8 replaces with Pin / Unpin. The carousel call site that Task 10's trailing collection tile reaches through `onShowRelatedDetails` → `presentStandaloneDetail`. A `viewWillAppear` that registers the collection page's Menu handler, and a first line in `handleMenuBack` that drops Menu until the page's first `viewDidAppear`. `ShelfRowCell.armFocusRestore(on:)`, and a `requestingFocus: Bool = true` parameter on `restoreShelfRowFocusIfNeeded` in `BelowFoldCollectionView` and `ExpandedDetailContainerView`; Task 10 edits the body of the BelowFold one and must keep the parameter.

- [ ] **Step 0: Preconditions (read only)**

Task 3 must be committed. Each of these must print at least one line; if any prints nothing, stop and finish Task 3 first:

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
F=Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift
grep -n "case collection(MediaItem)" "$F"
grep -n "private var pageZero" "$F"
grep -n "private let collectionFocusAnchor = PreviewFocusAnchorView()" "$F"
grep -n "view.addSubview(collectionFocusAnchor)" "$F"
grep -n "collectionFocusAnchor.isHidden" "$F"
```

Check for another session's uncommitted hunks in the five files this task edits:

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && git diff --stat -- Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift Rivulet/Views/Media/PreviewCarousel/UIKit/PreviewCarouselViewController.swift Rivulet/Views/Media/UIKit/Cells/ShelfRowCell.swift Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldCollectionView.swift Rivulet/Views/Media/MediaDetail/UIKit/ExpandedDetailContainerView.swift
```

Empty output: edit in place and use the plain gated commit in Step 7. Any output: use the patch flow from the global constraints for that file (`git show HEAD:<path> > "$SCRATCH/head.swift"`, apply this task's edits to a copy, `diff -u` into a patch with `a/` and `b/` headers, `git apply --check --cached`, `git apply --cached`), then the gated commit.

- [ ] **Step 1: Write the failing test**

Create `RivuletTests/Unit/CollectionPageRoutingTests.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CollectionPageRoutingTests.swift
//  RivuletTests
//

import XCTest
@testable import Rivulet

/// Stands in for whatever is on screen when a tile is tapped. `below` fakes
/// the controller that presented it, and `present` records instead of
/// presenting, so the routing walk runs with no window.
private final class RecordingPresenter: UIViewController {
    var below: UIViewController?
    private(set) var presented: [UIViewController] = []

    override var presentingViewController: UIViewController? { below }

    override func present(_ viewControllerToPresent: UIViewController,
                          animated flag: Bool,
                          completion: (() -> Void)? = nil) {
        presented.append(viewControllerToPresent)
    }
}

@MainActor
final class CollectionPageRoutingTests: XCTestCase {

    private func item(_ key: String, kind: MediaKind) -> MediaItem {
        MediaItem(
            ref: MediaItemRef(providerID: "plex:test", itemID: key),
            kind: kind,
            title: "Item \(key)",
            sortTitle: nil,
            overview: nil,
            year: nil,
            runtime: nil,
            parentRef: nil,
            grandparentRef: nil,
            episodeNumber: nil,
            seasonNumber: nil,
            childProgress: nil,
            userState: MediaUserState(isPlayed: false, viewOffset: 0, isFavorite: false, lastViewedAt: nil),
            artwork: MediaArtwork(poster: nil, backdrop: nil, thumbnail: nil, logo: nil),
            parentArtwork: nil,
            grandparentArtwork: nil
        )
    }

    func test_nonCollection_isNotRouted() {
        let presenter = RecordingPresenter()

        let opened = PlexHomeViewController.openCollectionIfNeeded(item("1", kind: .movie), from: presenter)

        XCTAssertFalse(opened)
        XCTAssertTrue(presenter.presented.isEmpty)
    }

    func test_collection_presentsBlurFadePage() throws {
        let presenter = RecordingPresenter()
        var dismissed = false

        let opened = PlexHomeViewController.openCollectionIfNeeded(
            item("9144", kind: .collection), from: presenter, onDismiss: { dismissed = true })

        XCTAssertTrue(opened)
        XCTAssertEqual(presenter.presented.count, 1)
        let page = try XCTUnwrap(presenter.presented.first as? PlexHomeViewController)
        guard case .collection(let shown) = page.mode else {
            return XCTFail("presented page is not in collection mode")
        }
        XCTAssertEqual(shown.ref.itemID, "9144")
        XCTAssertEqual(page.modalPresentationStyle, .overFullScreen)
        // UIKit holds the transitioning delegate weakly: nil here means the
        // page does not keep its own reference.
        XCTAssertTrue(page.transitioningDelegate is BlurFadeTransitioningDelegate)
        page.onDismiss?()
        XCTAssertTrue(dismissed)
    }

    func test_sameCollectionBelowPresenter_doesNotStack() {
        // Collection page, a member's detail on top of it, and the detail's
        // trailing tile is the same collection. Only the no-stack half is
        // checkable here: the fake page never really presents, so the unwind
        // (dismiss) is device check 6h.
        let page = PlexHomeViewController(mode: .collection(item("9144", kind: .collection)))
        let memberDetail = RecordingPresenter()
        memberDetail.below = page

        let opened = PlexHomeViewController.openCollectionIfNeeded(
            item("9144", kind: .collection), from: memberDetail)

        XCTAssertTrue(opened)
        XCTAssertTrue(memberDetail.presented.isEmpty, "a second page for the same collection was stacked")
    }

    func test_otherCollectionBelowPresenter_presentsNewPage() {
        let page = PlexHomeViewController(mode: .collection(item("9144", kind: .collection)))
        let memberDetail = RecordingPresenter()
        memberDetail.below = page

        let opened = PlexHomeViewController.openCollectionIfNeeded(
            item("118562", kind: .collection), from: memberDetail)

        XCTAssertTrue(opened)
        XCTAssertEqual(memberDetail.presented.count, 1)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' \
  -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/CollectionPageRoutingTests
```

Expected: the test target does not compile, with `error: type 'PlexHomeViewController' has no member 'openCollectionIfNeeded'` and `error: value of type 'PlexHomeViewController' has no member 'onDismiss'`, ending in `** TEST FAILED **`.

- [ ] **Step 3a: Implement: `onDismiss` and the stored transition delegate**

In `PlexHomeViewController.swift`, find:

```swift
    let mode: HomeMode

    init(mode: HomeMode = .home) {
```

Replace with:

```swift
    let mode: HomeMode

    /// Collection mode: runs once the page has been dismissed, never when it
    /// only covers itself with a carousel or detail. The carousel passes one
    /// that puts focus back on the below-fold tile that opened the page.
    var onDismiss: (() -> Void)?
    /// Collection mode's blur-fade transition. UIKit holds a transitioning
    /// delegate weakly, so the page keeps it alive (PersonDetailViewController
    /// does the same).
    private let blurFade = BlurFadeTransitioningDelegate()

    init(mode: HomeMode = .home) {
```

- [ ] **Step 3b: Implement: presentation style in `init(mode:)`**

Find (the only `super.init(nibName: nil, bundle: nil)` in the file):

```swift
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
```

Replace with:

```swift
        super.init(nibName: nil, bundle: nil)
        if case .collection = mode {
            // A drill-in like the person page and the standalone detail: the
            // shell has no navigation controller, so it blur-fades in over
            // whatever presented it.
            modalPresentationStyle = .overFullScreen
            transitioningDelegate = blurFade
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }
```

- [ ] **Step 3c: Implement: fire `onDismiss` from `viewDidDisappear`**

Find:

```swift
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stop taking Menu presses the moment the page leaves the screen, and
        // keep the handler list from growing by one per page visited. A fresh
        // appearance re-registers.
        MenuPressInterceptor.resign(self)
    }
```

Replace with:

```swift
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        // Stop taking Menu presses the moment the page leaves the screen, and
        // keep the handler list from growing by one per page visited. A fresh
        // appearance re-registers.
        MenuPressInterceptor.resign(self)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        // Only a real dismissal. A carousel presented over the collection page
        // (.overFullScreen) never makes it disappear at all.
        if isBeingDismissed { onDismiss?() }
    }
```

- [ ] **Step 3d: Implement: anchor at the top of `preferredFocusEnvironments`**

Find:

```swift
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // Strip idle return / letter stepping: land on the jumped-to slot.
```

Replace with:

```swift
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        // Collection page with page 0 in flight: the grid is hidden, so the
        // anchor is the only target inside this modal. Without it focus stays
        // on the library tile underneath, where the library's staged Menu back
        // would swallow Menu and arrows / Select would drive the hidden page.
        if case .collection = mode, case .loading = pageZero {
            return [collectionFocusAnchor]
        }
        // Strip idle return / letter stepping: land on the jumped-to slot.
```

- [ ] **Step 3e: Implement: `openCollectionIfNeeded` and its first call site**

Find:

```swift
    private func presentPreview(forSection section: HomeSectionData, indexPath: IndexPath) {
        guard indexPath.item < section.items.count else { return }
```

Replace with:

```swift
    /// Opens a collection tile on its own page. Returns false for anything
    /// that is not a collection, so the caller carries on as before.
    ///
    /// The walk covers the whole modal stack, not only what sits above
    /// `presenter`: a member's detail is presented ON TOP of the page it came
    /// from, so the loop page → member → trailing collection tile finds the
    /// page below it and unwinds to it instead of stacking a second one.
    @discardableResult
    static func openCollectionIfNeeded(_ item: MediaItem,
                                       from presenter: UIViewController,
                                       onDismiss: (() -> Void)? = nil) -> Bool {
        guard item.kind == .collection else { return false }
        var top = presenter
        while let presented = top.presentedViewController { top = presented }
        var node: UIViewController? = top
        while let vc = node {
            if let page = vc as? PlexHomeViewController,
               case .collection(let open) = page.mode,
               open.ref.itemID == item.ref.itemID {
                // dismiss on a presenter unwinds what it presented. On a page
                // that is already on top it would dismiss the page itself.
                if page.presentedViewController != nil { page.dismiss(animated: true) }
                return true
            }
            node = vc.presentingViewController
        }
        let page = PlexHomeViewController(mode: .collection(item))
        page.onDismiss = onDismiss
        top.present(page, animated: true)
        return true
    }

    private func presentPreview(forSection section: HomeSectionData, indexPath: IndexPath) {
        guard indexPath.item < section.items.count else { return }
        // Grid taps, every shelf row (handleShelfTap) and search
        // (handleSearchTap) all come through here. A collection never opens
        // the carousel, whose Play would hand the collection's key to the player.
        if Self.openCollectionIfNeeded(section.items[indexPath.item], from: self) { return }
```

- [ ] **Step 3f: Implement: collection tiles get no menu yet**

Find:

```swift
                                  shelfLocation: (sectionID: HomeSectionID, itemIndex: Int)? = nil) -> [[TileMenuAction]] {
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              !item.ref.itemID.isEmpty
        else { return [] }
```

Replace with:

```swift
                                  shelfLocation: (sectionID: HomeSectionID, itemIndex: Int)? = nil) -> [[TileMenuAction]] {
        // Select already opens a collection's page, and every action below
        // needs a playable item. Empty sections present no popup.
        if item.kind == .collection { return [] }
        guard let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken,
              !item.ref.itemID.isEmpty
        else { return [] }
```

The branch sits before the credentials guard, so Task 8's replacement does not depend on a server token.

- [ ] **Step 3g: Implement: the carousel call site with the pre-present arm**

In `PreviewCarouselViewController.swift`, find:

```swift
    private func presentStandaloneDetail(_ item: MediaItem) {
        // The standalone detail is presented .overFullScreen, so THIS controller
```

Replace with:

```swift
    private func presentStandaloneDetail(_ item: MediaItem) {
        // A collection tile opens the collection page. Arm the shelf row's
        // restore first, while the tile still exists: the carousel cannot
        // resolve focus while the page is up, and on dismissal the engine
        // may resolve before any callback runs. The page's onDismiss re-arms
        // and applies it, so focus returns to the tile with the row unscrolled.
        // No focus request here: focus is still on the tile, so a request
        // would be honoured now and spend the row's one-shot tile index.
        if item.kind == .collection {
            expandedDetail.restoreShelfRowFocusIfNeeded(requestingFocus: false)
            PlexHomeViewController.openCollectionIfNeeded(item, from: self) { [weak self] in
                self?.restoreBelowFoldFocusAfterReturn()
            }
            return
        }
        // The standalone detail is presented .overFullScreen, so THIS controller
```

- [ ] **Step 3h: Implement: the page owns Menu from the start of its fade**

The page registers its Menu handler in `viewDidAppear`, after the 0.45s blur-fade. During the fade focus can still sit on the library tile, and `MenuPressInterceptor` withholds Menu in `UIWindow.sendEvent`, before any responder or gesture recognizer. The library's handler would pass its containment check and run its staged back under the modal (the `cfb44f1` class). Registering in `viewWillAppear` puts the page first in the handler list, and it drops Menu until its first `viewDidAppear` (a dismiss during a presentation is ignored by UIKit anyway). `hasMarkedFirstFrame` is set only by that first `viewDidAppear`, and a collection page appears once: a carousel over it is `.overFullScreen`, so it never disappears.

In `PlexHomeViewController.swift`, find:

```swift
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasMarkedFirstFrame {
```

Replace with:

```swift
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // Collection page: own Menu from the start of the blur-fade (see
        // handleMenuBack). The library that presented it already installed
        // the interceptor; viewDidAppear registering again is harmless.
        if case .collection = mode { MenuPressInterceptor.register(self) }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !hasMarkedFirstFrame {
```

Find:

```swift
    func handleMenuBack() -> Bool {
        guard isViewLoaded, let window = view.window, window.isKeyWindow else { return false }
```

Replace with:

```swift
    func handleMenuBack() -> Bool {
        // Collection page mid blur-fade: asked before the library under it,
        // whose tile may still hold focus. Drop the press. Before the window
        // guard, because the page's view may not be in the window yet.
        if case .collection = mode, !hasMarkedFirstFrame { return true }
        guard isViewLoaded, let window = view.window, window.isKeyWindow else { return false }
```

- [ ] **Step 3i: Implement: arm a shelf tile without a focus request**

`ShelfRowCell.prepareFocusRestore(on:)` sets the one-shot `pendingFocusIndex` and calls `setNeedsFocusUpdate()`. Step 3g's arm runs while focus is on the trailing tile, so the shelf contains focus, the request is honoured, and resolving it reads `preferredFocusEnvironments`, which clears `pendingFocusIndex`. The dismissal's fresh resolution would then reach the armed shelf with no index and fall back to `[rowCollectionView]` (`remembersLastFocusedIndexPath = false`), a default tile. Home's modal path already avoids this with the layout-only `prepareFocusRestoreLayout`.

In `Rivulet/Views/Media/UIKit/Cells/ShelfRowCell.swift`, find:

```swift
    func prepareFocusRestore(on itemIndex: Int) {
        pendingFocusIndex = itemIndex
        prepareFocusRestoreLayout(on: itemIndex)
        setNeedsFocusUpdate()
    }
```

Replace with:

```swift
    func prepareFocusRestore(on itemIndex: Int) {
        armFocusRestore(on: itemIndex)
        setNeedsFocusUpdate()
    }

    /// Arm the tile for the next focus resolution without requesting one.
    /// For a caller that still holds focus inside this row: a request would
    /// be honoured at once and spend `pendingFocusIndex` before it is needed.
    func armFocusRestore(on itemIndex: Int) {
        pendingFocusIndex = itemIndex
        prepareFocusRestoreLayout(on: itemIndex)
    }
```

In `Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldCollectionView.swift`, find:

```swift
    func restoreShelfRowFocusIfNeeded() {
```

Replace with:

```swift
    func restoreShelfRowFocusIfNeeded(requestingFocus: Bool = true) {
```

Find:

```swift
        shelf.prepareFocusRestore(on: item)
```

Replace with:

```swift
        if requestingFocus {
            shelf.prepareFocusRestore(on: item)
        } else {
            shelf.armFocusRestore(on: item)
        }
```

In `Rivulet/Views/Media/MediaDetail/UIKit/ExpandedDetailContainerView.swift`, find:

```swift
    func restoreShelfRowFocusIfNeeded() {
        belowFoldCollection.restoreShelfRowFocusIfNeeded()
    }
```

Replace with:

```swift
    func restoreShelfRowFocusIfNeeded(requestingFocus: Bool = true) {
        belowFoldCollection.restoreShelfRowFocusIfNeeded(requestingFocus: requestingFocus)
    }
```

Every existing caller keeps the default, so their behaviour is unchanged.

- [ ] **Step 4: Run it to verify it passes**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' \
  -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/CollectionPageRoutingTests
```

Expected: `Executed 4 tests, with 0 failures` and `** TEST SUCCEEDED **`. Then rerun the Menu rule tests, which this task leans on without changing. The file is `StagedMenuBackTests.swift`, but `-only-testing` matches class names, and a filter that matches nothing still reports `** TEST SUCCEEDED **`: `-only-testing:RivuletTests/StagedMenuBackPolicyTests -only-testing:RivuletTests/MenuPressSwallowStateTests`. Expected: both suites report passed with a non-zero test count, then `** TEST SUCCEEDED **`.

- [ ] **Step 5: Build and lint**

RivuletCore is untouched, so no `Rivulet iOS` build is needed. The Step 4 run already built the tvOS app. Run:

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && swiftlint lint --strict
git diff -U0 -- Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift Rivulet/Views/Media/PreviewCarousel/UIKit/PreviewCarouselViewController.swift Rivulet/Views/Media/UIKit/Cells/ShelfRowCell.swift Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldCollectionView.swift Rivulet/Views/Media/MediaDetail/UIKit/ExpandedDetailContainerView.swift | grep '^+' | grep -nE $'\xe2\x80\x93|\xe2\x80\x94'
grep -nE $'\xe2\x80\x93|\xe2\x80\x94' RivuletTests/Unit/CollectionPageRoutingTests.swift
```

Expected: `Found 0 violations`, and the dash check prints nothing. No SwiftUI import was added to any UIKit surface.

- [ ] **Step 6: Device verification (Apple TV; Simulator focus results are provisional)**

You can't reach a collection tile after this task alone: search filters collections out, and library and Home hubs show only members. So 6a to 6f and 6i run on the first build that has Task 5's Collections row (with Task 3, Step 6, checks 5 to 7b), and again for the grid after Task 6. 6g and 6h run after Task 10 adds the detail's trailing tile. Record the results against this task. Commit now (Step 7); don't hold the commit for these checks.

Run the `Rivulet` scheme in Debug on the Apple TV from Xcode. Use a Siri Remote for every check, then repeat 6b and 6d with a clickpad-only or IR/CEC remote (arrow presses only) and the iPhone Remote (swipes only).

- 6a. **Open.** In Movies, move to the Collections row, focus "James Bond" (rk 9144) and press Select. Expected: the page blur-fades in over the library, shows its title header, and focus moves to the first grid tile ("Dr. No") once page 0 arrives. The carousel never appears. After Task 6, repeat from a tile in the Collections grid (header switch set to Collections).
- 6b. **Menu from any tile, focus back on the library.** On the page, press Menu from a first-row tile. Expected: the page fades out, and focus returns to the James Bond tile in the Collections row. The library keeps its scroll position. Open the page again, move down three grid rows, press Menu. Expected: the page dismisses on the first press. It doesn't return to the top row first.
- 6c. **Tile menu and Play.** Long-press Select on a collection tile in the Collections row (and in the Collections grid after Task 6). Expected: no popup (Task 8 later adds Pin to Home here). With no popup to take focus, the release can reach the tile as a Select and open the collection page, which is the same as a click and is correct (Settings needed `suppressNextSelect` for the same trailing Select). Press Play/Pause on the same tile. Expected: nothing plays.
- 6d. **Loading window.** Stretch the load: on the Apple TV, Settings > Developer > Network Link Conditioner, profile "Very Bad Network". If that menu is missing, use Xcode's Devices and Simulators window > this Apple TV > Device Conditions > Network Link > Very Bad Network. Focus a genre row tile (below the Collections row) and press Select on a collection tile, then while the loading state shows:
  - Press Down, Left, Right, and swipe on the touch surface. Expected: nothing moves, and the library under the blur doesn't scroll.
  - Press Select. Expected: no carousel opens over the loading page.
  - Press Menu. Expected: the page dismisses. The library under it stays at the same scroll position and doesn't jump to its hero. The sidebar doesn't expand.
  - Press Menu again. Expected: the normal staged back (library returns to its top row), which shows no stale state was left behind.
  Turn the conditioner off afterwards.
- 6e. **Member round trip.** On the page, press Select on a member. Expected: the preview carousel opens. Press Menu. Expected: focus returns to that member's grid tile on the collection page, and the page is still up.
- 6f. **Try Again (with Task 3).** With the conditioner at 100% loss, open a collection. Wait for the error state and select Try Again. Expected: while it reloads, focus sits on the anchor (Menu still dismisses as in 6d). Turn loss off, Try Again, and focus moves to grid item 0.
- 6g. **Detail trailing tile (after Task 10).** Open "Raiders of the Lost Ark" from the library and scroll its "IMDb Top 250 Collection" row to its end. Press Select on the trailing collection tile. Expected: the collection page opens. Press Menu. Expected: focus is back on the trailing tile and the row is still scrolled to its end. It doesn't jump to the first member. (Diamonds Are Forever has only 4 Bond members, so its row has no trailing tile.)
- 6h. **Same-page unwind (after Task 10).** From the IMDb Top 250 collection page, open a member (Forrest Gump), expand to its detail, scroll to its "IMDb Top 250 Collection" row, press Select on the trailing tile. Expected: the detail closes back to the existing collection page, with no second page stacked. One Menu press from the page returns to where it was opened from.
- 6i. **Impatient presses during the fade in (Review Focus 3).** On the normal network, focus a Collections row tile, press Select and then Menu as fast as possible (within half a second). Expected: Menu during the fade does nothing (Step 3h drops it), so the page finishes opening and stays up; the library under it does not scroll and the sidebar does not expand. A second Menu dismisses the page, focus is back on the same library tile at the same scroll position, and a third Menu gives the library's normal staged back. Repeat with Select then Select: expected the page opens with focus on its first tile and no carousel opens under or over it. Repeat both with the Network Link Conditioner at Very Bad Network.

If a check fails:
- 6b loses the tapped tile, or focus goes elsewhere (this can happen when a hub refresh re-vends the tile while the page is up). Apply the spec's fallback in `presentPreview`: replace the single `openCollectionIfNeeded` line from Step 3e with
  ```swift
          let tapped = section.items[indexPath.item]
          if tapped.kind == .collection {
              pendingPreviewRestore = PreviewSourceTarget(rowID: section.id.raw,
                                                          itemID: sourceItemIDs(for: section)[indexPath.item])
          }
          if Self.openCollectionIfNeeded(tapped, from: self, onDismiss: { [weak self] in
              self?.applyPendingPreviewRestoreIfNeeded()
          }) { return }
  ```
  Then rerun 6b.
- 6b, 6d or 6i Menu doesn't dismiss the page after the fade has finished (the press is swallowed, or reaches the library or sidebar). A `.menu` tap recognizer cannot fix this: `MenuPressInterceptor` withholds a consumed press in `UIWindow.sendEvent`, before any gesture recognizer. Dismiss from the page's own handler instead, which runs first. In `handleMenuBack`, find:
  ```swift
          // Focus must be inside THIS page's collection. When a player, detail
  ```
  Replace with:
  ```swift
          // Collection page: Menu with focus anywhere on the page closes it.
          // A carousel over the page holds focus itself, so this declines there.
          if case .collection = mode,
             let focused = UIFocusSystem.focusSystem(for: collectionView)?.focusedItem as? UIView,
             focused.isDescendant(of: view) {
              dismiss(animated: true)
              return true
          }
          // Focus must be inside THIS page's collection. When a player, detail
  ```
  Rerun 6b, 6d, 6e and 6i (6e must still close only the carousel).
- 6g puts focus on another tile in the row, or the row scrolls back to its start. The page's `onDismiss` may run before the engine's own resolution and clear the arm first. Defer the restore by one runloop in Step 3g: replace `self?.restoreBelowFoldFocusAfterReturn()` inside the `openCollectionIfNeeded` closure with `DispatchQueue.main.async { self?.restoreBelowFoldFocusAfterReturn() }`, then rerun 6g and 6h. If it still fails, stop and report; the trailing tile does not ship (Task 10 check 3 depends on it).

- [ ] **Step 7: Commit**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
git add Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift \
        Rivulet/Views/Media/PreviewCarousel/UIKit/PreviewCarouselViewController.swift \
        Rivulet/Views/Media/UIKit/Cells/ShelfRowCell.swift \
        Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldCollectionView.swift \
        Rivulet/Views/Media/MediaDetail/UIKit/ExpandedDetailContainerView.swift \
        RivuletTests/Unit/CollectionPageRoutingTests.swift
[ "$(git branch --show-current)" = test/integration ] && \
[ "$(git diff --cached --name-only | sort)" = "$(printf '%s\n' \
    Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift \
    Rivulet/Views/Media/PreviewCarousel/UIKit/PreviewCarouselViewController.swift \
    Rivulet/Views/Media/UIKit/Cells/ShelfRowCell.swift \
    Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldCollectionView.swift \
    Rivulet/Views/Media/MediaDetail/UIKit/ExpandedDetailContainerView.swift \
    RivuletTests/Unit/CollectionPageRoutingTests.swift | sort)" ] && \
git commit -m "Open collections on their own page"
```

If Step 0 found foreign hunks in any of the Swift files, stage that file with `git apply --cached` from your patch instead of `git add`, then run the same gated commit.

---

### Task 5: Library Collections row

Implements spec §5.3 and the §9 library-row checks. It ships with Task 1 (artwork separator, which the composite collection posters need) and Tasks 3 and 4 (the collection page, reached through `presentPreview`) already committed.

**Files:**
- Modify: `Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift`. Symbols: `HomeSectionID` (~line 49), stored properties next to `libraryHubsError` (~442), `refreshThisLibraryHubs()` (~1146), `computeLibrarySections(libraryKey:libraryTitle:)` (~3478), `isRecentRow(_:)` (~3535). Line numbers are from HEAD `7aa86fb` and will have moved after Tasks 3 and 4. Find each edit by its quoted text.
- Test: `RivuletTests/Unit/LibraryCollectionsRowTests.swift`. This goes at the `Unit/` root beside `HomeRecentlyAddedCarryOverTests.swift`, `HomePromotedHubRowsTests.swift` and `LibraryAlphabetIndexTests.swift`, because the repo's Home and library tests already live there. The synchronized group adds it to the target.

**Interfaces:**
- Consumes:
  - `PlexNetworkManager.getLibraryItemsWithTotal(serverURL:authToken:sectionId:start:size:sort:type:includeGuids:) async throws -> (items: [PlexMetadata], totalSize: Int?)`. It already exists and is unchanged. It sends Start together with Size, so paging works.
  - `PlexMediaMapper.artworkURL(_:serverURL:authToken:)` with Task 1's `?` / `&` separator. Composite thumbs (`/library/collections/{rk}/composite/{ts}?width=400&height=600`) need it.
  - Tasks 3 and 4: `presentPreview(forSection:indexPath:)` calls `openCollectionIfNeeded` right after its bounds guard, so a Collections-row tap opens the collection page. Task 4 makes the `.collection` tile menu return `[]`. This task calls neither one directly.
- Produces (Tasks 6, 7 and 8 rely on these):
  - `private var libraryCollections: [PlexMetadata] = []` on `PlexHomeViewController`.
  - `static let libraryCollections = HomeSectionID(raw: "collections")`.
  - `nonisolated static func collectionsRowInsertionIndex(rows: [(isContinueWatching: Bool, isRecent: Bool)]) -> Int` on `PlexHomeViewController`.
  - Inside `refreshThisLibraryHubs`, the success branch `if let result = try? await collectionsFetch { ... }` ending in `libraryCollections = collections`, the `collectionsChanged` flag, and a function tail of `if collectionsChanged { refreshSortHeaderCount() }`, `selectHeroItemsIfNeeded()`, `updateHomeState()`. Task 6 appends `syncCollectionsGrid()` to that tail (§5.4 compares against the grid's own copy, not this flag). Task 7 adds `HomeCollectionPins.updateTitles(from:libraryUUID:)` inside the success branch, after `libraryCollections = collections`, on every successful fetch: a rename keeps the ratingKey, so a call behind `collectionsChanged` would never see one, and `updateTitles` writes nothing when no title differs. `HomeCollectionPins` does not exist until Task 7, so this task leaves that call out.
  - Two private helpers placed directly after `refreshThisLibraryHubs`: `applySnapshotKeepingFocusedRowStill()` and `firstItemMinY(ofSection:)`. They sit between that function and `// MARK: - Library grid data`, so later tasks must not anchor on that MARK line.

- [ ] **Step 1: Write the failing test**

Before you start: `git diff Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift` must print nothing. If it shows another session's hunks, use the hunk-only patch route from the global constraints at Step 7.

Create `RivuletTests/Unit/LibraryCollectionsRowTests.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LibraryCollectionsRowTests.swift
//  RivuletTests
//
//  Where a library page puts its Collections row among its hub rows. Row
//  flags mirror the hub orders measured on PMS 1.43.4 (Movies: inprogress,
//  recentlyreleased, recentlyadded, genre...). An admin can reorder hubs in
//  Plex's Manage Recommendations, and a promotion adds a custom.collection
//  hub, so a discovery row can come before Continue Watching.
//

import XCTest
@testable import Rivulet

final class LibraryCollectionsRowTests: XCTestCase {
    private typealias Row = (isContinueWatching: Bool, isRecent: Bool)
    private let cw: Row = (isContinueWatching: true, isRecent: false)
    private let recent: Row = (isContinueWatching: false, isRecent: true)
    private let other: Row = (isContinueWatching: false, isRecent: false)

    private func index(_ rows: [Row]) -> Int {
        PlexHomeViewController.collectionsRowInsertionIndex(rows: rows)
    }

    /// Measured Movies order: the row follows Recently Added.
    func test_measuredOrder_followsLastRecentRow() {
        XCTAssertEqual(index([cw, recent, recent, other]), 3)
    }

    func test_onlyDiscoveryRows_goesFirst() {
        XCTAssertEqual(index([other]), 0)
    }

    func test_essentialRowsOnly_goesLast() {
        XCTAssertEqual(index([cw, recent]), 2)
    }

    func test_noHubRows_goesFirst() {
        XCTAssertEqual(index([]), 0)
    }

    /// Recent Rows off: the gate drops the recent rows before this runs.
    func test_recentRowsOff_followsContinueWatching() {
        XCTAssertEqual(index([cw, other]), 1)
    }

    /// A genre hub moved above Continue Watching must not drag the row up.
    func test_discoveryRowAboveContinueWatching_stillFollowsRecentRow() {
        XCTAssertEqual(index([other, cw, recent]), 3)
    }

    /// A promoted custom.collection hub ahead of Continue Watching.
    func test_promotedCollectionHubFirst_stillFollowsRecentRow() {
        XCTAssertEqual(index([other, cw, recent, other]), 3)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' \
  -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/LibraryCollectionsRowTests
```

Expected: the build fails with `error: type 'PlexHomeViewController' has no member 'collectionsRowInsertionIndex'`, then `** TEST FAILED **`.

- [ ] **Step 3: Implement**

**3.1 Section id.** In `HomeSectionID`, find:

```swift
    static let sortHeader = HomeSectionID(raw: "sortHeader")
    static let grid = HomeSectionID(raw: "grid")
```

Replace with:

```swift
    static let sortHeader = HomeSectionID(raw: "sortHeader")
    static let grid = HomeSectionID(raw: "grid")
    /// Library-mode-only: the library's Collections shelf. Each library key
    /// has its own cached controller, so the id cannot collide.
    static let libraryCollections = HomeSectionID(raw: "collections")
```

**3.2 Stored list.** Find:

```swift
    private var isLoadingLibraryHubs = false
    private var libraryHubsError: String?
```

Replace with:

```swift
    private var isLoadingLibraryHubs = false
    private var libraryHubsError: String?
    /// This library's non-empty collections in server order, filled by
    /// refreshThisLibraryHubs. Feeds the Collections row. Kept as-is when a
    /// fetch fails.
    private var libraryCollections: [PlexMetadata] = []
```

**3.3 Placement static.** Find the end of `isRecentRow`:

```swift
            || id.contains("newestreleases") || title.contains("newest releases")
    }
```

Replace with:

```swift
            || id.contains("newestreleases") || title.contains("newest releases")
    }

    /// Where the Collections row goes among a library's hub rows: right after
    /// the LAST Continue Watching or recent row, else first. Keyed on the
    /// last essential row so a genre or promoted-collection hub that an
    /// admin moved above them cannot pull Collections up with it.
    nonisolated static func collectionsRowInsertionIndex(rows: [(isContinueWatching: Bool, isRecent: Bool)]) -> Int {
        rows.lastIndex { $0.isContinueWatching || $0.isRecent }.map { $0 + 1 } ?? 0
    }
```

**3.4 Row in `computeLibrarySections`.** Two edits.

First, find:

```swift
        for hub in dataStore.libraryItemsByKey[key] ?? [] {
            if !showRecentRows, isRecentRow(hub) { continue }
            if !showDiscoveryRows, !isEssentialRow(hub) { continue }
            let id = HomeSectionID(raw: hub.id)
```

Replace with:

```swift
        let firstHubRow = sections.count
        var hubRowKinds: [(isContinueWatching: Bool, isRecent: Bool)] = []
        for hub in dataStore.libraryItemsByKey[key] ?? [] {
            if !showRecentRows, isRecentRow(hub) { continue }
            if !showDiscoveryRows, !isEssentialRow(hub) { continue }
            hubRowKinds.append((isContinueWatching: hub.isContinueWatching, isRecent: isRecentRow(hub)))
            let id = HomeSectionID(raw: hub.id)
```

Second, find:

```swift
        // Below the hub rows: the sort header (library title + count + sort
```

Replace with:

```swift
        // Collections: placed after the gates, so it follows whatever CW and
        // recent rows survive. Not part of projectLibraryItems (that rail is
        // written to disk and re-projected without this list), so it has no
        // warm-launch cache and arrives with refreshThisLibraryHubs. No
        // hubKey, so loadMoreIfNeeded never pages it.
        if !libraryCollections.isEmpty {
            sections.insert(.hub(
                id: .libraryCollections,
                title: "Collections",
                items: mapToMediaItems(libraryCollections),
                isContinueWatching: false,
                hubKey: nil,
                hubIdentifier: nil,
                totalSize: libraryCollections.count
            ), at: firstHubRow + Self.collectionsRowInsertionIndex(rows: hubRowKinds))
        }

        // Below the hub rows: the sort header (library title + count + sort
```

There is no type guard. Only movie and show libraries reach `.library` mode (music goes to `MusicHomeView`). `observeUserDefaults` needs no change, because a Recent Rows toggle re-runs this method.

**3.5 Fetch in `refreshThisLibraryHubs`.** Find the whole function body, from its signature to its closing brace. Leave the doc comment above it untouched:

```swift
    private func refreshThisLibraryHubs() async {
        guard case .library(let key, _) = mode,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        isLoadingLibraryHubs = (dataStore.libraryHubs[key] == nil)
        updateHomeState()
        do {
            let hubs = try await PlexNetworkManager.shared.getLibraryHubs(
                serverURL: serverURL, authToken: token, sectionId: key
            )
            dataStore.libraryHubs[key] = hubs
            // Project to the MediaItem rail the library page now renders from
            // (Stage 2 reads dataStore.libraryItemsByKey[key]). This also bumps
            // libraryHubsVersion + writes the flat library cache for next launch.
            dataStore.projectLibraryItems(forKey: key)
            libraryHubsError = nil
        } catch {
            // Keep stale content if we have any; only surface the error when
            // there's nothing to show (mirrors the home's hubsError handling).
            if (dataStore.libraryHubs[key] ?? []).isEmpty {
                libraryHubsError = error.localizedDescription
            }
        }
        isLoadingLibraryHubs = false
        applySnapshot(animated: false)
        selectHeroItemsIfNeeded()
        updateHomeState()
    }
```

Replace with:

```swift
    private func refreshThisLibraryHubs() async {
        guard case .library(let key, _) = mode,
              let serverURL = authManager.selectedServerURL,
              let token = authManager.selectedServerToken else { return }
        isLoadingLibraryHubs = (dataStore.libraryHubs[key] == nil)
        updateHomeState()
        // The Collections list (type 18), fetched beside the hubs and awaited
        // before the apply. No sort: the server's titleSort order is
        // Kometa's curation.
        // ponytail: one page of 1000; a library with more collections is
        // truncated. Page on totalSize if one ever gets there.
        async let collectionsFetch = PlexNetworkManager.shared.getLibraryItemsWithTotal(
            serverURL: serverURL, authToken: token, sectionId: key,
            start: 0, size: 1000, type: 18
        )
        do {
            let hubs = try await PlexNetworkManager.shared.getLibraryHubs(
                serverURL: serverURL, authToken: token, sectionId: key
            )
            dataStore.libraryHubs[key] = hubs
            // Project to the MediaItem rail the library page now renders from
            // (Stage 2 reads dataStore.libraryItemsByKey[key]). This also bumps
            // libraryHubsVersion + writes the flat library cache for next launch.
            dataStore.projectLibraryItems(forKey: key)
            libraryHubsError = nil
        } catch {
            // Keep stale content if we have any; only surface the error when
            // there's nothing to show (mirrors the home's hubsError handling).
            if (dataStore.libraryHubs[key] ?? []).isEmpty {
                libraryHubsError = error.localizedDescription
            }
        }
        // Assigned only on success: a failed fetch keeps the previous list and
        // never surfaces as a library error. `childCount > 0` drops the empty
        // ones (Kometa separators, emptied lists) at no request cost.
        var collectionsChanged = false
        if let result = try? await collectionsFetch {
            let collections = result.items.filter { ($0.childCount ?? 0) > 0 }
            // Every player exit comes through here and the list almost never
            // changes then, so an equal ratingKey sequence skips the follow-ups.
            collectionsChanged = collections.map(\.ratingKey) != libraryCollections.map(\.ratingKey)
            libraryCollections = collections
        }
        isLoadingLibraryHubs = false
        applySnapshotKeepingFocusedRowStill()
        // The sort header's item id never changes, so the apply above never
        // re-vends it; without this it keeps whatever list it first saw.
        if collectionsChanged { refreshSortHeaderCount() }
        selectHeroItemsIfNeeded()
        updateHomeState()
    }

    /// The apply for refreshThisLibraryHubs. The Collections row has no
    /// warm-launch cache, so it is the one row routinely inserted into, or
    /// removed from, a live page. The page moves its own offset only on focus
    /// changes, so a row appearing above the focused one would push the
    /// focused tile down a whole poster row. When the row comes or goes,
    /// shift the offset by however far the apply moved the focused section.
    /// Its first item stands in for the focused cell: a section inserted
    /// above moves every item below it alike, and a focused section above
    /// the slot does not move at all.
    private func applySnapshotKeepingFocusedRowStill() {
        let hadCollectionsRow = sectionsSnapshot.contains { $0.id == .libraryCollections }
        let focusedID = focusedSectionForHandoff.flatMap { sectionsSnapshot[safe: $0]?.id }
        let minYBefore = focusedID.flatMap { firstItemMinY(ofSection: $0) }
        applySnapshot(animated: false)
        guard sectionsSnapshot.contains(where: { $0.id == .libraryCollections }) != hadCollectionsRow,
              let focusedID, let minYBefore else { return }
        collectionView.layoutIfNeeded()
        guard let minYAfter = firstItemMinY(ofSection: focusedID) else { return }
        let oldY = collectionView.contentOffset.y
        let newY = max(-collectionView.adjustedContentInset.top, oldY + minYAfter - minYBefore)
        collectionView.contentOffset.y = newY
        // A focus scroll in flight re-derives the offset every frame from its
        // endpoints; move them too or the next tick undoes the shift.
        if offsetLink != nil {
            offsetStartY += newY - oldY
            offsetTargetY += newY - oldY
        }
    }

    private func firstItemMinY(ofSection id: HomeSectionID) -> CGFloat? {
        guard let section = sectionsSnapshot.firstIndex(where: { $0.id == id }) else { return nil }
        return collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: section))?.frame.minY
    }
```

Checked against the file:
- `focusedSectionForHandoff` (an internal var in the class body) resolves a tile inside a shelf row's nested collection view to the outer section.
- `sectionsSnapshot[safe:]` is already used by `loadAlphabetIndex`.
- `offsetLink`, `offsetStartY` and `offsetTargetY` are stored in the class body. `stepOffset` rebuilds the offset from them on every tick. `stepFastScroll` reads the live offset, so it needs no shift.
- `libraryCollections` is assigned only here, with no suspension point between that assignment and the apply. The presence gate therefore fires exactly on the apply that adds or drops the row, even when the coalesced `setNeedsSnapshotApply` from `projectLibraryItems` runs during the `await`.

- [ ] **Step 4: Run it to verify it passes**

```bash
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' \
  -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/LibraryCollectionsRowTests
```

Expected: `Executed 7 tests, with 0 failures` and `** TEST SUCCEEDED **`.

- [ ] **Step 5: Build and lint**

RivuletCore is not touched, so the iOS scheme needs no build.

```bash
xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd"
swiftlint lint --strict
git diff -U0 Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift | grep '^+' | grep -nE $'\xe2\x80\x93|\xe2\x80\x94'
grep -nE $'\xe2\x80\x93|\xe2\x80\x94' RivuletTests/Unit/LibraryCollectionsRowTests.swift
```

Expected: `** BUILD SUCCEEDED **` and zero lint violations. The file sits under `Views/**/UIKit/**` and gains no SwiftUI import. The dash check prints nothing.

- [ ] **Step 6: Device verification**

Simulator focus results are provisional (CLAUDE.md), so every check below runs on an Apple TV against the home PMS (`192.168.1.140:32400`). Expected contents come from the measurements in spec §4 (2026-09-30). This is also the first build where Task 3, Step 6, checks 5 to 7b and Task 4's checks 6a to 6f and 6i can run.

1. **Placement, Movies (section 1).** Open Movies with Recent Rows and Discovery Rows on. Expected rows: Continue Watching, Recently Released, Recently Added, **Collections**, then the genre rows, sort header and grid.
2. **Contents.** Scroll the Collections row. Its order matches the Collections tab in Plex Web: the Kometa `!010_` lists (Newly Released, the IMDb lists, genre collections) come first. Empty collections are absent: Batman, Die Hard and Genre Collections do not appear, and James Bond does. Composite posters render for Cinderella, The Hobbit and Marvel Studios, which depends on Task 1. Tiles show no progress bar and no watched glyph.
3. **Placement, TV (section 2).** Expected: Continue Watching, Recently Released Episodes, Recently Added, **Collections**.
4. **Gates.** Settings > Appearance > Library, Recent Rows off: Collections sits directly after Continue Watching. Discovery Rows off: Collections still shows after the recent rows, since it is not a discovery row. Restore both.
5. **Select and menu.** Select a Collections tile: the collection page opens (Tasks 3 and 4). Menu returns to the same tile. A long press on a Collections tile opens no menu (Task 4 returns `[]`; Task 8 adds Pin).
6. **Focused tile stays still (§9).** Cold-launch to Home. Slow the network with Settings > Developer > Network Link Conditioner (Very Bad Network). That menu is present on a device paired with Xcode (moderate confidence). Open Movies for the first time this session. The rows paint from cache, but the Collections row waits for the network. Press Down at once until focus is on a genre row below Recently Added, and note its screen position. When the Collections row appears above, the focused tile does not move on screen. Press Up once: focus moves to the Collections row. Press Up again: Recently Added. Turn the conditioner off.
7. **Admin reorder (§9).** In Plex Web, go to Movies > Recommended > Manage Recommendations and drag a genre hub above Continue Watching. Relaunch Rivulet and open Movies. Expected: genre hub, Continue Watching, Recently Released, Recently Added, **Collections**. Collections still follows Recently Added and is not pulled up next to the moved hub. Restore the order in Plex Web.
8. **Equal-list refresh.** Focus a genre row tile, play any title from it and exit the player. The page does not jump, the Collections row does not flicker, and focus returns to the same tile. This exercises the `.plexDataNeedsRefresh` path with an unchanged list.

- [ ] **Step 7: Commit**

```bash
git add Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift RivuletTests/Unit/LibraryCollectionsRowTests.swift
[ "$(git branch --show-current)" = test/integration ] && [ "$(git diff --cached --name-only | sort)" = "$(printf '%s\n' Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift RivuletTests/Unit/LibraryCollectionsRowTests.swift | sort)" ] && git commit -m "Library: Collections row"
```

If Step 1's pre-check found foreign hunks in `PlexHomeViewController.swift`, stage only this task's hunks through the `git show HEAD:<path>` / `git apply --cached` route from the global constraints, then run the same gated commit. The changelog bullet ("Movie and TV libraries show a Collections row.") goes in at tag time through Task 11.

---

### Task 6: Titles / Collections switch

Rollout step 3 (spec §10). Needs Tasks 1, 3, 4 and 5 committed first: Task 5 owns `libraryCollections` and calls `refreshSortHeaderCount()` when the list changes, Task 4 routes a collection tile tap to the collection page, Task 1 fixes the composite poster URLs.

**Files:**
- Modify: `Rivulet/Views/Media/Library/UIKit/MediaLibrarySortControl.swift` (file header comment, `SortButton.configure`, `MediaLibrarySortControl` doc, `viewButton`, `onViewTapped`, `sortBesideSwitch` / `sortAtEdge`, `setup()`, `configure(title:count:sortName:collections:)`, `preferredFocusEnvironments`)
- Modify: `Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift` (`HomeSectionData.sortHeader` doc ~347, `gridShowsCollections` ~576, `refreshThisLibraryHubs` tail, `loadGridPage` ~1183, `loadAlphabetIndex` ~1250, `applySort` ~1401 plus new `resetGrid`, `setGridShowsCollections`, `syncCollectionsGrid`, `CollectionsGridUpdate`, `collectionsGridUpdate`, `.sortHeader` cell provider ~2513)
- Test: `RivuletTests/Unit/CollectionsGridUpdateTests.swift` (new, at the Unit root beside the other Home and library tests)

**Interfaces:**
- Consumes: `private var libraryCollections: [PlexMetadata] = []` (Task 5), assigned only when the fetch succeeds, with Task 5 calling `refreshSortHeaderCount()` when the list changes; Task 5's `refreshThisLibraryHubs` tail (`if collectionsChanged { refreshSortHeaderCount() }`, `selectHeroItemsIfNeeded()`, `updateHomeState()`); `openCollectionIfNeeded(_:from:onDismiss:)` called by `presentPreview(forSection:indexPath:)` right after its bounds guard (Task 4); `HomeSectionData.grid(items:title:)` with `title` defaulting to nil (Task 3); Task 3's rewritten `loadGridPage` head; the `PlexMediaMapper.artworkURL` separator fix (Task 1).
- Produces: `private var gridShowsCollections = false`, `private func resetGrid()`, `private func setGridShowsCollections(_ on: Bool)` on `PlexHomeViewController`; `MediaLibrarySortControl.configure(title: String, count: Int, sortName: String, collections: Bool?)`, `var onViewTapped: (() -> Void)?`; `SortButton.configure(sortName: String, symbol: String = "arrow.up.arrow.down")`. Also adds `nonisolated enum CollectionsGridUpdate { case unchanged, titles, hold, apply }` and `nonisolated static func collectionsGridUpdate(gridKeys: [String?], listKeys: [String?], isGridBusy: Bool) -> CollectionsGridUpdate` on `PlexHomeViewController`, plus `private func syncCollectionsGrid()`, called as the last statement of `refreshThisLibraryHubs`.

- [ ] **Step 1: Write the failing test**

Create `RivuletTests/Unit/CollectionsGridUpdateTests.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CollectionsGridUpdateTests.swift
//  RivuletTests
//
//  What a refreshed collection list does to a library grid that is showing
//  collections (the Titles / Collections switch). Grid slot ids are
//  positional, so the order of these checks decides whether the focused tile
//  can change collection under the user.
//

import XCTest
@testable import Rivulet

final class CollectionsGridUpdateTests: XCTestCase {

    private func update(grid: [String?], list: [String?], busy: Bool) -> PlexHomeViewController.CollectionsGridUpdate {
        PlexHomeViewController.collectionsGridUpdate(gridKeys: grid, listKeys: list, isGridBusy: busy)
    }

    func test_sameList_changesNothing() {
        XCTAssertEqual(update(grid: ["9144", "118562"], list: ["9144", "118562"], busy: false), .unchanged)
    }

    func test_sameList_whileBusy_changesNothing() {
        XCTAssertEqual(update(grid: ["9144"], list: ["9144"], busy: true), .unchanged)
    }

    /// The empty check beats the hold: the header hides the switch once the
    /// list is empty, so a held collections grid would have no way out.
    func test_emptiedList_returnsToTitles_evenWhileBusy() {
        XCTAssertEqual(update(grid: ["9144"], list: [], busy: true), .titles)
    }

    /// Both empty is not "unchanged": an empty collections grid with the
    /// switch hidden would be stuck until relaunch.
    func test_emptyList_withEmptyGrid_returnsToTitles() {
        XCTAssertEqual(update(grid: [], list: [], busy: false), .titles)
    }

    func test_changedList_whileBusy_holds() {
        XCTAssertEqual(update(grid: ["9144"], list: ["9144", "118562"], busy: true), .hold)
    }

    func test_changedList_whenIdle_applies() {
        XCTAssertEqual(update(grid: ["9144"], list: ["9144", "118562"], busy: false), .apply)
    }

    /// Same members in a new order: every moved slot shows a different
    /// collection, so it counts as a change.
    func test_reorderedList_applies() {
        XCTAssertEqual(update(grid: ["9144", "118562"], list: ["118562", "9144"], busy: false), .apply)
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/CollectionsGridUpdateTests
```

Expected: the test target fails to compile with `error: 'CollectionsGridUpdate' is not a member type of class 'Rivulet.PlexHomeViewController'` (and/or `type 'PlexHomeViewController' has no member 'collectionsGridUpdate'`), then `** TEST FAILED **`.

- [ ] **Step 3: Implement**

Before editing, check for another session's uncommitted hunks:

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && git diff --stat HEAD -- Rivulet/Views/Media/Library/UIKit/MediaLibrarySortControl.swift Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift
```

Expected: no output. If a file shows changes you did not make, still edit the working tree as below, and at commit time use the patch route in Step 7.

**3a. The testable decision.** In `PlexHomeViewController.swift`, replace `applySort` (doc comment included) with `applySort` + `resetGrid` + `setGridShowsCollections` + `syncCollectionsGrid` + the decision static.

Find:

```swift
    /// Persists the new sort, resets the grid (bumping the generation token
    /// so any in-flight page discards itself), and reloads the first page.
    /// The snapshot + sort-header reconfigure run immediately so the sort
    /// name flips on selection rather than after the fetch resolves.
    private func applySort(_ option: LibrarySortOption) {
        guard case .library(let key, _) = mode, option != gridSort else { return }
        gridSort = option
        LibrarySettingsManager.shared.setSortOption(option, for: key)

        gridGeneration += 1
        gridItems = []
        totalGridCount = 0

        applySnapshot(animated: false)
        refreshSortHeaderCount()
        gridPagesRequested = []
        pendingGridFocusItem = nil
        loadGridPage(containing: 0)
        loadAlphabetIndex()
    }
```

Replace with:

```swift
    /// Persists the new sort, resets the grid (bumping the generation token
    /// so any in-flight page discards itself), and reloads the first page.
    /// The snapshot + sort-header reconfigure run immediately so the sort
    /// name flips on selection rather than after the fetch resolves.
    private func applySort(_ option: LibrarySortOption) {
        guard case .library(let key, _) = mode, option != gridSort else { return }
        gridSort = option
        LibrarySettingsManager.shared.setSortOption(option, for: key)
        resetGrid()
        applySnapshot(animated: false)
        refreshSortHeaderCount()
        loadGridPage(containing: 0)
        loadAlphabetIndex()
    }

    /// Empties the grid for a new source: a sort change or the Titles /
    /// Collections switch. The generation bump makes any in-flight page
    /// discard itself. The remembered focus path goes off because it can name
    /// a slot the new grid lacks (titles slot 500 in a 71-slot collections
    /// grid), and entering the collection view on such a path moves focus
    /// nowhere. The `.grid` focus branch turns it back on.
    private func resetGrid() {
        gridGeneration += 1
        gridItems = []
        totalGridCount = 0
        gridPagesRequested = []
        pendingGridFocusItem = nil
        collectionView.remembersLastFocusedIndexPath = false
    }

    /// The Titles / Collections switch. Collections come whole from
    /// `libraryCollections` in server order: no paging, no A-Z bar, and no
    /// sort (`gridSort` is never forwarded; `sort=mediaHeight:desc` returns
    /// an empty list). Makes no focus request: the header reconfigure
    /// re-vends the same cell, so focus stays on the switch, and Down enters
    /// the grid by geometry.
    private func setGridShowsCollections(_ on: Bool) {
        gridShowsCollections = on
        resetGrid()
        if on {
            gridItems = libraryCollections
            totalGridCount = libraryCollections.count
        }
        applySnapshot(animated: false)
        refreshSortHeaderCount()
        // Required: `grid-N` ids are the same in both states, so the apply
        // alone leaves the old posters on screen.
        reconfigureGridSlots(0..<gridItems.count)
        if !on { loadGridPage(containing: 0) }
        loadAlphabetIndex()
    }

    /// Runs after every library refresh. While the grid shows collections it
    /// holds its own copy of `libraryCollections`; a refreshed list replaces
    /// that copy in place (no `resetGrid()`, which is for user toggles only)
    /// unless the grid is busy.
    private func syncCollectionsGrid() {
        guard gridShowsCollections else { return }
        // Busy: focus in the grid, or anything presented over this page (a
        // collection page opened from the grid, the tile menu popup). Slot
        // ids are positional, so a swap would repaint the focused tile, or
        // the tile focus returns to, with a different collection.
        let focusedSection = focusedSectionForHandoff
        let busy = (focusedSection != nil && focusedSection == gridSectionIndex)
            || presentedViewController != nil
        switch Self.collectionsGridUpdate(
            gridKeys: gridItems.map { $0?.ratingKey },
            listKeys: libraryCollections.map(\.ratingKey),
            isGridBusy: busy
        ) {
        case .unchanged:
            break
        case .hold:
            // ponytail: a held swap waits for the next list fetch (the next
            // .plexDataNeedsRefresh); apply it when focus leaves the grid if
            // stale collection posters ever show up in use.
            break
        case .titles:
            setGridShowsCollections(false)
        case .apply:
            gridItems = libraryCollections
            totalGridCount = libraryCollections.count
            applySnapshot(animated: false)
            refreshSortHeaderCount()
            reconfigureGridSlots(0..<gridItems.count)
        }
    }

    /// What a refreshed collection list does to a grid showing collections.
    nonisolated enum CollectionsGridUpdate { case unchanged, titles, hold, apply }

    /// An empty list returns to Titles first, even under focus and even when
    /// the grid is already empty: with no collections the header hides the
    /// switch, so an empty collections grid would have no way out. Any other
    /// change waits while the grid is busy. Order counts, because the slots
    /// are positional: a reordered list is a change.
    nonisolated static func collectionsGridUpdate(
        gridKeys: [String?], listKeys: [String?], isGridBusy: Bool
    ) -> CollectionsGridUpdate {
        if listKeys.isEmpty { return .titles }
        if gridKeys == listKeys { return .unchanged }
        return isGridBusy ? .hold : .apply
    }
```

`gridItems = libraryCollections` relies on Swift's implicit `[PlexMetadata]` to `[PlexMetadata?]` array upcast.

**3b. The state flag.** Find:

```swift
    private var pendingGridFocusItem: Int?
```

Replace with:

```swift
    private var pendingGridFocusItem: Int?
    /// Titles / Collections switch in the sort header. Session only: the
    /// shell caches one controller per library tab, so it survives tab
    /// switches and resets on relaunch. While on, `gridItems` is
    /// `libraryCollections` in server order.
    private var gridShowsCollections = false
```

**3c. `loadGridPage` goes inert in Collections state.** Task 3 rewrote this function's `guard case .library` line to admit collection mode, so the check goes on its own line, where it cannot collide with Task 3's guard. The flag is only ever true in library mode, so this behaves the same as putting it inside the library-mode guard. Find:

```swift
    private func loadGridPage(containing index: Int) {
```

Replace with:

```swift
    private func loadGridPage(containing index: Int) {
        // Collections state: the grid is `libraryCollections`, already whole,
        // so `willDisplay`'s look-ahead paging goes inert.
        guard !gridShowsCollections else { return }
```

**3d. `loadAlphabetIndex` guard goes AFTER the four reset lines.** The reset still has to run: it sets `alphabetIndex = nil` and hides the strip with `isHidden`, which the geometric occlusion rule requires. Find:

```swift
        alphabetBar.isHidden = true
        guard case .library(let key, _) = mode,
              gridSort == .titleAsc || gridSort == .titleDesc,
```

Replace with:

```swift
        alphabetBar.isHidden = true
        guard case .library(let key, _) = mode,
              !gridShowsCollections,
              gridSort == .titleAsc || gridSort == .titleDesc,
```

**3e. The list-refresh comparison hook.** Put it at the end of `refreshThisLibraryHubs`, after Task 5's apply and its focused-offset correction. Placed there, the grid's own snapshot changes can never come between Task 5's `minY` capture and its apply. Task 5 inserted two helpers between this function and `// MARK: - Library grid data`, so anchor on Task 5's tail. Find:

```swift
        if collectionsChanged { refreshSortHeaderCount() }
        selectHeroItemsIfNeeded()
        updateHomeState()
    }
```

Replace with:

```swift
        if collectionsChanged { refreshSortHeaderCount() }
        selectHeroItemsIfNeeded()
        updateHomeState()
        syncCollectionsGrid()
    }
```

It runs after a failed list fetch too. Then it compares against the last good list, which unchanged means `.unchanged`, and a hold from an earlier fetch can apply one refresh sooner under the same busy guard.

**3f. Wire the switch through the `.sortHeader` cell provider.** Find:

```swift
        case .sortHeader:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MediaLibrarySortControl.reuseID, for: indexPath) as! MediaLibrarySortControl
            cell.configure(title: section.title ?? "", count: totalGridCount, sortName: gridSort.displayName)
            cell.onSortTapped = { [weak self] in self?.presentSortPicker() }
            return cell
```

Replace with:

```swift
        case .sortHeader:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: MediaLibrarySortControl.reuseID, for: indexPath) as! MediaLibrarySortControl
            // Read only when the cell is dequeued or reconfigured, which is why
            // a changed list calls refreshSortHeaderCount(). nil hides the
            // switch: the library has no non-empty collection.
            cell.configure(
                title: section.title ?? "",
                count: totalGridCount,
                sortName: gridSort.displayName,
                collections: libraryCollections.isEmpty ? nil : gridShowsCollections
            )
            cell.onSortTapped = { [weak self] in self?.presentSortPicker() }
            cell.onViewTapped = { [weak self] in
                guard let self else { return }
                self.setGridShowsCollections(!self.gridShowsCollections)
            }
            return cell
```

**3g. Stale doc on the section builder.** Find:

```swift
    /// Library mode: the sort-header section. `title` carries the library
    /// title for `MediaLibrarySortControl.configure(title:count:sortName:)`;
    /// count + sort name live on the controller (totalGridCount / gridSort).
```

Replace with:

```swift
    /// Library mode: the sort-header section. `title` carries the library
    /// title for `MediaLibrarySortControl.configure(title:count:sortName:collections:)`;
    /// count, sort name and switch state live on the controller
    /// (totalGridCount / gridSort / gridShowsCollections).
```

**3h. `SortButton` gains a symbol.** In `MediaLibrarySortControl.swift`, find:

```swift
    func configure(sortName: String) {
        sortLabel.text = sortName
    }
```

Replace with:

```swift
    func configure(sortName: String, symbol: String = "arrow.up.arrow.down") {
        sortLabel.text = sortName
        iconView.image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
    }
```

**3i. File header comment.** Find:

```swift
//  Layout: library title (left, 34pt bold) + item count (below, 17pt dimmed) and
//  a focusable sort button (right, glass style). The CELL itself is not focusable;
//  only the embedded SortButton receives focus.
```

Replace with:

```swift
//  Layout: library title (left, 34pt bold) + item count (below, 17pt dimmed) and,
//  on the right in glass style, a focusable sort button and the Titles /
//  Collections switch (outermost). The CELL itself is not focusable; only the
//  two embedded SortButtons receive focus.
```

**3j. Cell doc, `viewButton`, `onViewTapped`, the two sort-button trailing constraints.** Find:

```swift
/// Full-width UICollectionViewCell hosting the library title, item count, and
/// a focusable sort button. The CELL is not focusable; only the SortButton is.
```

Replace with:

```swift
/// Full-width UICollectionViewCell hosting the library title, item count, a
/// focusable sort button and the Titles / Collections switch. The CELL is not
/// focusable; only the two SortButtons are.
```

Then find:

```swift
    private let sortButton: SortButton = {
        let b = SortButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    // MARK: - Public API

    /// Called by the ViewController when the sort action sheet should appear (Task 10).
    var onSortTapped: (() -> Void)? {
        get { sortButton.onSortTapped }
        set { sortButton.onSortTapped = newValue }
    }
```

Replace with:

```swift
    private let sortButton: SortButton = {
        let b = SortButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    /// Titles / Collections switch: shows the current state, Select flips it.
    /// A SortButton, so the glass focus, select debounce and press overrides
    /// come with it.
    private let viewButton: SortButton = {
        let b = SortButton()
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    /// The sort button's trailing edge: beside the switch while both show,
    /// otherwise at the cell edge (alone, or hidden under the switch). Not a
    /// UIStackView: its hiding constraint (width 0, required) fights
    /// SortButton's required internal padding and logs a conflict each toggle.
    private lazy var sortBesideSwitch: NSLayoutConstraint = sortButton.trailingAnchor.constraint(
        equalTo: viewButton.leadingAnchor, constant: -16)
    private lazy var sortAtEdge: NSLayoutConstraint = sortButton.trailingAnchor.constraint(
        equalTo: contentView.trailingAnchor, constant: -32)

    // MARK: - Public API

    /// Called by the ViewController when the sort action sheet should appear (Task 10).
    var onSortTapped: (() -> Void)? {
        get { sortButton.onSortTapped }
        set { sortButton.onSortTapped = newValue }
    }

    /// Called when the Titles / Collections switch is selected.
    var onViewTapped: (() -> Void)? {
        get { viewButton.onSortTapped }
        set { viewButton.onSortTapped = newValue }
    }
```

**3k. Layout.** Find the whole `setup()`:

```swift
    private func setup() {
        // Cell must NOT be focusable; only sortButton is.
        contentView.addSubview(titleLabel)
        contentView.addSubview(countLabel)
        contentView.addSubview(sortButton)

        NSLayoutConstraint.activate([
            // Title: left-aligned, vertically centered on the top text cluster.
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),

            // Count: just below the title, same left edge.
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            countLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            // Sort button: right edge, vertically centered, fixed size.
            sortButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),
            sortButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            sortButton.heightAnchor.constraint(equalToConstant: 44),
            sortButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            // Keep sort button from overrunning the title.
            sortButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
        ])
    }
```

Replace with:

```swift
    private func setup() {
        // Cell must NOT be focusable; only the two buttons are.
        contentView.addSubview(titleLabel)
        contentView.addSubview(countLabel)
        contentView.addSubview(sortButton)
        contentView.addSubview(viewButton)

        NSLayoutConstraint.activate([
            // Title: left-aligned, vertically centered on the top text cluster.
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 32),
            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20),

            // Count: just below the title, same left edge.
            countLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            countLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            // Switch: pinned to the right edge, so it never moves under focus
            // when the sort button hides.
            viewButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -32),
            viewButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            viewButton.heightAnchor.constraint(equalToConstant: 44),
            viewButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            // Sort button: left of the switch, or at the edge (configure()
            // swaps these two). Starts at the edge: no switch until the
            // collection list arrives.
            sortAtEdge,
            sortButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            sortButton.heightAnchor.constraint(equalToConstant: 44),
            sortButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),

            // Keep the buttons from overrunning the title. Both stay active: a
            // hidden sort button parks under the switch, so either way the
            // leftmost visible button binds.
            sortButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
            viewButton.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 16),
        ])
    }
```

**3l. Configure and focus.** Find:

```swift
    func configure(title: String, count: Int, sortName: String) {
        titleLabel.text = title
        countLabel.text = "\(count) items"
        sortButton.configure(sortName: sortName)
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { false }

    // Forward focus to the sort button (so the engine lands there on Up/Down into
    // this section rather than skipping past it entirely).
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [sortButton]
    }
```

Replace with:

```swift
    /// `collections`: nil hides the switch (the library has no non-empty
    /// collection); false shows "Titles" with "N items"; true shows
    /// "Collections" with "N collections" and hides the sort button, which
    /// also takes it out of the focus graph.
    func configure(title: String, count: Int, sortName: String, collections: Bool?) {
        titleLabel.text = title
        countLabel.text = collections == true ? "\(count) collections" : "\(count) items"
        sortButton.configure(sortName: sortName)
        sortButton.isHidden = collections == true
        viewButton.isHidden = collections == nil
        viewButton.configure(
            sortName: collections == true ? "Collections" : "Titles",
            symbol: collections == true ? "square.stack" : "square.grid.2x2")
        // Deactivate before activate, so the two are never active together.
        let beside = collections == false
        NSLayoutConstraint.deactivate([beside ? sortAtEdge : sortBesideSwitch])
        NSLayoutConstraint.activate([beside ? sortBesideSwitch : sortAtEdge])
    }

    // MARK: - Focus

    override var canBecomeFocused: Bool { false }

    // Forward focus to the buttons (so the engine moves there on Up/Down into
    // this section rather than skipping past it entirely). A hidden sort button
    // is not focusable, so a programmatic request falls through to the switch.
    override var preferredFocusEnvironments: [UIFocusEnvironment] {
        [sortButton, viewButton]
    }
```

Focus notes for later work: the swap makes no focus request, and the existing `.grid` branch of `didUpdateFocusIn` turns `remembersLastFocusedIndexPath` back on once focus enters the grid. Any later programmatic move into the grid must use `UIFocusSystem.focusSystem(for: view)?.requestFocusUpdate(to:)`, never `setNeedsFocusUpdate` from outside the focused environment.

- [ ] **Step 4: Run it to verify it passes**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/CollectionsGridUpdateTests
```

Expected: `Executed 7 tests, with 0 failures`, then `** TEST SUCCEEDED **`.

- [ ] **Step 5: Build and lint**

No RivuletCore file changed, so the tvOS scheme is enough:

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd"
cd "/Users/bain/git/Swift Projects/Rivulet" && swiftlint lint --strict
cd "/Users/bain/git/Swift Projects/Rivulet" && git diff -U0 HEAD -- Rivulet/Views/Media/Library/UIKit/MediaLibrarySortControl.swift Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift | grep '^+' | grep -nE $'\xe2\x80\x93|\xe2\x80\x94'
cd "/Users/bain/git/Swift Projects/Rivulet" && grep -nE $'\xe2\x80\x93|\xe2\x80\x94' RivuletTests/Unit/CollectionsGridUpdateTests.swift
```

Expected: `** BUILD SUCCEEDED **`; SwiftLint reports 0 violations; the dash check prints nothing.

- [ ] **Step 6: Device verification** (Apple TV hardware. Simulator focus results are provisional and do not count.)

Setup: run a Debug build on the Apple TV. In Settings > Appearance > Library turn Hero Off and Discovery Rows Off, and turn both back On when done. Use the Movies library (section 1; on the measured server it has 71 non-empty collections, so the count should match the Collections row's tile count).

1. Switch appears when the list arrives: force-quit Rivulet, relaunch, open Movies from the sidebar, press nothing. Expected: the sort header is on screen with only the sort pill at the right edge. When the Collections row appears, a "Titles" pill appears at the right edge and the sort pill moves left by its width. The count still reads "N items".
2. Toggle on: press Down to the sort header (sort pill focused), Right to "Titles", then Select. Expected: the pill reads "Collections" with the stack icon, stays in place and keeps focus. The sort pill is gone and the count reads "71 collections" (the row's count). The grid shows collection posters, composites included, with no placeholder tiles. No A-Z bar ever appears.
3. Toggle off: Select again. Expected: "Titles" with the grid icon, the sort pill back on its left, focus still on the switch. The grid is blank briefly, then shows titles in the saved sort, and the count returns to the library's item count. Press Left: the sort pill takes focus. Press Right: the switch takes focus.
4. Collections grid: toggle on, press Down. Expected: focus moves to a tile in the first grid row. Keep pressing Down to the bottom: no placeholders, no loading past the last collection, no A-Z bar. Press Up back to the header: focus moves to the Collections pill.
5. Open and return: from the Collections grid, Select a tile. Expected: that collection's page opens (Task 4). Press Menu: focus is back on the same tile, which still shows the same collection.
6. Remembered path: toggle to Titles. Use the A-Z bar (Right from the grid's right column onto the strip, choose "S", Left into the grid) to focus a titles slot around 500. Press Menu once (the page snaps to its top row), press Down to the sort header, Right to the switch, Select (Collections). Press Menu (to the top row), Menu again (the sidebar opens), then Right. Expected: focus is on a visible item on the library page. If Right does nothing or focus becomes invisible, record it: turning `remembersLastFocusedIndexPath` off did not clear the stored titles path (spec §11 risk). Stop and report it with these steps; do not commit Task 6 (Step 7) as shippable. The fix depends on what the device shows, so it comes back as a follow-up.
7. Held swap under an open page: in Plex Web, add one movie to a new collection named "AAA Rivulet Test". In Rivulet, in the Collections state, focus about the 10th grid tile and Select it (collection page opens). Play any member for about 10 s, exit the player, wait 5 s (the player posts the refresh 2 s after exit), then press Menu until the collection page closes. Expected: focus is on the same tile showing the same collection. The grid did not shift under the open page.
8. Refill in place: move focus Up to a hub row above the header, press Play/Pause on any tile, play about 10 s, exit, and wait 5 s. Expected: without any focus change, "AAA Rivulet Test" appears in the Collections grid at its server position, later tiles shift by one, and the count goes up by one.
9. Cleanup: delete "AAA Rivulet Test" in Plex Web and repeat step 8. Expected: the tile is gone and the count drops by one.
10. No collections: if any library has no non-empty collection, open it. Expected: only the sort pill shows, at the right edge, with no Collections row.

- [ ] **Step 7: Commit**

No changelog edit here. The step 3 bullet ("Switch a library's grid between titles and collections.") goes into `WhatsNewView.changelogs` through Task 11 at tag time.

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && git add Rivulet/Views/Media/Library/UIKit/MediaLibrarySortControl.swift Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift RivuletTests/Unit/CollectionsGridUpdateTests.swift && [ "$(git branch --show-current)" = test/integration ] && [ "$(git diff --cached --name-only | sort)" = "$(printf '%s\n' Rivulet/Views/Media/Library/UIKit/MediaLibrarySortControl.swift Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift RivuletTests/Unit/CollectionsGridUpdateTests.swift | sort)" ] && git commit -m "Library: Titles and Collections switch"
```

If Step 3's pre-check found another session's hunks in one of these files, do not `git add` that file. Stage only your hunks for it: `git show HEAD:<path> > "$SCRATCH/head.swift"`, apply the Step 3 edits to a copy, `diff -u` it against the HEAD copy into a patch with `a/<path>` and `b/<path>` headers, then `git apply --check --cached patch`, `git apply --cached patch`, `git add` the other files, and run the same gated commit.

---

### Task 7: Rivulet pins, store and Home projection

**Files:**
- Modify: `Rivulet/Services/Plex/HomeRowSettings.swift` (file header comment ~l.7 and ~l.15-18; new `enum HomeCollectionPins` appended after `HomeRowSettings`)
- Modify: `Rivulet/Services/Plex/PlexDataStore.swift` (`libraryHubFetchFailures` ~l.52; `librariesPinnedToHome` doc ~l.213; `private init()` observer ~l.310; `onProfileSwitched` ~l.596 and `reset()` ~l.2035; `loadLibraryHubsIfNeeded` task tail ~l.1053; new `loadPinnedCollections` after `refreshLibraryHubs` ~l.1063; `projectHomeItems` loop ~l.1206; new `PinRowDecision` / `pinRowDecision` after `shouldCarryOverRecentlyAddedRow` ~l.1522)
- Modify: `Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift` (Task 5's collections success branch inside `refreshThisLibraryHubs`)
- Test: `RivuletTests/Unit/HomeCollectionPinsTests.swift` (beside `HomePromotedHubRowsTests.swift`, as spec §9 test 4 asks)

**Interfaces:**
- Consumes:
  - `PlexNetworkManager.getHubItems(serverURL:authToken:hubKey:hubIdentifier:start:count:) async throws -> (items: [PlexMetadata], totalSize: Int?)` (Task 2; HEAD already returns this tuple, Task 2 fixes `totalSize` and keeps the key's query. A collection children key has no query, so this task works against either).
  - `private var libraryCollections: [PlexMetadata] = []` on `PlexHomeViewController` and Task 5's success branch `if let result = try? await collectionsFetch { ... libraryCollections = collections }` inside `refreshThisLibraryHubs`.
- Produces:
  - `enum HomeCollectionPins` in `Rivulet/Services/Plex/HomeRowSettings.swift`:
    - `nonisolated struct Pin: Codable, Hashable, Sendable { let ratingKey: String; let libraryUUID: String; var title: String }` with the memberwise `Pin(ratingKey:libraryUUID:title:)` and computed `id` (`"\(libraryUUID)/\(ratingKey)"`), `rowIdentifier` (`"rivulet.pin.collection.\(ratingKey)"`), `childrenKey` (`"/library/collections/\(ratingKey)/children"`).
    - `static var pins: [Pin]`, `static func isPinned(ratingKey: String, libraryUUID: String) -> Bool`, `static func pin(_ pin: Pin)`, `static func unpin(ratingKey: String, libraryUUID: String)`, `static func updateTitles(from collections: [PlexMetadata], libraryUUID: String)`, `static let changedNotification: Notification.Name`.
    - Storage: JSON `Data` of `[Pin]` under `homeCollectionPins`, or `homeCollectionPins_user_{selectedPlexUserId}`.
  - `PlexDataStore`: `private var pinnedCollectionItems: [String: [PlexMetadata]]`, `func loadPinnedCollections(serverURL: String, token: String) async`, `nonisolated enum PinRowDecision { case render, carryOver, omit }`, `nonisolated static func pinRowDecision(isPromotedDuplicate: Bool, fetched: [PlexMetadata]?, hasCachedRow: Bool) -> PinRowDecision`.

Before editing, confirm no other session has uncommitted hunks in the three source files (earlier tasks of this plan must already be committed):

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
git diff --stat HEAD -- Rivulet/Services/Plex/HomeRowSettings.swift Rivulet/Services/Plex/PlexDataStore.swift Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift
grep -n "private var libraryCollections" Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift
grep -n "            libraryCollections = collections" Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift
```

Expected: the stat prints nothing (on 2026-09-30 none of the three carried foreign hunks), and each grep hits once (Task 5 is committed). If the stat shows hunks you did not write, use the patch route from the global constraints at commit time. If a grep misses, stop: Task 5 has not been committed.

- [ ] **Step 1: Write the failing test**

Create `RivuletTests/Unit/HomeCollectionPinsTests.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  HomeCollectionPinsTests.swift
//  RivuletTests
//
//  Collections pinned to Home in Rivulet (P2 of the collections spec).
//
//  The store is JSON in UserDefaults under a per-profile key, so these tests
//  point `selectedPlexUserId` at throwaway ids and restore it afterwards. The
//  projection's per-pin decision is a pure static because `PlexDataStore` is a
//  private-init singleton (the constraint `HomePromotedHubRowsTests`
//  documents).
//
//  Rating keys and titles come from the home PMS 1.43.4: James Bond is
//  collection 9144 in Movies, Dr. No (55929) is its first member, Newly
//  Released is 118573. The library uuids are fake on purpose: the test host is
//  the app, its `PlexDataStore` reacts to `changedNotification`, and a real
//  uuid would make a signed-in simulator fetch and draw the test pins.
//

import XCTest
@testable import Rivulet

@MainActor
final class HomeCollectionPinsTests: XCTestCase {

    private typealias Pin = HomeCollectionPins.Pin

    private let userIdKey = "selectedPlexUserId"
    private let profileA = 987_654_321
    private let profileB = 987_654_322
    private var savedUserId: Any?

    private let movies = "test-library-movies"
    private let tv = "test-library-tv"

    private var bond: Pin { Pin(ratingKey: "9144", libraryUUID: movies, title: "James Bond") }
    private var newlyReleased: Pin { Pin(ratingKey: "118573", libraryUUID: movies, title: "Newly Released") }
    private let members = [PlexMetadata(ratingKey: "55929", title: "Dr. No")]

    override func setUp() {
        super.setUp()
        savedUserId = UserDefaults.standard.object(forKey: userIdKey)
        removeTestPins()
        UserDefaults.standard.set(profileA, forKey: userIdKey)
    }

    override func tearDown() {
        removeTestPins()
        if let savedUserId {
            UserDefaults.standard.set(savedUserId, forKey: userIdKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userIdKey)
        }
        super.tearDown()
    }

    private func removeTestPins() {
        for profile in [profileA, profileB] {
            UserDefaults.standard.removeObject(forKey: "homeCollectionPins_user_\(profile)")
        }
    }

    // MARK: - Derived keys

    func test_derivedKeys() {
        XCTAssertEqual(bond.id, "test-library-movies/9144")
        XCTAssertEqual(bond.rowIdentifier, "rivulet.pin.collection.9144")
        XCTAssertEqual(bond.childrenKey, "/library/collections/9144/children")
        XCTAssertFalse(PlexDataStore.isContinueWatchingFamily(hubIdentifier: bond.rowIdentifier),
                       "a pin row must never get the Continue Watching resume tiles")
    }

    // MARK: - Persistence

    func test_pins_roundTripInPinOrder() throws {
        XCTAssertEqual(HomeCollectionPins.pins, [])
        HomeCollectionPins.pin(bond)
        HomeCollectionPins.pin(newlyReleased)
        XCTAssertEqual(HomeCollectionPins.pins, [bond, newlyReleased])

        let data = try XCTUnwrap(UserDefaults.standard.data(forKey: "homeCollectionPins_user_\(profileA)"),
                                 "stored under the profile-suffixed key")
        XCTAssertEqual(try JSONDecoder().decode([Pin].self, from: data), [bond, newlyReleased],
                       "stored as a JSON array")
    }

    func test_pin_twiceKeepsOneEntry() {
        HomeCollectionPins.pin(bond)
        HomeCollectionPins.pin(bond)
        XCTAssertEqual(HomeCollectionPins.pins, [bond])
    }

    func test_isPinned_matchesRatingKeyAndLibrary() {
        HomeCollectionPins.pin(bond)
        XCTAssertTrue(HomeCollectionPins.isPinned(ratingKey: "9144", libraryUUID: movies))
        XCTAssertFalse(HomeCollectionPins.isPinned(ratingKey: "9144", libraryUUID: tv),
                       "the same ratingKey in another library is a different pin")
        XCTAssertFalse(HomeCollectionPins.isPinned(ratingKey: "118573", libraryUUID: movies))
    }

    func test_unpin_removesOnlyThatPinAndIsIdempotent() {
        HomeCollectionPins.pin(bond)
        HomeCollectionPins.pin(newlyReleased)
        HomeCollectionPins.unpin(ratingKey: "9144", libraryUUID: movies)
        XCTAssertEqual(HomeCollectionPins.pins, [newlyReleased])

        // Two pin loaders can both see the same 404; the second unpin must not
        // post again and start another fetch round.
        let posted = expectation(forNotification: HomeCollectionPins.changedNotification, object: nil)
        posted.isInverted = true
        HomeCollectionPins.unpin(ratingKey: "9144", libraryUUID: movies)
        wait(for: [posted], timeout: 0.2)
    }

    func test_pins_arePerProfile() {
        HomeCollectionPins.pin(bond)
        UserDefaults.standard.set(profileB, forKey: userIdKey)
        XCTAssertEqual(HomeCollectionPins.pins, [], "another Plex Home profile sees none of A's pins")
        UserDefaults.standard.set(profileA, forKey: userIdKey)
        XCTAssertEqual(HomeCollectionPins.pins, [bond])
    }

    func test_pin_postsChangedNotification() {
        expectation(forNotification: HomeCollectionPins.changedNotification, object: nil)
        HomeCollectionPins.pin(bond)
        waitForExpectations(timeout: 1)
    }

    // MARK: - updateTitles

    func test_updateTitles_adoptsRenameInThatLibraryOnly() {
        HomeCollectionPins.pin(bond)
        HomeCollectionPins.pin(Pin(ratingKey: "9144", libraryUUID: tv, title: "James Bond"))
        HomeCollectionPins.updateTitles(
            from: [PlexMetadata(ratingKey: "9144", title: "007 Collection")],
            libraryUUID: movies
        )
        XCTAssertEqual(HomeCollectionPins.pins.map(\.title), ["007 Collection", "James Bond"])
    }

    /// The library page calls this on every refresh, so a no-op must not post
    /// (each post re-fetches every pin).
    func test_updateTitles_writesNothingWhenNoTitleDiffers() {
        HomeCollectionPins.pin(bond)
        let posted = expectation(forNotification: HomeCollectionPins.changedNotification, object: nil)
        posted.isInverted = true
        HomeCollectionPins.updateTitles(
            from: [PlexMetadata(ratingKey: "9144", title: "James Bond"),
                   PlexMetadata(ratingKey: "118573", title: "Newly Released")],
            libraryUUID: movies
        )
        wait(for: [posted], timeout: 0.2)
        XCTAssertEqual(HomeCollectionPins.pins, [bond])
    }

    // MARK: - Projection decision (spec §9 test 4)

    func test_pinRow_promotedDuplicateIsOmitted() {
        XCTAssertEqual(
            PlexDataStore.pinRowDecision(isPromotedDuplicate: true, fetched: members, hasCachedRow: true),
            .omit, "Plex already promotes this collection's hub, and P1 wins")
    }

    func test_pinRow_loadedNonEmptyRenders() {
        XCTAssertEqual(
            PlexDataStore.pinRowDecision(isPromotedDuplicate: false, fetched: members, hasCachedRow: false),
            .render)
    }

    func test_pinRow_notFetchedCarriesOverOnlyACachedRow() {
        XCTAssertEqual(
            PlexDataStore.pinRowDecision(isPromotedDuplicate: false, fetched: nil, hasCachedRow: true),
            .carryOver, "an early projection must not wipe the warm-launch row (#236)")
        XCTAssertEqual(
            PlexDataStore.pinRowDecision(isPromotedDuplicate: false, fetched: nil, hasCachedRow: false),
            .omit, "nothing cached, nothing to carry")
    }

    func test_pinRow_fetchedEmptyIsOmitted() {
        XCTAssertEqual(
            PlexDataStore.pinRowDecision(isPromotedDuplicate: false, fetched: [], hasCachedRow: true),
            .omit, "a collection with no members right now draws no row; the pin stays")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/HomeCollectionPinsTests
```

Expected: the test target does not compile, with `error: cannot find type 'HomeCollectionPins' in scope` (and `cannot find 'HomeCollectionPins' in scope`) plus `error: type 'PlexDataStore' has no member 'pinRowDecision'`, ending in `** TEST FAILED **`.

- [ ] **Step 3.1: Implement the store and rescope the `HomeRowSettings` header** (`Rivulet/Services/Plex/HomeRowSettings.swift`)

Find:

```swift
//  Which Home rows this device hides.
```

Replace with:

```swift
//  Which Home rows this device hides, and which collections it pins.
```

Find:

```swift
//  Subtractive ON PURPOSE. It can hide a row Plex offers; it can never invent
//  one Plex does not. That keeps a single source of truth for what a row IS and
//  what it is called, and it means a stored preference can never resurrect a
//  row for a library the user has since unshared or deleted.
```

Replace with:

```swift
//  The hide list is subtractive ON PURPOSE. It can hide a row Plex offers; it
//  can never invent one Plex does not. That keeps a single source of truth for
//  what a row IS and what it is called, and it means a stored preference can
//  never resurrect a row for a library the user has since unshared or deleted.
//
//  Local pins (`HomeCollectionPins`, below) are the one user-created exception:
//  a collection pinned from a library's tile menu adds a row inside that
//  library's Home block. A pin never adds a library, and a pin whose library is
//  gone, unshared or on another server never matches, so the no-resurrection
//  property still holds.
```

Find (end of file):

```swift
    private static func write(_ ids: Set<String>) {
        defaults.set(Array(ids), forKey: hiddenKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}
```

Replace with:

```swift
    private static func write(_ ids: Set<String>) {
        defaults.set(Array(ids), forKey: hiddenKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}

/// Collections the user pinned to Home from a library's tile menu. The one
/// user-created exception to the subtractive rule above (see the file header).
///
/// Scoped by library uuid rather than server. `PlexAuthManager.selectedServer`,
/// and with it the machine id, is nil after a warm launch that restores only
/// URL and token, while `PlexLibrary.uuid` is always present. Matching on it
/// keeps pins to the current server and leaves a pin for a deleted or unshared
/// library inert.
///
/// Stored as a JSON array per Plex Home profile, keyed like
/// `HomeRowSettings.hiddenKey`. `PlexDataStore` fetches each pin's first page
/// (`loadPinnedCollections`) and draws it after its library's own rows
/// (`projectHomeItems`).
enum HomeCollectionPins {

    /// `nonisolated` because the target defaults to MainActor, and the pin
    /// loader's `TaskGroup` children and `PlexDataStore.pinRowDecision` read
    /// these keys off the main actor. Same as `HomeItemID` and `CachedHomeHub`.
    nonisolated struct Pin: Codable, Hashable, Sendable {
        let ratingKey: String
        let libraryUUID: String
        /// Plex's title at pin time, refreshed by `updateTitles` on a rename.
        var title: String

        var id: String { "\(libraryUUID)/\(ratingKey)" }
        /// Never matches `PlexDataStore.isContinueWatchingFamily`, so the row
        /// renders as a plain poster shelf.
        var rowIdentifier: String { "rivulet.pin.collection.\(ratingKey)" }
        /// Members in the collection's own order, smart collections included.
        /// `/library/metadata/{rk}/children` returns none for a smart one.
        var childrenKey: String { "/library/collections/\(ratingKey)/children" }
    }

    /// Posted after any change. `PlexDataStore` re-projects, fetches and
    /// re-projects on it.
    static let changedNotification = Notification.Name("homeCollectionPinsChanged")

    private static let baseKey = "homeCollectionPins"

    private static var defaults: UserDefaults { .standard }

    /// Per profile, for the same reason as `HomeRowSettings.hiddenKey`.
    private static var storageKey: String {
        guard let userId = defaults.object(forKey: "selectedPlexUserId") as? Int else {
            return baseKey
        }
        return "\(baseKey)_user_\(userId)"
    }

    /// Every pin for the current profile, in the order they were pinned.
    static var pins: [Pin] {
        guard let data = defaults.data(forKey: storageKey) else { return [] }
        return (try? JSONDecoder().decode([Pin].self, from: data)) ?? []
    }

    static func isPinned(ratingKey: String, libraryUUID: String) -> Bool {
        pins.contains { $0.ratingKey == ratingKey && $0.libraryUUID == libraryUUID }
    }

    static func pin(_ pin: Pin) {
        guard !isPinned(ratingKey: pin.ratingKey, libraryUUID: pin.libraryUUID) else { return }
        write(pins + [pin])
    }

    /// No-op, and no notification, when the pin is already gone.
    static func unpin(ratingKey: String, libraryUUID: String) {
        let current = pins
        let kept = current.filter { !($0.ratingKey == ratingKey && $0.libraryUUID == libraryUUID) }
        guard kept.count != current.count else { return }
        write(kept)
    }

    /// Adopts Plex's current title for any pin in `libraryUUID` whose
    /// collection was renamed. Writes and posts nothing when no title differs,
    /// so the library page can call it on every refresh.
    static func updateTitles(from collections: [PlexMetadata], libraryUUID: String) {
        let current = pins
        let updated = current.map { pin -> Pin in
            guard pin.libraryUUID == libraryUUID,
                  let title = collections.first(where: { $0.ratingKey == pin.ratingKey })?.title,
                  !title.isEmpty else { return pin }
            var renamed = pin
            renamed.title = title
            return renamed
        }
        guard updated != current else { return }
        write(updated)
    }

    private static func write(_ pins: [Pin]) {
        guard let data = try? JSONEncoder().encode(pins) else { return }
        defaults.set(data, forKey: storageKey)
        NotificationCenter.default.post(name: changedNotification, object: nil)
    }
}
```

- [ ] **Step 3.2: Implement the row decision** (`Rivulet/Services/Plex/PlexDataStore.swift`)

Find:

```swift
    nonisolated static func shouldCarryOverRecentlyAddedRow(hubs: [PlexHub]?, fetchFailed: Bool) -> Bool {
        hubs == nil || fetchFailed
    }
```

Replace with:

```swift
    nonisolated static func shouldCarryOverRecentlyAddedRow(hubs: [PlexHub]?, fetchFailed: Bool) -> Bool {
        hubs == nil || fetchFailed
    }

    /// What `projectHomeItems` does with one pinned collection (see
    /// `HomeCollectionPins`). Plain values so it can be tested.
    nonisolated enum PinRowDecision { case render, carryOver, omit }

    /// - A hub Plex already promotes for the same collection wins (P1).
    /// - `fetched == nil` means not fetched this session. The row already in
    ///   `homeItems` (warm-launch cache or an earlier pass) carries over:
    ///   `projectHomeItems` runs from the Continue Watching poll before the pin
    ///   loader finishes, and `setHomeItems` re-persists whatever it gets, so
    ///   dropping the row here would wipe the pin from the next warm launch
    ///   (the #236 trap).
    /// - Fetched and empty: no members right now. Omit the row; the pin stays,
    ///   since a smart collection can refill.
    ///
    /// No hidden branch: pins are never `HomeRowSettings` hide toggles.
    nonisolated static func pinRowDecision(
        isPromotedDuplicate: Bool,
        fetched: [PlexMetadata]?,
        hasCachedRow: Bool
    ) -> PinRowDecision {
        if isPromotedDuplicate { return .omit }
        guard let fetched else { return hasCachedRow ? .carryOver : .omit }
        return fetched.isEmpty ? .omit : .render
    }
```

- [ ] **Step 3.3: Add the items store and clear it on profile switch and sign-out** (`PlexDataStore.swift`)

Find:

```swift
    private var libraryHubFetchFailures: Set<String> = []
```

Replace with:

```swift
    private var libraryHubFetchFailures: Set<String> = []

    /// First page of each pinned collection (see `HomeCollectionPins`), keyed
    /// by `Pin.id`. nil means not fetched this session; [] means fetched and
    /// empty. `pinRowDecision` needs the difference.
    private var pinnedCollectionItems: [String: [PlexMetadata]] = [:]
```

Then, with the Edit tool and `replace_all: true`, find (occurs exactly twice: `onProfileSwitched` and `reset()`; `refreshLibraryHubs` has no `lastRecentlyAddedStamp` line and is not matched):

```swift
        libraryHubs.removeAll()
        lastRecentlyAddedStamp = nil
        libraryHubFetchFailures.removeAll()
```

Replace with:

```swift
        libraryHubs.removeAll()
        pinnedCollectionItems.removeAll()
        lastRecentlyAddedStamp = nil
        libraryHubFetchFailures.removeAll()
```

Check: `grep -c "pinnedCollectionItems.removeAll()" Rivulet/Services/Plex/PlexDataStore.swift` prints `2`.

- [ ] **Step 3.4: Add the loader** (`PlexDataStore.swift`)

Find:

```swift
    /// Refresh hubs for all libraries on Home screen
    func refreshLibraryHubs() async {
        libraryHubs.removeAll()
        libraryHubFetchFailures.removeAll()
        await cacheManager.clearLibraryHubsCache()
        await loadLibraryHubsIfNeeded()
    }
```

Replace with:

```swift
    /// Refresh hubs for all libraries on Home screen
    func refreshLibraryHubs() async {
        libraryHubs.removeAll()
        libraryHubFetchFailures.removeAll()
        await cacheManager.clearLibraryHubsCache()
        await loadLibraryHubsIfNeeded()
    }

    /// Fetches the first page of every pinned collection (see
    /// `HomeCollectionPins`) into `pinnedCollectionItems`. Callers project
    /// afterwards; this never touches `homeItems`.
    ///
    /// Only pins whose library is a video library pinned to Home are
    /// requested. That filter is load-bearing: without it one server's pins
    /// are requested against another, answer 404, and are pruned below.
    ///
    /// Per pin: success stores the page, even an empty one. A 404 unpins,
    /// because PMS answers 404 for a deleted collection and for one this
    /// profile can no longer see (measured on PMS 1.43.4), so the pin could
    /// never render again. Any other error keeps the last-known items.
    func loadPinnedCollections(serverURL: String, token: String) async {
        // ponytail: no generation check. A fetch in flight across a profile
        // switch arrives in the new profile's dictionary, which only matters if
        // that profile pinned the same collection. Add a generation token if seen.
        let libraryUUIDs = Set(librariesPinnedToHome.filter(\.isVideoLibrary).map(\.uuid))
        let pins = HomeCollectionPins.pins.filter { libraryUUIDs.contains($0.libraryUUID) }
        guard !pins.isEmpty else { return }

        typealias Fetch = (pin: HomeCollectionPins.Pin, items: [PlexMetadata]?, gone: Bool)
        let fetches = await withTaskGroup(of: Fetch.self) { group in
            for pin in pins {
                group.addTask {
                    do {
                        let page = try await self.networkManager.getHubItems(
                            serverURL: serverURL,
                            authToken: token,
                            hubKey: pin.childrenKey,
                            hubIdentifier: nil,
                            start: 0,
                            count: 24
                        )
                        return (pin, page.items, false)
                    } catch PlexAPIError.httpError(let statusCode, _) where statusCode == 404 {
                        return (pin, nil, true)
                    } catch {
                        return (pin, nil, false)
                    }
                }
            }
            var fetches: [Fetch] = []
            for await fetch in group { fetches.append(fetch) }
            return fetches
        }

        for fetch in fetches {
            if fetch.gone {
                pinnedCollectionItems[fetch.pin.id] = nil
                HomeCollectionPins.unpin(ratingKey: fetch.pin.ratingKey, libraryUUID: fetch.pin.libraryUUID)
            } else if let items = fetch.items {
                pinnedCollectionItems[fetch.pin.id] = items
            }
        }
    }
```

- [ ] **Step 3.5: Call the loader after the library hub load** (`PlexDataStore.swift`, end of `loadLibraryHubsIfNeeded`'s task)

Find:

```swift
            libraryHubsVersion = UUID()
            isLoadingLibraryHubs = false
            // Stage 1: final projection refresh after all library hubs land.
            projectAllLoadedItems()
        }
```

Replace with:

```swift
            libraryHubsVersion = UUID()
            isLoadingLibraryHubs = false
            // Stage 1: final projection refresh after all library hubs land.
            projectAllLoadedItems()

            // Pinned collections load in their own task. The projection above
            // has already painted every promoted row and library page, and
            // neither it nor a caller awaiting this task waits on a pin fetch,
            // which can take up to the request timeout. This one site covers
            // launch, the #315 content-added poll and `refreshLibraryHubs`.
            Task {
                await self.loadPinnedCollections(serverURL: serverURL, token: token)
                self.projectHomeItems()
            }
        }
```

(`serverURL` and `token` are the locals bound by the `guard let serverURL = authManager.selectedServerURL, let token = authManager.selectedServerToken` above the task.)

- [ ] **Step 3.6: Observe pin changes** (`PlexDataStore.swift`, `private init()`)

Find:

```swift
        NotificationCenter.default.addObserver(
            forName: HomeRowSettings.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.projectHomeItems() }
        }
```

Replace with:

```swift
        NotificationCenter.default.addObserver(
            forName: HomeRowSettings.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.projectHomeItems() }
        }

        // A pin change is also a data change: a new pin has nothing fetched.
        // Project first so an unpin vanishes at once, then fetch and project
        // again. Kept apart from the observer above so a hide toggle never
        // fetches.
        NotificationCenter.default.addObserver(
            forName: HomeCollectionPins.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.projectHomeItems()
                guard let serverURL = self.authManager.selectedServerURL,
                      let token = self.authManager.selectedServerToken else { return }
                await self.loadPinnedCollections(serverURL: serverURL, token: token)
                self.projectHomeItems()
            }
        }
```

- [ ] **Step 3.7: Project pin rows inside each library block** (`PlexDataStore.swift`, `projectHomeItems`)

Find:

```swift
        for library in librariesPinnedToHome {
            for hub in libraryHubs[library.key] ?? [] {
```

Replace with:

```swift
        let pins = HomeCollectionPins.pins
        for library in librariesPinnedToHome {
            for hub in libraryHubs[library.key] ?? [] {
```

Find:

```swift
                rail.append(makeCachedHub(
                    id: "hub:\(hub.id)",
                    title: hub.title ?? "",
                    isContinueWatching: false,
                    hubKey: hub.key ?? hub.hubKey,
                    hubIdentifier: hub.hubIdentifier,
                    metas: metas
                ))
            }
        }

        // An empty projection is only allowed to replace a populated Home once a
```

Replace with:

```swift
                rail.append(makeCachedHub(
                    id: "hub:\(hub.id)",
                    title: hub.title ?? "",
                    isContinueWatching: false,
                    hubKey: hub.key ?? hub.hubKey,
                    hubIdentifier: hub.hubIdentifier,
                    metas: metas
                ))
            }

            // Collections pinned in Rivulet (see `HomeCollectionPins`), after
            // Plex's own rows for this library, in pin order.
            let promotedKeys = Set((libraryHubs[library.key] ?? [])
                .filter { $0.promoted == true }
                .compactMap(\.key))
            for pin in pins where pin.libraryUUID == library.uuid {
                let rowID = "hub:\(pin.rowIdentifier)"
                let cachedRow = homeItems.first { $0.id == rowID }
                switch Self.pinRowDecision(
                    isPromotedDuplicate: promotedKeys.contains(pin.childrenKey),
                    fetched: pinnedCollectionItems[pin.id],
                    hasCachedRow: cachedRow != nil
                ) {
                case .render:
                    rail.append(makeCachedHub(
                        id: rowID,
                        title: pin.title,
                        isContinueWatching: false,
                        hubKey: pin.childrenKey,
                        hubIdentifier: pin.rowIdentifier,
                        metas: pinnedCollectionItems[pin.id] ?? []
                    ))
                case .carryOver:
                    if let cachedRow { rail.append(cachedRow) }
                case .omit:
                    break
                }
            }
        }

        // An empty projection is only allowed to replace a populated Home once a
```

- [ ] **Step 3.8: Rescope gate 1 of `librariesPinnedToHome`** (`PlexDataStore.swift`)

Find:

```swift
    /// 1. Plex's own pin (`isPinnedToHome`, the server-side `hidden` field) says
    ///    which libraries Plex itself would put on Home. Rivulet can subtract
    ///    from that set but never add to it, which is what keeps the row set a
    ///    single source of truth (see `HomeRowSettings` for the same rule at row
    ///    granularity).
```

Replace with:

```swift
    /// 1. Plex's own pin (`isPinnedToHome`, the server-side `hidden` field) says
    ///    which libraries Plex itself would put on Home. Rivulet can subtract
    ///    from that set but never add to it, which keeps the library set a
    ///    single source of truth. `HomeRowSettings` applies the same rule to
    ///    rows, with one user-created exception: a collection pinned with
    ///    `HomeCollectionPins` adds a row inside its library's block, and only
    ///    for a library this gate already lets through.
```

- [ ] **Step 3.9: Refresh pin titles from the library page** (`Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift`, Task 5's collections success branch)

This is the `updateTitles` call Task 5 left out. It goes inside the success branch on every successful fetch, not behind `collectionsChanged`: `PlexMetadata.==` compares `ratingKey` alone (`RivuletCore/Models/Plex/PlexMetadata.swift` ~l.389), and Task 5's comparison uses ratingKeys, so a collection renamed in Plex reads as an unchanged list. `updateTitles` writes and posts nothing when no title differs (Step 1, `test_updateTitles_writesNothingWhenNoTitleDiffers`), so calling it on every fetch costs one UserDefaults read. A failed fetch skips it, which is correct: there is nothing new to compare.

Find:

```swift
            libraryCollections = collections
        }
```

Replace with:

```swift
            libraryCollections = collections
            // Pinned Home rows take Plex's current collection titles. Every
            // successful fetch, not only a changed list: a rename keeps the
            // ratingKey, so it reads as an unchanged list. Writes nothing
            // unless a pinned title differs.
            if let libraryUUID = dataStore.libraries.first(where: { $0.key == key })?.uuid {
                HomeCollectionPins.updateTitles(from: collections, libraryUUID: libraryUUID)
            }
        }
```

(`key` is bound by the function's opening `guard case .library(let key, _) = mode`. A post from `updateTitles` reaches `PlexDataStore`'s observer through a queued `Task`, so it never runs between Task 5's `minY` capture and its apply.)

- [ ] **Step 4: Run it to verify it passes**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/HomeCollectionPinsTests -only-testing:RivuletTests/HomePromotedHubRowsTests
```

Expected: `HomeCollectionPinsTests` executes 13 tests with 0 failures, `HomePromotedHubRowsTests` passes unchanged, and the run ends `** TEST SUCCEEDED **`.

- [ ] **Step 5: Build and lint**

No file under `RivuletCore/` changes in this task (all edits are in `Rivulet/` and `RivuletTests/`, tvOS only), so the iOS scheme is unaffected and not rebuilt here.

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd"
swiftlint lint --strict
git diff -U0 -- Rivulet/Services/Plex/HomeRowSettings.swift Rivulet/Services/Plex/PlexDataStore.swift Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift | grep '^+' | grep -nE $'\xe2\x80\x93|\xe2\x80\x94'
grep -nE $'\xe2\x80\x93|\xe2\x80\x94' RivuletTests/Unit/HomeCollectionPinsTests.swift
```

Expected: `** BUILD SUCCEEDED **`; swiftlint reports 0 violations; the dash check prints nothing. Also check that no new warnings mention `HomeCollectionPins`, `pinnedCollectionItems` or `loadPinnedCollections` (Swift 6 isolation): `grep -n "HomeCollectionPins\|pinnedCollectionItems\|loadPinnedCollections" <build log> | grep -i warning` prints nothing.

- [ ] **Step 6: Device verification**

This task adds no entry point (Pin to Home arrives in Task 8), so nothing here can be pinned from the remote. The §9 "Pins" checks (pin, unpin, warm relaunch, Settings listing, promoted collection offers no Pin, a large pinned row paging past 48) run at the end of Task 8. On the Apple TV now, run a no-pin regression smoke:
1. Cold launch. Home shows the same rows in the same order as the previous build (Continue Watching, then each pinned library's promoted rows).
2. Open the Movies library tab, press Menu back to Home, then relaunch (warm). Home rows are unchanged and nothing flickers in or out.
3. Settings > Appearance > Rows lists the same toggles as before.

- [ ] **Step 7: Commit**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
git add Rivulet/Services/Plex/HomeRowSettings.swift Rivulet/Services/Plex/PlexDataStore.swift Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift RivuletTests/Unit/HomeCollectionPinsTests.swift
[ "$(git branch --show-current)" = test/integration ] && [ "$(git diff --cached --name-only | sort)" = "$(printf '%s\n' Rivulet/Services/Plex/HomeRowSettings.swift Rivulet/Services/Plex/PlexDataStore.swift Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift RivuletTests/Unit/HomeCollectionPinsTests.swift | sort)" ] && git commit -m "Home: pinned collection rows"
```

If the pre-edit check found another session's hunks in any of the three source files, stage only this task's hunks with the `git show HEAD:<path>` / `git apply --cached` patch route from the global constraints, then run the same gated commit.

---

### Task 8: Pin / Unpin entry points (tile menu and Settings > Home Rows)

**Files:**
- Modify: `Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift` (new `PinAction`, `collectionPinAction`, `collectionTileMenuSections(for:)` under `// MARK: - Tile menu builder` ~5184; Task 4's `.collection` branch inside `tileMenuSections(for:isContinueWatching:shelfLocation:)` ~5191)
- Modify: `Rivulet/Views/Settings/UIKit/SettingsPageModels.swift` (`homeRows` ~525, new `pinnedCollectionRows(store:)` before `// MARK: Libraries (sidebar visibility)` ~575)
- Modify: `Rivulet/Views/Settings/SettingsDescriptors.swift` (`descriptor(for:)` ~28, `descriptors` after `"homeRowItem"` ~78)
- Test: `RivuletTests/Unit/CollectionPinActionTests.swift` (new, at the Unit root beside the other Home tests)

**Interfaces:**
- Consumes:
  - `enum HomeCollectionPins` (Task 7): `nonisolated struct Pin: Codable, Hashable, Sendable { let ratingKey: String; let libraryUUID: String; var title: String }` with memberwise `Pin(ratingKey:libraryUUID:title:)`, computed `id` (`"\(libraryUUID)/\(ratingKey)"`), `rowIdentifier` (`"rivulet.pin.collection.\(ratingKey)"`), `childrenKey` (`"/library/collections/\(ratingKey)/children"`); `static var pins: [Pin]`; `static func isPinned(ratingKey:libraryUUID:) -> Bool`; `static func pin(_ pin: Pin)`; `static func unpin(ratingKey:libraryUUID:)`. Task 7's `changedNotification` observer in `PlexDataStore` does the Home repaint and fetch; this task only calls the store.
  - Task 4's early return inside `tileMenuSections`, exactly:
    ```swift
            // Select already opens a collection's page, and every action below
            // needs a playable item. Empty sections present no popup.
            if item.kind == .collection { return [] }
    ```
  - Task 5's Collections row (`HomeSectionData.hub`, so kind `.recentlyAdded`) and Task 6's Collections grid (`.grid` items mapped from collection `PlexMetadata`, kind `.collection`).
  - Existing: `PlexDataStore.libraries: [PlexLibrary]`, `PlexDataStore.libraryHubs: [String: [PlexHub]]`, `PlexDataStore.librariesPinnedToHome`, `PlexLibrary.uuid: String`, `PlexHub.promoted: Bool?`, `PlexHub.key: String?`, `SettingsRowItem.header(_:)`, `SettingsPageViewController.reloadRows()`, `TileMenuAction(title:systemImage:destructive:handler:)`.
- Produces:
  - `nonisolated enum PinAction { case pin, unpin }` nested in `PlexHomeViewController`.
  - `nonisolated static func collectionPinAction(isLibraryPinned: Bool, promotedChildrenKeys: Set<String>, childrenKey: String, isPinned: Bool) -> PinAction?` on `PlexHomeViewController`.

No coverage edits are needed in `presentShelfTileMenu` or `handleGridLongPress`: the Collections row is a `.recentlyAdded` shelf, which already calls `tileMenuSections(for:isContinueWatching: false, shelfLocation:)`, and a Collections grid tile is a `.grid` item, which `handleGridLongPress` already sends to `tileMenuSections(for:isContinueWatching: false)`. Both reach the one `.collection` branch this task rewrites. `presentTileMenu` already drops a menu with no non-empty group (`guard sections.contains(where: { !$0.isEmpty })`), so a `[]` answer shows nothing.

- [ ] **Step 0: Check for other sessions' hunks in the files this task edits**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
git diff --stat -- Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift Rivulet/Views/Settings/UIKit/SettingsPageModels.swift Rivulet/Views/Settings/SettingsDescriptors.swift
```

Expected: no output. If a file shows changes you did not make, use the global hunk-only commit path (`git show HEAD:<path>` copy, patch, `git apply --cached`) for that file in Step 7.

- [ ] **Step 1: Write the failing test**

Create `RivuletTests/Unit/CollectionPinActionTests.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  CollectionPinActionTests.swift
//  RivuletTests
//
//  A collection tile's menu in a library offers Pin to Home, Unpin from Home,
//  or nothing. A wrong answer either hides the only tile-side Unpin or offers
//  a Pin whose row can never render, so the choice is a pure static and this
//  covers it. Keys follow the measured P1 hub: a promoted collection hub's key
//  is /library/collections/{rk}/children (James Bond is rk 9144 on the test
//  server).
//

import XCTest
@testable import Rivulet

@MainActor
final class CollectionPinActionTests: XCTestCase {

    private let bond = "/library/collections/9144/children"

    /// No Home block to render into, so no menu.
    func test_libraryNotPinnedToHome_offersNothing() {
        XCTAssertNil(PlexHomeViewController.collectionPinAction(
            isLibraryPinned: false, promotedChildrenKeys: [], childrenKey: bond, isPinned: false))
    }

    /// A pin whose library was later taken off Home still gets no tile menu.
    /// Settings > Home Rows is where it is unpinned.
    func test_libraryNotPinnedToHome_offersNothingEvenWhenPinned() {
        XCTAssertNil(PlexHomeViewController.collectionPinAction(
            isLibraryPinned: false, promotedChildrenKeys: [], childrenKey: bond, isPinned: true))
    }

    /// Plex already puts a promoted collection on Home (P1 wins).
    func test_promotedInPlex_offersNothing() {
        XCTAssertNil(PlexHomeViewController.collectionPinAction(
            isLibraryPinned: true, promotedChildrenKeys: [bond], childrenKey: bond, isPinned: false))
        XCTAssertNil(PlexHomeViewController.collectionPinAction(
            isLibraryPinned: true, promotedChildrenKeys: [bond], childrenKey: bond, isPinned: true))
    }

    func test_otherPromotedCollection_doesNotBlock() {
        XCTAssertEqual(PlexHomeViewController.collectionPinAction(
            isLibraryPinned: true,
            promotedChildrenKeys: ["/library/collections/118562/children"],
            childrenKey: bond,
            isPinned: false), .pin)
    }

    func test_notPinned_offersPin() {
        XCTAssertEqual(PlexHomeViewController.collectionPinAction(
            isLibraryPinned: true, promotedChildrenKeys: [], childrenKey: bond, isPinned: false), .pin)
    }

    func test_pinned_offersUnpin() {
        XCTAssertEqual(PlexHomeViewController.collectionPinAction(
            isLibraryPinned: true, promotedChildrenKeys: [], childrenKey: bond, isPinned: true), .unpin)
    }

    /// Pin rows carry the pin's identity in their id, so they resolve through
    /// the prefix fallback, the way homeRow_ rows do.
    func test_pinRowId_resolvesToPinnedCollectionDescriptor() {
        XCTAssertEqual(SettingsDescriptorStore.descriptor(for: "pinnedCollection_abc123/9144")?.description,
                       "A collection you pinned to Home from its tile menu. Select to unpin it.")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/CollectionPinActionTests
```

Expected: the test target fails to compile with `error: type 'PlexHomeViewController' has no member 'collectionPinAction'`, and the run ends `** TEST FAILED **`.

- [ ] **Step 3a: Implement the static, the enum and the collection menu builder**

In `Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift`, find (unique in the file; the doc comment below it stays where it is):

```swift
    // MARK: - Tile menu builder
```

Replace with:

```swift
    // MARK: - Tile menu builder

    nonisolated enum PinAction { case pin, unpin }

    /// What a collection tile's menu offers in a library: nil (no menu) when
    /// the library has no Home block to render into, or when Plex already
    /// promotes this collection to Home; otherwise Unpin if pinned, Pin if not.
    nonisolated static func collectionPinAction(isLibraryPinned: Bool,
                                                promotedChildrenKeys: Set<String>,
                                                childrenKey: String,
                                                isPinned: Bool) -> PinAction? {
        guard isLibraryPinned, !promotedChildrenKeys.contains(childrenKey) else { return nil }
        return isPinned ? .unpin : .pin
    }

    /// A collection tile's menu: Pin to Home or Unpin from Home, in library
    /// mode only. Select already opens the collection, so there is no Open
    /// action. A MediaItem carries no section id, so the library comes from
    /// `mode`.
    private func collectionTileMenuSections(for item: MediaItem) -> [[TileMenuAction]] {
        guard case .library(let key, _) = mode,
              !item.ref.itemID.isEmpty,
              let libraryUUID = dataStore.libraries.first(where: { $0.key == key })?.uuid
        else { return [] }
        let pin = HomeCollectionPins.Pin(ratingKey: item.ref.itemID, libraryUUID: libraryUUID, title: item.title)
        let promotedKeys = Set((dataStore.libraryHubs[key] ?? [])
            .filter { $0.promoted == true }
            .compactMap(\.key))
        guard let action = Self.collectionPinAction(
            isLibraryPinned: dataStore.librariesPinnedToHome.contains { $0.key == key },
            promotedChildrenKeys: promotedKeys,
            childrenKey: pin.childrenKey,
            isPinned: HomeCollectionPins.isPinned(ratingKey: pin.ratingKey, libraryUUID: libraryUUID))
        else { return [] }
        switch action {
        case .pin:
            return [[TileMenuAction(title: "Pin to Home", systemImage: "pin") {
                HomeCollectionPins.pin(pin)
            }]]
        case .unpin:
            return [[TileMenuAction(title: "Unpin from Home", systemImage: "pin.slash", destructive: true) {
                HomeCollectionPins.unpin(ratingKey: pin.ratingKey, libraryUUID: pin.libraryUUID)
            }]]
        }
    }
```

The promoted-key test reads `hub.key`, the same field Task 7's projection compares against `pin.childrenKey`, so the tile menu and the P1 dedupe can never disagree.

- [ ] **Step 3b: Point Task 4's collection branch at the builder**

Find:

```swift
        // Select already opens a collection's page, and every action below
        // needs a playable item. Empty sections present no popup.
        if item.kind == .collection { return [] }
```

Replace with:

```swift
        // A collection opens its page on Select and has nothing to play or
        // mark. In a library its menu is Pin to Home or Unpin from Home.
        if item.kind == .collection { return collectionTileMenuSections(for: item) }
```

The branch stays above the credentials guard and above `if isContinueWatching {`, where Task 4 put it.

- [ ] **Step 3c: Keep pins out of the Home Rows toggle list**

In `Rivulet/Views/Settings/UIKit/SettingsPageModels.swift`, inside `homeRows`, find:

```swift
            + visible.compactMap { row in
                guard let id = row.hubIdentifier else { return nil }
                return (id, row.title)
            }
```

Replace with:

```swift
            + visible.compactMap { row in
                // Pinned collections are listed below with an Unpin action,
                // never as a hide toggle.
                guard let id = row.hubIdentifier, !id.hasPrefix("rivulet.pin.") else { return nil }
                return (id, row.title)
            }
```

- [ ] **Step 3d: Append the Pinned Collections group to Home Rows**

In the same `homeRows`, find:

```swift
        guard !entries.isEmpty else {
            return [SettingsRowItem(id: "noHomeRows",
                                    title: "Connect to a Plex server to manage Home rows",
                                    kind: .info(value: { "" }))]
        }
```

Replace with:

```swift
        let pinRows = pinnedCollectionRows(store: store)
        guard !entries.isEmpty else {
            // A pin can outlive every Plex row (its library taken off Home),
            // and this page is the only place left to unpin it.
            guard pinRows.isEmpty else { return pinRows }
            return [SettingsRowItem(id: "noHomeRows",
                                    title: "Connect to a Plex server to manage Home rows",
                                    kind: .info(value: { "" }))]
        }
```

Then find the end of `homeRows`:

```swift
                set: { shown in HomeRowSettings.setHidden(!shown, for: entry.id) })))
        }
        return rows
    }

    // MARK: Libraries (sidebar visibility)
```

Replace with:

```swift
                set: { shown in HomeRowSettings.setHidden(!shown, for: entry.id) })))
        }
        return rows + pinRows
    }

    /// The Pinned Collections group: every pin on the current server, not only
    /// the rows Home draws, so an emptied pin, or one whose library was taken
    /// off Home, can still be unpinned. Omitted when there are none. Show All
    /// never touches pins.
    private static func pinnedCollectionRows(store: PlexDataStore) -> [SettingsRowItem] {
        let serverLibraries = Set(store.libraries.map(\.uuid))
        let pins = HomeCollectionPins.pins.filter { serverLibraries.contains($0.libraryUUID) }
        guard !pins.isEmpty else { return [] }
        var rows: [SettingsRowItem] = [.header("Pinned Collections")]
        for pin in pins {
            rows.append(SettingsRowItem(id: "pinnedCollection_\(pin.id)", title: pin.title,
                                        kind: .action(destructive: true, handler: { vc in
                HomeCollectionPins.unpin(ratingKey: pin.ratingKey, libraryUUID: pin.libraryUUID)
                (vc as? SettingsPageViewController)?.reloadRows()
            })))
        }
        return rows
    }

    // MARK: Libraries (sidebar visibility)
```

- [ ] **Step 3e: Add the pin row descriptor**

In `Rivulet/Views/Settings/SettingsDescriptors.swift`, find:

```swift
        if id.hasPrefix("homeRow_") { return descriptors["homeRowItem"] }
```

Replace with:

```swift
        if id.hasPrefix("homeRow_") { return descriptors["homeRowItem"] }
        if id.hasPrefix("pinnedCollection_") { return descriptors["pinnedCollection"] }
```

Then find:

```swift
        "homeRowItem": SettingDescriptor(
            icon: "rectangle.grid.1x2",
            description: "Turn this row off to hide it on this Apple TV. Your Plex account is unchanged, so the row keeps showing in the Plex app and on your other devices."
        ),
```

Replace with:

```swift
        "homeRowItem": SettingDescriptor(
            icon: "rectangle.grid.1x2",
            description: "Turn this row off to hide it on this Apple TV. Your Plex account is unchanged, so the row keeps showing in the Plex app and on your other devices."
        ),
        "pinnedCollection": SettingDescriptor(
            icon: "pin",
            description: "A collection you pinned to Home from its tile menu. Select to unpin it."
        ),
```

The `homeRows`, `showAllHomeRows` and `homeRowItem` copy and the `homeRows` doc comment stay as they are: the toggles still cover only Plex rows.

- [ ] **Step 4: Run it to verify it passes**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/CollectionPinActionTests
```

Expected: `Test Suite 'CollectionPinActionTests' passed`, `Executed 7 tests, with 0 failures`, `** TEST SUCCEEDED **`.

- [ ] **Step 5: Build and lint**

No `RivuletCore/` file changes in this task, so the iOS scheme is not required.

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd"
swiftlint lint --strict
git diff -U0 -- Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift Rivulet/Views/Settings/UIKit/SettingsPageModels.swift Rivulet/Views/Settings/SettingsDescriptors.swift | grep '^+' | grep -nE $'\xe2\x80\x93|\xe2\x80\x94'
grep -nE $'\xe2\x80\x93|\xe2\x80\x94' RivuletTests/Unit/CollectionPinActionTests.swift
```

Expected: `** BUILD SUCCEEDED **`; swiftlint reports 0 violations; both dash checks print nothing (they read added lines only, so the file's pre-existing comments do not count).

- [ ] **Step 6: Device verification**

Simulator focus behaviour is provisional; run these on an Apple TV against the home PMS. Test data: Movies library (section 1), James Bond collection (rk 9144, 4 members, manual). Before starting, confirm in Plex Web that Movies is pinned to Home and that James Bond is not promoted (its "Visible on" does not include Home).

Tile menu, Collections row:
1. Open Movies. Down to the Collections row, focus James Bond, hold Select about 1 second. Expected: the popup shows exactly one action, "Pin to Home", and nothing else (no Watch from Beginning, More Info, Mark as Watched or Refresh Metadata).
2. Select "Pin to Home". Go to Home. Expected: a "James Bond" row inside the Movies block, after Movies' promoted rows, showing the four films in release order.
3. Back in Movies, hold Select on the same tile. Expected: one action, "Unpin from Home", in destructive red. Select it, go to Home. Expected: the row is gone at once.

Tile menu, Collections grid:
4. Pin James Bond again from the row. Move to the sort header, switch the grid to Collections, Down into the grid, focus James Bond, hold Select. Expected: "Unpin from Home". Focus another collection. Expected: "Pin to Home". Press Menu to close without choosing.

No menu cases:
5. In Plex Web, un-pin the TV library from Home (Plex's library "Unpin"/hidden from Home). Relaunch Rivulet, open TV, hold Select on any Collections tile. Expected: no popup appears. With no popup to take focus, the release can reach the tile as a Select and open the collection page, the same as a click; that is correct (Task 4, check 6c). Re-pin the TV library afterwards.
6. In Plex Web, set another Movies collection's "Visible on" to include Home (the Manage Recommendations promotion). Relaunch, open Movies, hold Select on that tile. Expected: no popup. Its Plex row already shows on Home. Undo the promotion afterwards.
7. On Home, hold Select on a member tile of the pinned James Bond row. Expected: the normal movie menu (Watch from Beginning, More Info, watched state, Refresh Metadata), because members are movies.

Warm relaunch:
8. With James Bond pinned, force-quit Rivulet (double-press TV, swipe up) and relaunch. Expected: the James Bond row is on Home in the Movies block on first paint, before the network refresh.

Settings > Home Rows:
9. Settings > Appearance > Rows. Expected: the toggle list does not contain "James Bond"; after the last toggle there is a "PINNED COLLECTIONS" caption, then a "James Bond" row with no On/Off value, in destructive styling.
10. Focus the James Bond row. Expected: the left panel shows the pin icon and "A collection you pinned to Home from its tile menu. Select to unpin it."
11. Pin a second collection from Movies first, then in Rows press Select on the second pin row. Expected: that row leaves the list, focus moves to a neighbouring row of the list (not to the left panel, not to the sidebar), and James Bond is still listed.
12. Select James Bond. Expected: the row and the "PINNED COLLECTIONS" caption both leave the list, focus stays on a list row, and Menu back to Home shows no James Bond row.
13. Press "Show All" with a pin present. Expected: the pin is still listed afterwards.
14. Pin James Bond, then un-pin Movies from Home in Plex Web, relaunch. Expected: no James Bond row on Home, no tile menu on its tile (case 5), and James Bond still listed under Pinned Collections, where Select unpins it. Re-pin Movies afterwards.
15. Switch to another Plex Home profile. Expected: Rows lists only that profile's pins (none at first).

Paging (Review Focus 4; pins Task 7's projection and Task 2's pager):
16. Pin Action Movies (416 members) from the Movies Collections row. On Home, focus its row and hold Right past tile 48, then past 72. Expected: tiles keep arriving in the collection's own order with no repeats and no skeleton that never resolves. Unpin it afterwards.

If step 11 or 12 drops focus off the list, record it as a finding against `SettingsPageViewController.reloadRows()` (it uses `reloadData()`); do not patch it in this task.

- [ ] **Step 7: Commit**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
git add Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift Rivulet/Views/Settings/UIKit/SettingsPageModels.swift Rivulet/Views/Settings/SettingsDescriptors.swift RivuletTests/Unit/CollectionPinActionTests.swift
[ "$(git branch --show-current)" = test/integration ] && [ "$(git diff --cached --name-only | sort)" = "$(printf '%s\n' Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift Rivulet/Views/Settings/UIKit/SettingsPageModels.swift Rivulet/Views/Settings/SettingsDescriptors.swift RivuletTests/Unit/CollectionPinActionTests.swift | sort)" ] && git commit -m "Collections: pin to Home from the tile menu"
```

Changelog for rollout step 4 ("Pin a collection to Home from its tile menu.") is written at tag time through Task 11.

---

### Task 9: Related split in the provider and API

Fixtures come from the live PMS (192.168.1.140, 1.43.4). On 2026-09-30 GET `/library/metadata/{rk}/related?count=12` was sent for Raiders of the Lost Ark (87157), Diamonds Are Forever (55947) and UNTAMED (141852), plus the collection lookups.

**The measurement changes one spec decision** (Spec deviations, item 1; the plan's other departures from the spec are listed there too). `/library/all?type=18&index={tagId}` returns **two** collections when Kometa made same-named collections in both sections, and they share one tag: 353397 returns 118562 (movie) and 118567 (show), 353395 returns 118561 and 118566, movie first every time. `Metadata?.first` would give a show page the movie collection as its trailing tile. `/library/sections/{sid}/all?type=18&index={tagId}` returns exactly one (1125 to 1142 bytes, about 10ms), and a miss returns 200 with nothing (425 bytes). The section comes from the collection hub's own key (`/library/sections/2/all?type=2&tagId=353395&...`). So `getCollection` takes a `sectionId` and `RelatedSplit` carries it. The Raiders fixture's collection hub is IMDb Top 250 (tag 353397), so the split test asserts 353397 where spec §9 test 2 says 61303; 61303 is the James Bond tag, whose hub has no `more`.

**Files:**
- Create: `RivuletTests/Unit/Services/PlexProviderRelatedTests.swift`
- Modify: `RivuletCore/Plex/PlexNetworkManager.swift` (`getRelatedItems` ~586, `getCollectionItems` ~642, replaced by `getCollection`)
- Modify: `Rivulet/Services/MediaProvider/MediaProvider.swift` (protocol requirements ~36-41; new `RelatedContent`, `CollectionRow` at end of file)
- Modify: `Rivulet/Services/MediaProvider/Plex/PlexProvider.swift` (`collectionItems(matching:in:)` + `relatedItems(for:)` ~135-158, replaced by `related(for:kind:)`, `RelatedSplit`, `splitRelated`)
- Modify: `Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldContentLoader.swift` (`load(for:detail:)` ~140)
- Modify: `RivuletTests/Unit/HomeComposerTests.swift` (`StubMediaProvider` ~65-66)
- Test: `RivuletTests/Unit/Services/PlexProviderRelatedTests.swift`

**Interfaces:**
- Consumes: `PlexMediaMapper.item(_:providerID:serverURL:authToken:)` (existing, unchanged); `PlexHub` (existing: `hubIdentifier`, `type`, `key`, `more`, `title`, `Metadata`); `plexCall` (existing).
- Produces (Task 10 consumes the protocol method, both result types, the loader line and the stub):
  - `PlexNetworkManager.getRelatedItems(serverURL: String, authToken: String, ratingKey: String, limit: Int = 12) async throws -> [PlexHub]`
  - `PlexNetworkManager.getCollection(serverURL: String, authToken: String, sectionId: String, tagId: String) async throws -> PlexMetadata?` (`getCollectionItems` deleted)
  - `MediaProvider.related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent` (`collectionItems(matching:in:)` and `relatedItems(for:)` removed)
  - `nonisolated struct RelatedContent: Sendable { let items: [MediaItem]; let collection: CollectionRow? }`
  - `nonisolated struct CollectionRow: Sendable { let title: String; let members: [MediaItem]; let collection: MediaItem? }`
  - `PlexProvider.RelatedSplit` (`nonisolated struct { let related: [PlexMetadata]; let collectionTitle: String?; let members: [PlexMetadata]; let tagId: String?; let sectionId: String? }`)
  - `nonisolated static func PlexProvider.splitRelated(hubs: [PlexHub], currentRatingKey: String, kind: MediaKind) -> RelatedSplit`
  - The loader's Related line becomes `content.related = (try? await provider.related(for: item.ref, kind: item.kind))?.items ?? []`, directly under `// Related row.`
  - The stub in `HomeComposerTests.swift` becomes exactly the three lines `func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent {`, `RelatedContent(items: [], collection: nil)`, `}`.

Before editing, run `git diff -- <file>` on each file above. As of 2026-09-30 only `RivuletCore/Plex/PlexNetworkManager.swift` carries another session's hunks (Live TV, ~2369 and ~3186, far from this task's region). If any other file shows foreign hunks, commit it with the same splice procedure as Step 7.

- [ ] **Step 1: Write the failing test**

Create `RivuletTests/Unit/Services/PlexProviderRelatedTests.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexProviderRelatedTests.swift
//  RivuletTests
//
//  The detail page's Collection and Related rows come from one
//  /library/metadata/{rk}/related call. The fixtures are the hubs PMS 1.43.4
//  returned on 2026-09-30 for Raiders of the Lost Ark (87157), Diamonds Are
//  Forever (55947) and the show UNTAMED (141852), cut down to ratingKeys.
//

import XCTest
@testable import Rivulet

final class PlexProviderRelatedTests: XCTestCase {

    // MARK: - Split

    func test_movie_takesItsCollectionHubMinusItself_andRelatedDropsBothCollectionHubs() {
        let split = PlexProvider.splitRelated(hubs: raiders, currentRatingKey: "87157", kind: .movie)

        XCTAssertEqual(split.collectionTitle, "IMDb Top 250 Collection")
        XCTAssertEqual(split.members.map(\.ratingKey), [
            "52877", "64440", "95808", "61257", "14720", "63612", "14671", "9299", "95818", "14427", "14621",
        ])
        // All 8 Spielberg titles, then Harrison Ford up to the cap of 12. No
        // IMDb Top 250 movie or show, and not Raiders itself.
        XCTAssertEqual(split.related.map(\.ratingKey), [
            "64357", "231521", "14496", "233284", "13584", "234022", "72863", "234111",
            "232314", "231993", "232732", "14320",
        ])
        XCTAssertEqual(split.tagId, "353397")
        XCTAssertEqual(split.sectionId, "1")
    }

    func test_show_takesTheShowTypedHub_notTheMovieHubListedFirst() {
        let split = PlexProvider.splitRelated(hubs: untamed, currentRatingKey: "141852", kind: .show)

        XCTAssertEqual(split.collectionTitle, "IMDb Popular Collection")
        XCTAssertEqual(split.members.map(\.ratingKey), [
            "1160", "102973", "100408", "119495", "93597", "34356", "137938", "95007", "25088", "100200", "106687",
        ])
        XCTAssertEqual(split.related.map(\.ratingKey), ["218758", "25711", "25088", "221913", "219301", "218452"])
        XCTAssertEqual(split.tagId, "353395")
        XCTAssertEqual(split.sectionId, "2")
    }

    func test_episodeAndSeason_getNoCollectionHub() {
        for kind in [MediaKind.episode, .season] {
            let split = PlexProvider.splitRelated(hubs: untamed, currentRatingKey: "141852", kind: kind)
            XCTAssertNil(split.collectionTitle)
            XCTAssertTrue(split.members.isEmpty)
            XCTAssertNil(split.tagId)
            XCTAssertNil(split.sectionId)
            // Collection hubs stay out of Related even when none is picked.
            XCTAssertEqual(split.related.count, 6)
        }
    }

    func test_collectionOf12OrFewer_parsesNoTagId() {
        let split = PlexProvider.splitRelated(hubs: diamonds, currentRatingKey: "55947", kind: .movie)

        XCTAssertEqual(split.collectionTitle, "James Bond Collection")
        XCTAssertEqual(split.members.map(\.ratingKey), ["55929", "55933", "96003"])
        XCTAssertNil(split.tagId)
        XCTAssertNil(split.sectionId)
        XCTAssertTrue(split.related.isEmpty)
    }

    // MARK: - Provider

    func test_moreHub_looksUpTheTrailingTileInTheHubsOwnSection() async throws {
        let network = StubNetwork()
        network.hubs = raiders
        network.collection = PlexMetadata(
            ratingKey: "118562", key: "/library/collections/118562/children",
            type: "collection", title: "IMDb Top 250"
        )

        let content = try await makeProvider(network).related(for: ref("87157"), kind: .movie)

        XCTAssertEqual(network.lookups, ["1/353397"])
        XCTAssertEqual(content.collection?.title, "IMDb Top 250 Collection")
        XCTAssertEqual(content.collection?.members.count, 11)
        XCTAssertEqual(content.collection?.collection?.ref.itemID, "118562")
        XCTAssertEqual(content.collection?.collection?.kind, .collection)
        XCTAssertEqual(content.items.count, 12)
    }

    func test_noMore_makesNoLookup() async throws {
        let network = StubNetwork()
        network.hubs = diamonds

        let content = try await makeProvider(network).related(for: ref("55947"), kind: .movie)

        XCTAssertTrue(network.lookups.isEmpty)
        XCTAssertEqual(content.collection?.members.map(\.ref.itemID), ["55929", "55933", "96003"])
        XCTAssertNil(content.collection?.collection)
    }

    func test_failedLookup_keepsTheRowWithoutATile() async throws {
        let network = StubNetwork()
        network.hubs = raiders
        network.lookupFails = true

        let content = try await makeProvider(network).related(for: ref("87157"), kind: .movie)

        XCTAssertEqual(network.lookups, ["1/353397"])
        XCTAssertEqual(content.collection?.members.count, 11)
        XCTAssertNil(content.collection?.collection)
    }

    // MARK: - Fixtures

    private final class StubNetwork: PlexNetworkManager {
        var hubs: [PlexHub] = []
        var collection: PlexMetadata?
        var lookupFails = false
        var lookups: [String] = []

        override func getRelatedItems(
            serverURL: String, authToken: String, ratingKey: String, limit: Int
        ) async throws -> [PlexHub] {
            hubs
        }

        override func getCollection(
            serverURL: String, authToken: String, sectionId: String, tagId: String
        ) async throws -> PlexMetadata? {
            lookups.append("\(sectionId)/\(tagId)")
            if lookupFails { throw PlexAPIError.invalidURL }
            return collection
        }
    }

    private func makeProvider(_ network: StubNetwork) -> PlexProvider {
        PlexProvider(
            machineIdentifier: "test", displayName: "Test",
            serverURL: "http://plex.test", authToken: "t",
            networkManager: network
        )
    }

    private func ref(_ id: String) -> MediaItemRef {
        MediaItemRef(providerID: "plex:test", itemID: id)
    }

    private func hub(
        _ identifier: String, _ type: String, _ title: String, more: Bool = false, key: String, _ keys: [String]
    ) -> PlexHub {
        PlexHub(
            hubIdentifier: identifier, title: title, type: type, key: key, more: more,
            Metadata: keys.map { PlexMetadata(ratingKey: $0, type: type) }
        )
    }

    /// Raiders of the Lost Ark: IMDb Top 250 is its collection (more than 12
    /// members, so `more`), then that tag's TV twin and two people hubs.
    private var raiders: [PlexHub] {
        [
            hub("collection.related.1.1", "movie", "IMDb Top 250 Collection", more: true,
                key: "/library/sections/1/all?type=1&tagId=353397&sort=taggingIndex:nullsLast,titleSort",
                ["52877", "64440", "95808", "61257", "14720", "63612", "14671", "9299", "87157", "95818", "14427", "14621"]),
            hub("collection.related.2.2", "show", "TV Shows in IMDb Top 250 Collection", more: true,
                key: "/library/sections/2/all?type=2&tagId=353397&sort=taggingIndex:nullsLast,titleSort",
                ["10794", "27090", "30672", "1160", "10821", "25088", "1503", "126789", "73002", "10807", "86479", "140411"]),
            hub("movie.same.director", "movie", "More by Steven Spielberg",
                key: "/library/sections/1/all?director=158774&id!=87157",
                ["64357", "231521", "14496", "233284", "13584", "234022", "72863", "234111"]),
            hub("movie.same.actor.0", "movie", "More with Harrison Ford",
                key: "/library/sections/1/all?actor=141025&id!=87157",
                ["232314", "231993", "232732", "14320", "234255", "234251", "234244", "232525"]),
        ]
    }

    /// Diamonds Are Forever: the four Bond films in release order, itself
    /// included, and nothing else. Four members, so no `more`.
    private var diamonds: [PlexHub] {
        [
            hub("collection.related.1.1", "movie", "James Bond Collection",
                key: "/library/sections/1/all?type=1&tagId=61303&sort=originallyAvailableAt,year:nullsLast",
                ["55929", "55947", "55933", "96003"]),
        ]
    }

    /// UNTAMED: the first collection hub is movie-typed; the show's own
    /// collection comes second. Rick and Morty (25088) sits in both the
    /// collection and a people hub.
    private var untamed: [PlexHub] {
        [
            hub("collection.related.1.1", "movie", "Movies in IMDb Popular Collection",
                key: "/library/sections/1/all?type=1&tagId=353395&sort=taggingIndex:nullsLast,titleSort",
                ["140994", "141836", "141869", "14736", "127330", "139385", "61247", "61257", "129666"]),
            hub("collection.related.2.2", "show", "IMDb Popular Collection", more: true,
                key: "/library/sections/2/all?type=2&tagId=353395&sort=taggingIndex:nullsLast,titleSort",
                ["141852", "1160", "102973", "100408", "119495", "93597", "34356", "137938", "95007", "25088", "100200", "106687"]),
            hub("tv.same.actor.1", "show", "More with Sam Neill",
                key: "/library/sections/2/all?actor=162153&id!=141852",
                ["218758", "25711", "25088"]),
            hub("tv.same.actor.2", "show", "More with Rosemarie DeWitt",
                key: "/library/sections/2/all?actor=176790&id!=141852",
                ["221913", "219301", "218452"]),
        ]
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/PlexProviderRelatedTests
```

Expected: the test target does not compile. Errors include `type 'PlexProvider' has no member 'splitRelated'`, `method does not override any method from its superclass` (both `StubNetwork` overrides) and `value of type 'PlexProvider' has no member 'related'`, then `** TEST FAILED **`. If the build fails in a file this task does not touch (another session's Live TV work), stop and report it. Do not edit that file.

- [ ] **Step 3a: Implement: `getRelatedItems` returns raw hubs** (`RivuletCore/Plex/PlexNetworkManager.swift`)

Find:

```swift
    /// Get related items (similar content)
    func getRelatedItems(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        limit: Int = 12
    ) async throws -> [PlexMetadata] {
```

Replace with:

```swift
    /// The hubs `/library/metadata/{rk}/related` returns, raw: at most one
    /// `collection.related.*` hub per library section, then people and
    /// similar-title hubs. The caller decides which hub feeds which row.
    /// `limit` is the per-hub `count`.
    func getRelatedItems(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        limit: Int = 12
    ) async throws -> [PlexHub] {
```

Then find:

```swift
        // The /related endpoint nests items inside related Hubs (e.g. "Related
        // Movies", "More with …"); the top-level Metadata is usually empty. Flatten
        // the hubs (deduped by ratingKey), falling back to top-level Metadata.
        let mc = container.MediaContainer
        let fromHubs = (mc.Hub ?? []).flatMap { $0.Metadata ?? [] }
        let merged = fromHubs.isEmpty ? (mc.Metadata ?? []) : fromHubs
        var seen = Set<String>()
        let deduped = merged.filter { item in
            guard let key = item.ratingKey else { return true }
            return seen.insert(key).inserted
        }
        return Array(deduped.prefix(limit))
    }
```

Replace with:

```swift
        // Items normally arrive inside the hubs, with the top-level Metadata
        // empty. When no hub holds any, fall back to the top-level Metadata as
        // one untitled hub.
        let mc = container.MediaContainer
        let hubs = mc.Hub ?? []
        if hubs.contains(where: { !($0.Metadata ?? []).isEmpty }) { return hubs }
        return [PlexHub(Metadata: mc.Metadata ?? [])]
    }
```

- [ ] **Step 3b: Implement: replace `getCollectionItems` with `getCollection`** (same file)

Find:

```swift
    /// Get items in a collection (other movies in the same collection)
    /// - Parameters:
    ///   - sectionId: The library section ID containing the collection
    ///   - collectionId: The collection filter ID (from Collection[].id in metadata)
    ///   - excludeRatingKey: Optional ratingKey to exclude from results (typically current movie)
    func getCollectionItems(
        serverURL: String,
        authToken: String,
        sectionId: String,
        collectionId: String,
        excludeRatingKey: String? = nil
    ) async throws -> [PlexMetadata] {
        guard var components = URLComponents(string: "\(serverURL)/library/sections/\(sectionId)/all") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "collection", value: collectionId)
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        var items = container.MediaContainer.Metadata ?? []

        // Filter out the excluded item (current movie)
        if let exclude = excludeRatingKey {
            items = items.filter { $0.ratingKey != exclude }
        }

        return items
    }
```

Replace with:

```swift
    /// The collection a `collection.related` hub points at. A title's
    /// Collection tag id (the hub key's `tagId`) is the collection's `index`,
    /// not its ratingKey. Scoped to the hub's section because same-named
    /// collections in Movies and TV share one tag: `/library/all?type=18&index=`
    /// returns both, movie first.
    func getCollection(
        serverURL: String,
        authToken: String,
        sectionId: String,
        tagId: String
    ) async throws -> PlexMetadata? {
        guard var components = URLComponents(string: "\(serverURL)/library/sections/\(sectionId)/all") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "type", value: "18"),
            URLQueryItem(name: "index", value: tagId)
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )
        return container.MediaContainer.Metadata?.first
    }
```

- [ ] **Step 3c: Implement: the protocol and its result types** (`Rivulet/Services/MediaProvider/MediaProvider.swift`)

Find:

```swift
    /// Items in the same collection as the given `collectionName`. Returns
    /// items from the provider's library matching that collection tag.
    func collectionItems(matching collectionName: String, in library: MediaLibrary) async throws -> [MediaItem]

    /// Provider-curated "related/recommended like this" items.
    func relatedItems(for itemRef: MediaItemRef) async throws -> [MediaItem]
```

Replace with:

```swift
    /// Provider-curated "related/recommended like this" items, and the
    /// collection the item belongs to when the provider picks one. `kind` is
    /// the item's own kind, which a ref does not carry.
    func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent
```

Then find (end of file):

```swift
extension MediaProvider {
    func contentAdvisory(for ref: MediaItemRef) async throws -> ContentAdvisory? { nil }
}
```

Replace with:

```swift
extension MediaProvider {
    func contentAdvisory(for ref: MediaItemRef) async throws -> ContentAdvisory? { nil }
}

/// The Related row and, when the item has one, its collection row.
nonisolated struct RelatedContent: Sendable {
    let items: [MediaItem]
    let collection: CollectionRow?
}

/// The item's collection: the other members in the collection's own order,
/// and the collection itself as a trailing tile when the provider returned
/// only some of the members.
nonisolated struct CollectionRow: Sendable {
    let title: String
    let members: [MediaItem]
    let collection: MediaItem?
}
```

- [ ] **Step 3d: Implement: `PlexProvider.related(for:kind:)` and the split** (`Rivulet/Services/MediaProvider/Plex/PlexProvider.swift`)

First delete the dead `collectionItems(matching:in:)` stub. Its comment holds a dash character, so remove it by anchors instead of retyping it:

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
python3 - <<'PY'
p = "Rivulet/Services/MediaProvider/Plex/PlexProvider.swift"
s = open(p, encoding="utf-8").read()
start = s.index("    func collectionItems(matching collectionName: String, in library: MediaLibrary)")
end = s.index("    func relatedItems(for itemRef: MediaItemRef)", start)
open(p, "w", encoding="utf-8").write(s[:start] + s[end:])
PY
grep -n "collectionItems(matching" Rivulet/Services/MediaProvider/Plex/PlexProvider.swift   # expect no output
```

Then find:

```swift
    func relatedItems(for itemRef: MediaItemRef) async throws -> [MediaItem] {
        try await plexCall {
            let related = try await networkManager.getRelatedItems(
                serverURL: serverURL, authToken: authToken, ratingKey: itemRef.itemID
            )
            return related.map {
                PlexMediaMapper.item($0, providerID: id,
                                    serverURL: serverURL, authToken: authToken)
            }
        }
    }
```

Replace with:

```swift
    func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent {
        try await plexCall {
            func item(_ meta: PlexMetadata) -> MediaItem {
                PlexMediaMapper.item(meta, providerID: self.id,
                                    serverURL: self.serverURL, authToken: self.authToken)
            }
            let hubs = try await networkManager.getRelatedItems(
                serverURL: serverURL, authToken: authToken, ratingKey: ref.itemID
            )
            let split = Self.splitRelated(hubs: hubs, currentRatingKey: ref.itemID, kind: kind)
            var collection: CollectionRow?
            if let title = split.collectionTitle, !split.members.isEmpty {
                // Only a hub that reports `more` gets the trailing tile, and a
                // failed lookup keeps the row without it.
                var tile: MediaItem?
                if let tagId = split.tagId, let sectionId = split.sectionId,
                   let meta = try? await networkManager.getCollection(
                       serverURL: serverURL, authToken: authToken, sectionId: sectionId, tagId: tagId
                   ) {
                    tile = item(meta)
                }
                collection = CollectionRow(title: title, members: split.members.map(item), collection: tile)
            }
            return RelatedContent(items: split.related.map(item), collection: collection)
        }
    }

    /// The detail page's two rows, cut from one `/related` answer.
    nonisolated struct RelatedSplit {
        let related: [PlexMetadata]
        let collectionTitle: String?
        let members: [PlexMetadata]
        /// Set only when the collection hub reports `more`: the hub key's
        /// `tagId` and library section, which find the collection itself.
        let tagId: String?
        let sectionId: String?
    }

    /// Picks the item's collection hub: the first `collection.related.*` hub
    /// typed like the item, for movies and shows only, since a show's first
    /// collection hub can be movie-typed. Every other collection hub is
    /// dropped and the item itself is removed. The remaining hubs flatten
    /// into Related, deduped and capped at 12.
    nonisolated static func splitRelated(hubs: [PlexHub], currentRatingKey: String, kind: MediaKind) -> RelatedSplit {
        let itemType: String? = switch kind {
        case .movie: "movie"
        case .show: "show"
        default: nil
        }
        func isCollectionHub(_ hub: PlexHub) -> Bool {
            hub.hubIdentifier?.hasPrefix("collection.related.") == true
        }
        let collectionHub = itemType.flatMap { type in
            hubs.first { isCollectionHub($0) && $0.type == type }
        }
        let members = (collectionHub?.Metadata ?? []).filter { $0.ratingKey != currentRatingKey }

        var seen: Set<String> = [currentRatingKey]
        let related = hubs.filter { !isCollectionHub($0) }
            .flatMap { $0.Metadata ?? [] }
            .filter { item in
                guard let key = item.ratingKey else { return true }
                return seen.insert(key).inserted
            }

        var tagId: String?
        var sectionId: String?
        if collectionHub?.more == true,
           let key = collectionHub?.key,
           let components = URLComponents(string: key) {
            // /library/sections/1/all?type=1&tagId=353397&sort=...
            let path = components.path.split(separator: "/").map(String.init)
            if let tag = components.queryItems?.first(where: { $0.name == "tagId" })?.value,
               let i = path.firstIndex(of: "sections"), path.indices.contains(i + 1) {
                tagId = tag
                sectionId = path[i + 1]
            }
        }
        return RelatedSplit(
            related: Array(related.prefix(12)),
            collectionTitle: collectionHub?.title,
            members: members,
            tagId: tagId,
            sectionId: sectionId
        )
    }
```

(The `switch` over `kind` stands in for `kind.rawValue`, deliberately. It pattern-matches cases, so the nonisolated static never touches a conformance of the MainActor-inferred `MediaKind`.)

- [ ] **Step 3e: Implement: the loader keeps using only `.items`** (`Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldContentLoader.swift`)

Find:

```swift
        content.related = (try? await provider.relatedItems(for: item.ref)) ?? []
```

Replace with:

```swift
        content.related = (try? await provider.related(for: item.ref, kind: item.kind))?.items ?? []
```

Leave the header comment that names `collectionItems(matching:in:)` in place: Task 10 deletes it together with the loader's collection work.

- [ ] **Step 3f: Implement: update the stub** (`RivuletTests/Unit/HomeComposerTests.swift`, §9 test 5)

Find:

```swift
    func collectionItems(matching collectionName: String, in library: MediaLibrary) async throws -> [MediaItem] { [] }
    func relatedItems(for itemRef: MediaItemRef) async throws -> [MediaItem] { [] }
```

Replace with:

```swift
    func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent {
        RelatedContent(items: [], collection: nil)
    }
```

- [ ] **Step 3g: Confirm no other caller remains, iOS included**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && git grep -n "getCollectionItems\|relatedItems(for\|collectionItems(matching\|provider.relatedItems" -- '*.swift'; echo "---"; git grep -n "getRelatedItems\|getCollection(" -- RivuletiOS
```

Expected: the only hit before `---` is the loader's header comment (`collectionItems(matching:in:)`, which Task 10 removes). Nothing after `---`. `PlexProvider` and `StubMediaProvider` are the only `MediaProvider` conformers (`git grep -n "MediaProvider, @unchecked"`).

- [ ] **Step 4: Run it to verify it passes**

```bash
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/PlexProviderRelatedTests -only-testing:RivuletTests/HomeComposerTests -only-testing:RivuletTests/BelowFoldContentLoaderTests -only-testing:RivuletTests/BelowFoldRailScrollTests
```

Expected: all 7 `PlexProviderRelatedTests` pass, as do the stub's existing users (`HomeComposerTests`, `BelowFoldContentLoaderTests`, `BelowFoldRailScrollTests`), then `** TEST SUCCEEDED **`.

- [ ] **Step 5: Build both schemes (RivuletCore changed); lint**

```bash
xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd"
xcodebuild build -scheme 'Rivulet iOS' -destination 'generic/platform=iOS Simulator' -derivedDataPath "$SCRATCH/dd-ios"
swiftlint lint --strict
```

Expected: `** BUILD SUCCEEDED **` twice; swiftlint reports 0 violations. The iOS build must pass because `getRelatedItems`'s return type changed in shared code; `build-ios.yml` runs on this change.

- [ ] **Step 6: Visible-content check** (no focus code changed, so this can run on the Simulator against the real server)

1. Movies > Raiders of the Lost Ark > Select > press Down to the below-fold rows. Related starts with Catch Me If You Can, Disclosure Day, Hook, Jurassic Park and ends at The Secret Life of Pets 2 (12 tiles). It shows no Forrest Gump, no Fight Club, and not Raiders itself.
2. Diamonds Are Forever: **no Related row at all**. Its only `/related` hub is the Bond collection, and the Collection row that replaces it comes in Task 10. This is the expected in-between state, so do not tag a release between Task 9 and Task 10.
3. TV Shows > UNTAMED: Related shows Apples Never Fall, Peaky Blinders, Rick and Morty, Black Mirror, Lessons in Chemistry, Pantheon, and no IMDb Popular titles beyond those.

- [ ] **Step 7: Commit**

Run from the repo root. `PlexNetworkManager.swift` carries another session's Live TV hunks, so stage only this task's region: splice it onto HEAD between two anchors this task never edits (`func findByGuid(` and `/// Get children of an item`). Task 2's `getHubItems` (~946) and the Live TV hunks (~2369, ~3186) both fall outside that region.

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
F=RivuletCore/Plex/PlexNetworkManager.swift

git add Rivulet/Services/MediaProvider/MediaProvider.swift Rivulet/Services/MediaProvider/Plex/PlexProvider.swift Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldContentLoader.swift RivuletTests/Unit/HomeComposerTests.swift RivuletTests/Unit/Services/PlexProviderRelatedTests.swift

git show "HEAD:$F" > "$SCRATCH/head.swift"
python3 - "$SCRATCH" "$F" <<'EOF'
import sys
scratch, path = sys.argv[1], sys.argv[2]
head = open(f"{scratch}/head.swift", encoding="utf-8").read()
work = open(path, encoding="utf-8").read()
start, end = "    func findByGuid(", "    /// Get children of an item"
def cut(t):
    i = t.index(start)
    return i, t.index(end, i)
hi, hj = cut(head)
wi, wj = cut(work)
open(f"{scratch}/new.swift", "w", encoding="utf-8").write(head[:hi] + work[wi:wj] + head[hj:])
EOF
diff -u --label "a/$F" --label "b/$F" "$SCRATCH/head.swift" "$SCRATCH/new.swift" > "$SCRATCH/task9.patch"
git apply --check --cached "$SCRATCH/task9.patch"
git apply --cached "$SCRATCH/task9.patch"

# Staged shared-file diff must be only getRelatedItems + getCollection: expect 0 and 0.
git diff --cached -- "$F" | grep -c "PlexLiveTuneError\|getHubItems"
git diff --cached -U0 | grep '^+' | grep -cE $'\xe2\x80\x93|\xe2\x80\x94'

[ "$(git branch --show-current)" = test/integration ] && [ "$(git diff --cached --name-only | sort)" = "$(printf '%s\n' RivuletCore/Plex/PlexNetworkManager.swift Rivulet/Services/MediaProvider/MediaProvider.swift Rivulet/Services/MediaProvider/Plex/PlexProvider.swift Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldContentLoader.swift RivuletTests/Unit/HomeComposerTests.swift RivuletTests/Unit/Services/PlexProviderRelatedTests.swift | sort)" ] && git commit -m "Split related hubs into collection and related"
```

If either count is not 0, run `git restore --staged "$F"` (this touches only the index, never the working tree), fix the splice, and stage again. Never use `git commit -- <path>`.

---

### Task 10: Detail "In this collection" row

**Files:**
- Modify: `Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldContentLoader.swift` (file header comment ~17-20, `BelowFoldContent` ~35, Related line in `load(for:detail:)` ~139)
- Modify: `Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldCollectionView.swift` (`BelowFoldSectionKind`, `BelowFoldItem`, `relatedWidth`, `relatedByID`, cell registration, `makeLayout`, `configureDataSource`, new `configurePosterShelf`, `refreshWatchState`, new `applyRefreshedShelves`, `ingestEpisodesOnly`, `ingest`, stored shelf state, `applySnapshot`, `didSelectItemAt`, `restoreShelfRowFocusIfNeeded`)
- Modify: `Rivulet/Views/Media/MediaDetail/UIKit/Cells/BelowFoldCells.swift` (delete `RelatedPosterCell` and the now unused `import TVUIKit`)
- Modify: `RivuletTests/Unit/HomeComposerTests.swift` (`StubMediaProvider.related(for:kind:)` becomes configurable)
- Test: `RivuletTests/Unit/BelowFoldContentLoaderTests.swift` (existing file at the Unit root; new test method)

**Interfaces:**
- Consumes:
  - `MediaProvider.related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent` (Task 9)
  - `nonisolated struct RelatedContent: Sendable { let items: [MediaItem]; let collection: CollectionRow? }` and `nonisolated struct CollectionRow: Sendable { let title: String; let members: [MediaItem]; let collection: MediaItem? }` (Task 9, memberwise inits; explicitly Sendable, which `BelowFoldContent: Sendable` needs once it stores one)
  - Task 9's three-line `StubMediaProvider.related(for ref:kind:)` in `HomeComposerTests.swift`, and Task 9's rewrite of the loader's Related line under `// Related row.`
  - Task 4's `openCollectionIfNeeded` guard inside `PreviewCarouselViewController.presentStandaloneDetail(_:)`, including its pre-present `expandedDetail.restoreShelfRowFocusIfNeeded(requestingFocus: false)` arm and `onDismiss: restoreBelowFoldFocusAfterReturn`; Task 4 also added the `requestingFocus` parameter to `BelowFoldCollectionView.restoreShelfRowFocusIfNeeded`, which Step 3p keeps
- Produces:
  - `BelowFoldContent.collection: CollectionRow?`
  - `BelowFoldSectionKind.collection`, `BelowFoldItem.collectionShelf`
  - `StubMediaProvider.relatedContent: RelatedContent` and `StubMediaProvider.relatedKinds: [MediaKind]` (test stub)

- [ ] **Step 1: Write the failing test**

Preconditions (Tasks 4 and 9 committed). Run each; the first three must print hits, the last must print nothing:

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
grep -n "struct RelatedContent\|struct CollectionRow\|func related(for ref: MediaItemRef, kind: MediaKind)" Rivulet/Services/MediaProvider/MediaProvider.swift
grep -n "func related(for ref: MediaItemRef, kind: MediaKind)" RivuletTests/Unit/HomeComposerTests.swift
grep -n "openCollectionIfNeeded" Rivulet/Views/Media/PreviewCarousel/UIKit/PreviewCarouselViewController.swift
grep -rn "relatedItems(for" Rivulet RivuletTests
```

Also confirm no other session has uncommitted hunks in this task's files (must print nothing; if it prints anything, commit only your hunks with the patch route in the global constraints):

```bash
git diff --stat -- Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldContentLoader.swift Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldCollectionView.swift Rivulet/Views/Media/MediaDetail/UIKit/Cells/BelowFoldCells.swift RivuletTests/Unit/BelowFoldContentLoaderTests.swift RivuletTests/Unit/HomeComposerTests.swift
```

1a. Make the stub configurable. In `RivuletTests/Unit/HomeComposerTests.swift`, find Task 9's stub:

```swift
    func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent {
        RelatedContent(items: [], collection: nil)
    }
```

Replace with:

```swift
    /// What `related(for:kind:)` answers, and the kinds it was asked for.
    var relatedContent = RelatedContent(items: [], collection: nil)
    private(set) var relatedKinds: [MediaKind] = []
    func related(for ref: MediaItemRef, kind: MediaKind) async throws -> RelatedContent {
        relatedKinds.append(kind)
        return relatedContent
    }
```

(`StubMediaProvider` is a `final class ... @unchecked Sendable`, so the mutation compiles.)

1b. Add the test. In `RivuletTests/Unit/BelowFoldContentLoaderTests.swift`, find:

```swift
    private func item(_ id: String, _ kind: MediaKind, parent: String?) -> MediaItem {
```

Replace with:

```swift
    /// A movie's one `/related` answer feeds both rows: the collection row
    /// keeps Plex's hub title, its members and the trailing collection tile,
    /// and Related gets the rest. The loader passes the item's kind, which the
    /// provider's split needs to pick a movie-typed collection hub.
    func test_movieFillsCollectionRowFromTheRelatedCall() async {
        let stub = StubMediaProvider()
        stub.relatedContent = RelatedContent(
            items: [item("r1", .movie, parent: nil)],
            collection: CollectionRow(
                title: "James Bond Collection",
                members: [item("m1", .movie, parent: nil), item("m2", .movie, parent: nil)],
                collection: item("9144", .collection, parent: nil)
            )
        )
        MediaProviderRegistry.shared.register(stub)
        defer { MediaProviderRegistry.shared.unregister(providerID: stub.id) }

        let content = await BelowFoldContentLoader().load(for: item("m0", .movie, parent: nil), detail: nil)

        XCTAssertEqual(content.collection?.title, "James Bond Collection")
        XCTAssertEqual(content.collection?.members.map(\.ref.itemID), ["m1", "m2"])
        XCTAssertEqual(content.collection?.collection?.ref.itemID, "9144")
        XCTAssertEqual(content.related.map(\.ref.itemID), ["r1"])
        XCTAssertEqual(stub.relatedKinds, [.movie])
    }

    private func item(_ id: String, _ kind: MediaKind, parent: String?) -> MediaItem {
```

- [ ] **Step 2: Run it to verify it fails**

```bash
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/BelowFoldContentLoaderTests
```

Expected: the test target fails to compile with `error: value of type 'BelowFoldContent' has no member 'collection'`, then `** TEST FAILED **`.

- [ ] **Step 3: Implement**

3a. Loader: the new field. In `BelowFoldContentLoader.swift`, find:

```swift
    var related: [MediaItem] = []
    /// Default season to select in the pill bar.
```

Replace with:

```swift
    var related: [MediaItem] = []
    /// The collection row (Plex's collection hub for a movie or show, minus
    /// this item), from the same `related(for:kind:)` call as `related`.
    var collection: CollectionRow?
    /// Default season to select in the pill bar.
```

3b. Loader: fill it from the one call. Find the Related line as Task 9 left it:

```swift
        // Related row.
        content.related = (try? await provider.related(for: item.ref, kind: item.kind))?.items ?? []
```

Replace with:

```swift
        // Related row and the collection row: one `/related` call feeds both.
        if let related = try? await provider.related(for: item.ref, kind: item.kind) {
            content.related = related.items
            content.collection = related.collection
        }
```

3c. Loader: delete the stale header comment (the one saying collection items are intentionally omitted). Its first line contains a dash character, so remove it by anchors instead of retyping it:

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
python3 - <<'EOF'
p = "Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldContentLoader.swift"
s = open(p).read()
start = s.index("//  Collection items are intentionally omitted")
tail = "//  is follow-up plumbing.\n"
end = s.index(tail) + len(tail)
s = s[:start] + "//  The collection row and Related come from the same `related(for:kind:)`\n//  call.\n" + s[end:]
open(p, "w").write(s)
EOF
grep -n "intentionally omitted" Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldContentLoader.swift   # expect no output
```

3d. View: identifiers. In `BelowFoldCollectionView.swift`, three edits.

Find:

```swift
    case extras
    case related
    case cast
```

Replace with:

```swift
    case extras
    case collection
    case related
    case cast
```

Find:

```swift
    case extra(String)
    case related(String)
```

Replace with:

```swift
    case extra(String)
```

Find:

```swift
    case relatedShelf
    case cast(String)
```

Replace with:

```swift
    case relatedShelf
    /// The collection row, hosted exactly like `.relatedShelf`.
    case collectionShelf
    case cast(String)
```

3e. View: dead Related-poster state. Three edits.

Find:

```swift
    private static let relatedWidth: CGFloat = MediaRowMetrics.posterWidth
    private static let castWidth
```

Replace with:

```swift
    private static let castWidth
```

Find:

```swift
    private var relatedByID: [String: MediaItem] = [:]
    private var castEntriesByID: [String: CastEntry] = [:]
```

Replace with:

```swift
    private var castEntriesByID: [String: CastEntry] = [:]
```

Find:

```swift
        collectionView.register(RelatedPosterCell.self, forCellWithReuseIdentifier: RelatedPosterCell.reuseID)
        collectionView.register(ShelfRowCell.self, forCellWithReuseIdentifier: ShelfRowCell.reuseID)
```

Replace with:

```swift
        collectionView.register(ShelfRowCell.self, forCellWithReuseIdentifier: ShelfRowCell.reuseID)
```

3f. View: shared layout. Find:

```swift
            case .related:
                // Home-identical shelf: one full-width ShelfRowCell hosting
```

Replace with:

```swift
            case .related, .collection:
                // The collection row shares this: on a movie with no trailers
                // or extras it is the primary peek row, so it needs the same lift.
                // Home-identical shelf: one full-width ShelfRowCell hosting
```

3g. View: cell provider. Two edits in `configureDataSource()`.

Find:

```swift
            case .related(let id):
                let cell = cv.dequeueReusableCell(withReuseIdentifier: RelatedPosterCell.reuseID, for: indexPath) as! RelatedPosterCell
                if let it = self.relatedByID[id] { cell.configure(item: it) }
                return cell

            case .relatedShelf:
```

Replace with:

```swift
            case .relatedShelf:
```

Find:

```swift
            case .relatedShelf:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
                let items = self.relatedItems
                var hasher = Hasher()
                for it in items { hasher.combine(it.ref.itemID) }
                cell.cellProvider = { innerCV, ip in
                    let poster = innerCV.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: ip) as! PosterCell
                    if ip.item < items.count { poster.configure(item: items[ip.item]) }
                    return poster
                }
                cell.onSelect = { [weak self] idx in
                    guard let self, idx < self.relatedItems.count else { return }
                    self.onShowRelatedDetails?(self.relatedItems[idx])
                }
                cell.onWillDisplayItem = nil
                cell.onLongPressItem = nil
                cell.onOffsetChanged = nil
                // Self-align to the screen's rowLeading (robust to the
                // below-fold's state-dependent translation), and draw the
                // header in-cell so it aligns with the tiles.
                cell.screenAlignsLeading = true
                cell.headerTitle = "Related"
                cell.configure(
                    kind: .poster,
                    realCount: items.count,
                    hasSkeleton: false,
                    contentToken: hasher.finalize(),
                    initialOffset: 0
                )
                return cell
```

Replace with:

```swift
            case .collectionShelf:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
                let row = self.collectionRow
                self.configurePosterShelf(cell, section: .collection, title: row?.title ?? "",
                                          items: row?.members ?? [], trailing: row?.collection)
                return cell
            case .relatedShelf:
                let cell = cv.dequeueReusableCell(withReuseIdentifier: ShelfRowCell.reuseID, for: indexPath) as! ShelfRowCell
                self.configurePosterShelf(cell, section: .related, title: "Related",
                                          items: self.relatedItems, trailing: nil)
                return cell
```

3h. View: the empty-header group. Find:

```swift
            case .episodes, .about, .info: header.configure(title: "")
```

Replace with:

```swift
            case .episodes, .collection, .about, .info: header.configure(title: "")
```

3i. View: the one shelf helper. Find:

```swift
    // MARK: - Configure (fetch + populate)
```

Replace with:

```swift
    /// One body for both poster shelves (Collection, Related) so they cannot
    /// drift. Every tile, the trailing collection tile included, opens through
    /// `onShowRelatedDetails`; `presentStandaloneDetail` routes a collection
    /// to its page. The content token hashes each tile's ratingKey and watch
    /// state, so a watch-state refresh reloads the row (under the shelf's
    /// cross-dissolve) only when a glyph moved. The row keeps its horizontal
    /// offset across that reload and across host-cell reuse.
    private func configurePosterShelf(_ cell: ShelfRowCell,
                                      section: BelowFoldSectionKind,
                                      title: String,
                                      items: [MediaItem],
                                      trailing: MediaItem?) {
        let tiles = items + (trailing.map { [$0] } ?? [])
        var hasher = Hasher()
        for tile in tiles {
            hasher.combine(tile.ref.itemID)
            hasher.combine(tile.userState.isPlayed)
            hasher.combine(tile.userState.viewOffset)
        }
        cell.cellProvider = { innerCV, ip in
            let poster = innerCV.dequeueReusableCell(withReuseIdentifier: PosterCell.reuseID, for: ip) as! PosterCell
            if ip.item < tiles.count { poster.configure(item: tiles[ip.item]) }
            return poster
        }
        cell.onSelect = { [weak self] idx in
            guard let self, idx < tiles.count else { return }
            self.onShowRelatedDetails?(tiles[idx])
        }
        cell.onWillDisplayItem = nil
        cell.onLongPressItem = nil
        cell.onOffsetChanged = { [weak self] offset in self?.shelfOffsets[section] = offset }
        // Self-align to the screen's rowLeading (robust to the
        // below-fold's state-dependent translation), and draw the
        // header in-cell so it aligns with the tiles.
        cell.screenAlignsLeading = true
        cell.headerTitle = title
        cell.configure(
            kind: .poster,
            realCount: tiles.count,
            hasSkeleton: false,
            contentToken: hasher.finalize(),
            initialOffset: shelfOffsets[section] ?? 0
        )
    }

    // MARK: - Configure (fetch + populate)
```

3j. View: watch-state refresh re-runs `related(for:kind:)`. In `refreshWatchState()`, find:

```swift
            guard self.refreshToken == refresh, self.loadToken == load, !eps.isEmpty else { return }
            self.applyRefreshedEpisodes(eps)
        }
    }
```

Replace with:

```swift
            guard self.refreshToken == refresh, self.loadToken == load else { return }
            if !eps.isEmpty { self.applyRefreshedEpisodes(eps) }
            // Collection and Related tiles carry watch glyphs too. Same call
            // and same kinds as the loader's collection row; it runs after the
            // rail repaint so the rail never waits on a second GET.
            guard item.kind == .movie || item.kind == .show,
                  let fresh = try? await provider.related(for: item.ref, kind: item.kind),
                  self.refreshToken == refresh, self.loadToken == load else { return }
            self.applyRefreshedShelves(fresh)
        }
    }
```

3k. View: repaint both shelf host cells in place. Find:

```swift
    private var refreshToken: UInt64 = 0
```

Replace with:

```swift
    private var refreshToken: UInt64 = 0

    /// Swap refreshed Collection members and Related items into their stores
    /// and reconfigure the two shelf host cells in place, which re-runs
    /// `configurePosterShelf` on the EXISTING cells. The collection row keeps
    /// its title and trailing tile from the load: only watch state is news.
    // ponytail: a refresh never adds or removes a row, so a collection or
    // Related row that appears or empties between load and refresh waits for
    // the next open; insert/delete with a focus hand-off if that ever matters.
    private func applyRefreshedShelves(_ fresh: RelatedContent) {
        var snapshot = dataSource.snapshot()
        let present = snapshot.itemIdentifiers
        var targets: [BelowFoldItem] = []
        if present.contains(.collectionShelf), let row = collectionRow,
           let members = fresh.collection?.members, !members.isEmpty {
            collectionRow = CollectionRow(title: row.title, members: members, collection: row.collection)
            targets.append(.collectionShelf)
        }
        if present.contains(.relatedShelf), !fresh.items.isEmpty {
            relatedItems = fresh.items
            targets.append(.relatedShelf)
        }
        guard !targets.isEmpty else { return }
        snapshot.reconfigureItems(targets)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
```

3l. View: ingest. Three edits.

In `ingestEpisodesOnly`, find:

```swift
        trailersByID = [:]; extrasByID = [:]; relatedByID = [:]; castEntriesByID = [:]
        cachedTrailers = []; cachedExtras = []; cachedRelated = []; cachedCastOrder = []
```

Replace with:

```swift
        trailersByID = [:]; extrasByID = [:]; castEntriesByID = [:]
        cachedTrailers = []; cachedExtras = []; cachedRelated = []; cachedCastOrder = []
        collectionRow = nil; shelfOffsets = [:]
```

In `ingest`, find:

```swift
        extrasByID = Dictionary(content.extras.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        relatedByID = Dictionary(content.related.map { ($0.ref.itemID, $0) }, uniquingKeysWith: { a, _ in a })
```

Replace with:

```swift
        extrasByID = Dictionary(content.extras.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
```

Find:

```swift
        relatedItems = content.related
        cachedRelated = content.related.isEmpty ? [] : [BelowFoldItem.relatedShelf]
```

Replace with:

```swift
        relatedItems = content.related
        cachedRelated = content.related.isEmpty ? [] : [BelowFoldItem.relatedShelf]
        collectionRow = content.collection
        shelfOffsets = [:]
```

3m. View: stored shelf state. Find:

```swift
    /// Ordered Related items backing the shelf (index == shelf tile index).
    private var relatedItems: [MediaItem] = []
```

Replace with:

```swift
    /// Ordered Related items backing the shelf (index == shelf tile index).
    private var relatedItems: [MediaItem] = []
    /// The collection row (Plex's hub title, members, optional trailing
    /// collection tile). nil or no members: no row.
    private var collectionRow: CollectionRow?
    /// Each poster shelf's resting horizontal offset, so a content reload or
    /// a reused host cell does not throw the row back to its first tile.
    private var shelfOffsets: [BelowFoldSectionKind: CGFloat] = [:]
```

3n. View: snapshot order Trailers, Extras, Collection, Related, Cast, About, Info. In `applySnapshot()`, find:

```swift
        if !cachedRelated.isEmpty { add(.related, cachedRelated) }
```

Replace with:

```swift
        if let row = collectionRow, !row.members.isEmpty { add(.collection, [.collectionShelf]) }
        if !cachedRelated.isEmpty { add(.related, cachedRelated) }
```

3o. View: dead `.related` select branch. In `collectionView(_:didSelectItemAt:)`, find:

```swift
        // Related poster Select → open that item's detail page.
        if case let .related(id) = dataSource.itemIdentifier(for: indexPath),
           let item = relatedByID[id] {
            onShowRelatedDetails?(item)
        }
        // Cast / crew cell Select → open the person detail page.
```

Replace with:

```swift
        // Cast / crew cell Select → open the person detail page.
```

3p. View: the Required fix to `restoreShelfRowFocusIfNeeded`. Find:

```swift
        // Find the shelf host by identity, not by `lastFocusedIndexPath`: a shelf
        // row is ONE cell, so its index path is the same value for every tile in
        // it and can never say which tile had focus. The tile index lives on the
        // row itself (`lastFocusedItemIndex`).
        guard let shelf = collectionView.visibleCells
            .compactMap({ $0 as? ShelfRowCell })
            .first(where: { $0.lastFocusedItemIndex != nil }),
              let item = shelf.lastFocusedItemIndex else { return }
```

Replace with:

```swift
        // The collection's last focused index path names the ROW (a shelf row is
        // ONE cell, so every tile in it shares that path); the tile index lives
        // on the row itself (`lastFocusedItemIndex`). Do not pick the first
        // visible shelf with a tile index instead: `ShelfRowCell` clears it only
        // in `prepareForReuse`, so with Collection and Related both on screen
        // the row focus left earlier can still carry one and win.
        guard let path = collectionView.lastFocusedIndexPath,
              let shelf = collectionView.cellForItem(at: path) as? ShelfRowCell,
              let item = shelf.lastFocusedItemIndex else { return }
```

3q. Cells: delete `RelatedPosterCell` and its import. In `BelowFoldCells.swift`, find:

```swift
import UIKit
import TVUIKit
```

Replace with:

```swift
import UIKit
```

Then delete the class by its MARK anchors (everything from `// MARK: - Related poster` up to, not including, `// MARK: - Section header`):

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
python3 - <<'EOF'
p = "Rivulet/Views/Media/MediaDetail/UIKit/Cells/BelowFoldCells.swift"
s = open(p).read()
start = s.index("// MARK: - Related poster")
end = s.index("// MARK: - Section header")
s = s[:start] + s[end:]
open(p, "w").write(s)
EOF
grep -rn "RelatedPosterCell\|relatedByID\|TVPosterView" Rivulet/Views/Media/MediaDetail   # expect no output
```

- [ ] **Step 4: Run it to verify it passes**

```bash
xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd" -only-testing:RivuletTests/BelowFoldContentLoaderTests -only-testing:RivuletTests/HomeComposerTests -only-testing:RivuletTests/BelowFoldRailScrollTests
```

Expected: `Test Suite 'BelowFoldContentLoaderTests' passed` (3 tests, including `test_movieFillsCollectionRowFromTheRelatedCall`), `Test Suite 'HomeComposerTests' passed`, `Test Suite 'BelowFoldRailScrollTests' passed` unchanged (the only test that drives `BelowFoldCollectionView` through `configure`, ingest and the snapshot this task rewrites), `** TEST SUCCEEDED **`. This build compiles the whole tvOS app target, so it also proves the view edits compile.

- [ ] **Step 5: Lint** (RivuletCore is untouched by this task, so the iOS build is not required; the tvOS app compiled in Step 4)

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
swiftlint lint --strict
grep -rn "RelatedPosterCell\|relatedByID\|case related(String)\|\.related(let" Rivulet RivuletTests   # expect no output
git diff -U0 -- Rivulet/Views/Media/MediaDetail RivuletTests/Unit/BelowFoldContentLoaderTests.swift RivuletTests/Unit/HomeComposerTests.swift | grep '^+' | grep -nE $'\xe2\x80\x93|\xe2\x80\x94'   # expect no output
```

Expected: swiftlint `Found 0 violations`; both greps print nothing.

- [ ] **Step 6: Device verification**

Run the Rivulet scheme on the Apple TV from Xcode (device destination), signed into the home PMS (Movies = section 1, TV = section 2). Simulator focus results are provisional; every check below is for the device. Titles and rating keys were read from that server on 2026-09-30. Run Task 4's checks 6g and 6h on this build too.

1. Release order, without itself, no trailing tile. Movies > Diamonds Are Forever (rk 55947) > Select, then Down into details. Expected: after its Trailers/Extras, a row titled "James Bond Collection" showing Dr. No, Live and Let Die, No Time to Die in that order; Diamonds Are Forever is absent; no trailing collection tile (4 members, hub `more` false); Related follows if the movie has other hubs; Cast after that.
2. Related split. Raiders of the Lost Ark (rk 87157) > Down into details. Expected: a row titled "IMDb Top 250 Collection": Forrest Gump, Fight Club, The Silence of the Lambs ... Braveheart (11 tiles, Raiders absent), then a 12th trailing tile for the IMDb Top 250 collection itself. Related below it shows the Spielberg and Harrison Ford titles (Catch Me If You Can, Hook, Blade Runner 2049, ...), none of the IMDb Top 250 members, no TV shows, and not Raiders.
3. Trailing tile opens the page and focus comes back to it. In Raiders' collection row press Right until the trailing tile holds focus (the row scrolls to its end). Select. Expected: the IMDb Top 250 collection page opens. Press Menu. Expected: back on Raiders' details with focus on the trailing tile and the row still scrolled to its end.
4. Required fix, two shelves on screen. In Raiders' details: Down to Related, Right once (Related tile 2 focused). Up into the collection row, Right to the trailing tile, Select, then Menu. Expected: focus returns to the collection row's trailing tile; Related tile 2 stays unfocused. Then focus collection tile 3, press Up until a trailer holds focus, Select to play it, press Menu to exit the player. Expected: focus returns to that trailer, not to the collection row (before this fix the first visible shelf with a remembered tile won).
5. Watch state repaints in place. In Raiders' collection row, Right to Braveheart (last member). Select to open its standalone detail, Select the Watched (checkmark) button, press Menu. Expected: without leaving Raiders' details, Braveheart's tile shows the new watched state after a brief cross-dissolve and the row stays scrolled to its end. Repeat on a Related tile. Toggle both back afterwards to restore the server state.
   Playback variant (spec §9 watches a member to the end, which posts `.plexDataNeedsRefresh` about 2s after the player exits, while the standalone detail is still on top, so it meets the refresh and load tokens in a different order): in Raiders' collection row, Select Braveheart, Play, scrub into the last minute and let it end, press Menu back to the standalone detail and Menu again. Expected: after the cross-dissolve Braveheart's tile shows the watched glyph and the row is still scrolled to its end. Mark Braveheart unwatched afterwards.
6. Primary peek row. Aladdin and the King of Thieves (rk 63793; no trailers or extras, its only hub is Disney Collection). Expected at carousel rest: the bottom peek strip is Disney Collection posters with the "Disney Collection" title just above them (same geometry as a Related-only movie); Down slides the row up with the backdrop blur and metadata fade; no Related row; a trailing collection tile ends the row.
7. Shows. TV > UNTAMED (rk 141852) > Down into details. Expected: a row titled "IMDb Popular Collection" (shows) with a trailing tile; no "Movies in IMDb Popular Collection" row.
8. Stack unwinds (Task 4's guard, reachable only through this row). From step 3's IMDb Top 250 page, Select Forrest Gump, Down into its details, Right to its "IMDb Top 250 Collection" row's trailing tile, Select. Expected: the existing IMDb Top 250 page comes back (the Forrest Gump detail unwinds); one more Menu returns to Raiders' details, not to a second copy of the page.

- [ ] **Step 7: Commit**

```bash
cd "/Users/bain/git/Swift Projects/Rivulet"
git add Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldContentLoader.swift Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldCollectionView.swift Rivulet/Views/Media/MediaDetail/UIKit/Cells/BelowFoldCells.swift RivuletTests/Unit/BelowFoldContentLoaderTests.swift RivuletTests/Unit/HomeComposerTests.swift
[ "$(git branch --show-current)" = test/integration ] && [ "$(git diff --cached --name-only | sort)" = "$(printf '%s\n' Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldContentLoader.swift Rivulet/Views/Media/MediaDetail/UIKit/BelowFoldCollectionView.swift Rivulet/Views/Media/MediaDetail/UIKit/Cells/BelowFoldCells.swift RivuletTests/Unit/BelowFoldContentLoaderTests.swift RivuletTests/Unit/HomeComposerTests.swift | sort)" ] && git commit -m "Detail: show the movie's collection row"
```

---

### Task 11: Changelog and release

Spec §10. Release notes live only in `WhatsNewView.changelogs` (`Rivulet/Views/Components/WhatsNewView.swift`), keyed `"<CFBundleShortVersionString> (<build>)"`. CI takes the build number from the tag suffix (`v1.0.7-91` gives `"1.0.7 (91)"`), and the fresh-launch What's New has no fallback for a key that misses, so the key must come from the real tag.

**Files:**
- Modify: `Rivulet/Views/Components/WhatsNewView.swift` (one entry for the release, newest first)

**Interfaces:**
- Consumes: the commits of Tasks 1 to 10 that are in the release.
- Produces: one `changelogs` entry keyed from the release tag.

- [ ] **Step 1: Confirm the release boundary.** Run `git log --oneline <last release tag>..HEAD` and list which tasks' commits the release contains. Stop and ask the user if the range has Task 3 or 4 without Task 5 (nothing can open a collection page yet), or Task 9 without Task 10 (titles whose only `/related` hub is their collection lose the Related row). Also confirm the spec was amended per "Spec deviations" at the top of this plan; if it was not, amend those passages and commit the spec on its own (`Docs: align collections spec with plan`) before the changelog commit.

- [ ] **Step 2: Get the tag.** Ask the user for the release tag, or read it once they have pushed it (`git describe --tags --abbrev=0`). Never derive the build number from `CURRENT_PROJECT_VERSION`, TestFlight or arithmetic.

- [ ] **Step 3: Write the entry with the skill.** Invoke the `rivulet-changelog` skill with the tag and one bullet per user-facing step the release contains, from spec §10:
  - Task 2 (step 0b): "Long rows on Home, including collections from Plex, now keep loading as you scroll."
  - Tasks 3 and 4 (step 1): "Collections now open to a page of their titles."
  - Task 5 (step 2; Task 1 folds in here): "Movie and TV libraries show a Collections row."
  - Steps 1 and 2 always ship together (Global Constraints), so their two bullets always go in the same entry, next to each other.
  - Task 6 (step 3): "Switch a library's grid between titles and collections."
  - Tasks 7 and 8 (step 4): "Pin a collection to Home from its tile menu."
  - Tasks 9 and 10 (step 5): "Movie pages show the rest of the movie's collection."

  The skill owns the length cap and wording checks; if it asks for a shorter bullet, shorten it and keep the meaning. If the same release carries an AetherEngine bump, its line states only the version.

- [ ] **Step 4: Verify.** The new key matches the tag exactly (`grep -n '"<version> (<build>)"' Rivulet/Views/Components/WhatsNewView.swift` hits once), the entry is first in `changelogs`, and the dash check on the diff prints nothing. Build the tvOS scheme: `xcodebuild build -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath "$SCRATCH/dd"`.

- [ ] **Step 5: Commit.**
```bash
cd "/Users/bain/git/Swift Projects/Rivulet" && git add Rivulet/Views/Components/WhatsNewView.swift && [ "$(git branch --show-current)" = test/integration ] && [ "$(git diff --cached --name-only | sort)" = "$(printf '%s\n' Rivulet/Views/Components/WhatsNewView.swift | sort)" ] && git commit -m "Changelog: collections"
```
