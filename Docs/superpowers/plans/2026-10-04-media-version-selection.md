# Media Version Selection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Play the best file of a multi-version movie or episode by default, let the user pick another file from the detail page or the tile menu, and show Plex edition names.

**Architecture:** One shared ranking (`VersionRanking`) decides the best file for both the Plex player path and every `MediaProvider`. The Plex player moves the chosen `Media` to the front of `metadata.Media`, so the 40-plus existing `Media.first` reads play it unchanged; the Plex HLS fallback gets the version's server index as `mediaIndex`. A small `VersionPicker` builds the "Play Version" list on top of the existing `TileMenuPopupViewController`, and the version id travels through each play funnel as an optional parameter.

**Tech Stack:** Swift (language mode 5, app target default isolation MainActor), UIKit on tvOS 26, XCTest.

**Spec:** `Docs/superpowers/specs/2026-10-02-media-version-selection-design.md` (commits `f56d7d8`, `718e0f5`). Read it before Task 1. Edition names (Task 7) were added after the spec on 2026-10-04: Plex editions stay separate items as Plex presents them, and Rivulet now shows the edition name.

## Global Constraints

- Plex editions (`editionTitle`) are separate library items. No edition prompt and no grouping; Task 7 only displays the name.
- A version pick applies to one play. Nothing is persisted.
- Ranking order: resolution tier (2160, 1080, 720, 576, 480), then dynamic range (Dolby Vision, HDR10+, HDR10, HLG, SDR), then bitrate (missing counts as 0). Ties keep server order.
- No `#if os(...)` under `RivuletCore/`. The only RivuletCore change is a defaulted `mediaIndex` parameter.
- Provider-agnostic: no `isJellyfin` or `as? JellyfinProvider` branches. The only allowed special case is the existing Plex legacy path (`item.ref.isPlex`).
- UIKit only on these surfaces. No SwiftUI.
- Keep code comments to one or two short lines.
- User-facing strings: "Play Version" (header), "Play Version…" (tile menu row, with the single-character ellipsis). No em or en dashes anywhere.
- Commits: no per-task commits. Three commits at the goal boundaries (end of Task 6, end of Task 7, Task 8's changelog), each with explicit paths. Subagents never commit. Never push.
- The checkout is shared with other Claude sessions that leave uncommitted work. Work in a git worktree (superpowers:using-git-worktrees) and copy `RivuletCore/Config/Secrets.swift` into it, or commit only the paths this plan names.

## Test and build commands

Never run tests on the user's simulator ("Rivulet Testing ATV 1080p", `5A84266C-…`): `xcodebuild test` shuts its target down. Before each run, check no other session is testing on yours: `ps -axo command | grep '[x]codebuild'`.

```bash
DEST='platform=tvOS Simulator,id=0E1D6BEA-674E-4EA5-BF3E-67FAE0021A5A'   # "Apple TV", unused by the user
DD="$TMPDIR/rivulet-versions-dd"
# one test class
xcodebuild test -scheme Rivulet -destination "$DEST" -derivedDataPath "$DD" \
  -only-testing:RivuletTests/VersionRankingTests 2>&1 | grep -E "error:|Test Case.*(passed|failed)|TEST (SUCCEEDED|FAILED)" | tail -40
# app build (xcodebuild build defaults to Release; force Debug)
xcodebuild build -scheme Rivulet -configuration Debug -destination "$DEST" -derivedDataPath "$DD" 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -20
```

`print` output never reaches the console in tvOS tests; put values in assertion messages.

## Review Focus

1. **A metadata refresh during playback replaces `metadata.Media` with server order.** Expected: the picked file keeps playing and the info panel keeps naming it. Pinned by `test_select_source_findsTheSameVersionInAFreshServerOrder` (Task 1) and the `applyVersion(currentVersionChoice, …)` call sites (Task 2).
2. **The Plex HLS fallback while a non-first version plays.** Expected: the server transcodes that same file. Pinned by `test_init_recordsTheServerIndexOfTheBestVersion` (Task 2) and `test_buildHLSDirectPlayURL_sendsTheVersionIndex` (Task 2).
3. **Versions that rank equal** (Jellyfin sources with no stream info, two identical encodes). Expected: server order kept, no crash. Pinned by `test_ordered_tiesKeepServerOrder` (Task 1).
4. **A stacked Plex file** (one `Media`, two `Part`s) maps to two `MediaSource`s with the same id. Expected: no Versions button. Pinned by `test_versions_stackedFileIsOneVersion` (Task 4).
5. **A picked version on an item whose `Media` arrives after init** (hub metadata). Expected: the pick survives the fill. Pinned by `test_init_withoutMedia_keepsThePickedID` (Task 2).

---

### Task 1: VersionRanking and MediaSource badge pieces

**Files:**
- Create: `Rivulet/Models/Media/VersionRanking.swift`
- Modify: `Rivulet/Models/Media/MediaSource.swift` (add `versionName`, split `qualityBadges()` into pieces, share the tier rule)
- Test: `RivuletTests/Unit/VersionRankingTests.swift` (create)

**Interfaces:**
- Produces:
  - `enum VersionChoice: Equatable, Sendable { case best; case source(String); case matchingTier(Int) }`
  - `VersionRanking.Key` (`tier: Int`, `range: Int`, `bitrate: Int`, `Comparable`)
  - `VersionRanking.tier(label: String?, height: Int?) -> Int` (2160, 1080, 720, 576, 480, or 0 for unknown)
  - `VersionRanking.key(_: MediaSource) -> Key` and `VersionRanking.key(_: PlexMedia) -> Key`
  - `VersionRanking.ordered(_: [MediaSource]) -> [MediaSource]` (de-duplicated by id, best first)
  - `VersionRanking.choose(_: VersionChoice, from: [MediaSource]) -> MediaSource?`
  - `VersionRanking.select(_: VersionChoice, in: [PlexMedia]) -> (media: [PlexMedia], serverIndex: Int)`
  - `MediaItemDetail.primarySource: MediaSource?`
  - `MediaSource.versionName: String?` (defaulted `var`), `MediaSource.resolutionBadge`, `.rangeBadge`, `.audioBadge` (`String?`)

- [ ] **Step 1: Write the failing tests**

Create `RivuletTests/Unit/VersionRankingTests.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class VersionRankingTests: XCTestCase {

    private func source(_ id: String, res: String? = nil, height: Int? = nil,
                        range: VideoTrack.VideoRange = .sdr, bitrate: Int? = nil) -> MediaSource {
        let video = height.map {
            VideoTrack(id: "v\(id)", codec: "hevc", profile: nil, level: nil, width: nil, height: $0,
                       frameRate: nil, bitrate: nil, videoRange: range, isDefault: true, scanType: nil)
        }
        return MediaSource(id: id, container: "mkv", duration: 100, bitrate: bitrate, fileSize: nil,
                           fileName: nil, videoResolution: res, videoTracks: video.map { [$0] } ?? [],
                           audioTracks: [], subtitleTracks: [], streamKind: .directPlay, streamURL: nil)
    }

    private func plexMedia(_ json: String) throws -> [PlexMedia] {
        try JSONDecoder().decode([PlexMedia].self, from: Data(json.utf8))
    }

    // Two Sweeney Todd files, listed SD first so ranking has to reorder them.
    private let sdFirst = """
    [{"id":22249,"videoResolution":"sd","height":336,"bitrate":695,
      "Part":[{"id":2,"key":"/library/parts/2/b.avi","Stream":[{"id":21,"streamType":1,"codec":"mpeg4","height":336}]}]},
     {"id":260721,"videoResolution":"1080","height":1080,"bitrate":6564,
      "Part":[{"id":1,"key":"/library/parts/1/a.mkv","Stream":[{"id":11,"streamType":1,"codec":"hevc","height":1080}]}]}]
    """

    func test_tier_labelBeatsHeight_andCroppedWidescreenIs1080() {
        XCTAssertEqual(VersionRanking.tier(label: "4k", height: 1600), 2160)
        XCTAssertEqual(VersionRanking.tier(label: "sd", height: nil), 480)
        XCTAssertEqual(VersionRanking.tier(label: nil, height: 800), 1080)
        XCTAssertEqual(VersionRanking.tier(label: nil, height: nil), 0)
    }

    func test_ordered_tierBeatsRange_rangeBeatsBitrate() {
        let ranked = VersionRanking.ordered([
            source("hd-sdr-fat", height: 1080, bitrate: 40_000_000),
            source("hd-dv", height: 1080, range: .dolbyVision(profile: 8), bitrate: 8_000_000),
            source("uhd-sdr", height: 2160, bitrate: 1_000_000),
        ])
        XCTAssertEqual(ranked.map(\.id), ["uhd-sdr", "hd-dv", "hd-sdr-fat"])
    }

    func test_ordered_missingBitrateCountsAsZero() {
        let ranked = VersionRanking.ordered([source("a", height: 1080), source("b", height: 1080, bitrate: 1)])
        XCTAssertEqual(ranked.map(\.id), ["b", "a"])
    }

    func test_ordered_tiesKeepServerOrder() {
        let ranked = VersionRanking.ordered([source("first"), source("second"), source("third")])
        XCTAssertEqual(ranked.map(\.id), ["first", "second", "third"])
    }

    func test_ordered_collapsesDuplicateIDs() {
        // PlexMediaMapper emits one MediaSource per Part, all with the Media id.
        let ranked = VersionRanking.ordered([source("m", height: 1080), source("m", height: 1080)])
        XCTAssertEqual(ranked.count, 1)
    }

    func test_choose_sourceAndTier_fallBackToBest() {
        let sources = [source("hd", height: 1080), source("uhd", height: 2160)]
        XCTAssertEqual(VersionRanking.choose(.best, from: sources)?.id, "uhd")
        XCTAssertEqual(VersionRanking.choose(.source("hd"), from: sources)?.id, "hd")
        XCTAssertEqual(VersionRanking.choose(.source("gone"), from: sources)?.id, "uhd")
        XCTAssertEqual(VersionRanking.choose(.matchingTier(1080), from: sources)?.id, "hd")
        XCTAssertEqual(VersionRanking.choose(.matchingTier(720), from: sources)?.id, "uhd")
        XCTAssertNil(VersionRanking.choose(.best, from: []))
    }

    func test_select_movesBestToFront_andReportsServerIndex() throws {
        let selection = VersionRanking.select(.best, in: try plexMedia(sdFirst))
        XCTAssertEqual(selection.media.map(\.id), [260721, 22249])
        XCTAssertEqual(selection.serverIndex, 1)
    }

    func test_select_source_findsTheSameVersionInAFreshServerOrder() throws {
        // A refresh hands back server order; the picked id must come out on top again.
        let selection = VersionRanking.select(.source("22249"), in: try plexMedia(sdFirst))
        XCTAssertEqual(selection.media.first?.id, 22249)
        XCTAssertEqual(selection.serverIndex, 0)
    }

    func test_select_emptyMedia_isANoOp() {
        let selection = VersionRanking.select(.best, in: [])
        XCTAssertTrue(selection.media.isEmpty)
        XCTAssertEqual(selection.serverIndex, 0)
    }

    func test_primarySource_isTheBestVersion() {
        let item = JellyfinFixtures.mediaItem("m1")
        let detail = MediaItemDetail(
            item: item, tagline: nil, genres: [], studios: [], cast: [], directors: [], writers: [],
            chapters: [], mediaSources: [source("hd", height: 1080), source("uhd", height: 2160)],
            trailerURL: nil, contentRating: nil, rating: nil, nextEpisode: nil, collections: [])
        XCTAssertEqual(detail.primarySource?.id, "uhd")
    }
}
```

- [ ] **Step 2: Run the tests and confirm they fail**

Run the one-class command with `-only-testing:RivuletTests/VersionRankingTests`.
Expected: build failure, "cannot find 'VersionRanking' in scope".

- [ ] **Step 3: Create `Rivulet/Models/Media/VersionRanking.swift`**

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  VersionRanking.swift
//  Rivulet
//
//  Which file of a multi-version item plays. One rule for Plex and every
//  MediaProvider: resolution tier, then dynamic range, then bitrate.
//

import Foundation

enum VersionChoice: Equatable, Sendable {
    case best
    case source(String)        // Plex Media.id / Jellyfin MediaSource.Id
    case matchingTier(Int)     // a `VersionRanking.tier` value; Up Next keeps it
}

enum VersionRanking {
    struct Key: Comparable {
        let tier: Int
        let range: Int
        let bitrate: Int

        static func < (a: Key, b: Key) -> Bool {
            (a.tier, a.range, a.bitrate) < (b.tier, b.range, b.bitrate)
        }
    }

    /// Resolution class: 2160, 1080, 720, 576, 480, or 0 when unknown. The
    /// provider's label wins over pixel height, which crops below nominal.
    static func tier(label: String?, height: Int?) -> Int {
        switch label?.lowercased() {
        case "4k", "2160": return 2160
        case "1080": return 1080
        case "720": return 720
        case "576": return 576
        case "480", "sd": return 480
        default: break
        }
        guard let height else { return 0 }
        switch height {
        case 1600...: return 2160
        case 800..<1600: return 1080
        case 620..<800: return 720
        case 500..<620: return 576
        case 1..<500: return 480
        default: return 0
        }
    }

    static func rangeRank(_ range: VideoTrack.VideoRange) -> Int {
        switch range {
        case .dolbyVision: 4
        case .hdr10Plus: 3
        case .hdr10: 2
        case .hlg: 1
        case .sdr: 0
        }
    }

    static func key(_ source: MediaSource) -> Key {
        let video = source.videoTracks.first
        return Key(tier: tier(label: source.videoResolution, height: video?.height),
                   range: rangeRank(video?.videoRange ?? .sdr),
                   bitrate: source.bitrate ?? 0)
    }

    static func key(_ media: PlexMedia) -> Key {
        let video = (media.Part?.first?.Stream ?? []).lazy.compactMap(PlexMediaMapper.videoTrack).first
        return Key(tier: tier(label: media.videoResolution, height: media.height ?? video?.height),
                   range: rangeRank(video?.videoRange ?? .sdr),
                   bitrate: (media.bitrate ?? 0) * 1000)
    }

    /// Distinct versions, best first.
    static func ordered(_ sources: [MediaSource]) -> [MediaSource] {
        let unique = distinct(sources)
        return rankedIndices(unique.map(key)).map { unique[$0] }
    }

    static func choose(_ choice: VersionChoice, from sources: [MediaSource]) -> MediaSource? {
        let unique = distinct(sources)
        return pick(choice, ids: unique.map(\.id), keys: unique.map(key)).map { unique[$0] }
    }

    /// Moves the chosen version of a server-ordered `Media` array to the front.
    /// `serverIndex` is its original position, which Plex's transcoder calls `mediaIndex`.
    static func select(_ choice: VersionChoice, in media: [PlexMedia]) -> (media: [PlexMedia], serverIndex: Int) {
        guard let index = pick(choice, ids: media.map { "\($0.id)" }, keys: media.map(key)) else {
            return (media, 0)
        }
        var reordered = media
        reordered.insert(reordered.remove(at: index), at: 0)
        return (reordered, index)
    }

    private static func distinct(_ sources: [MediaSource]) -> [MediaSource] {
        var seen = Set<String>()
        return sources.filter { seen.insert($0.id).inserted }
    }

    /// Indices best first; equal keys keep their original order.
    private static func rankedIndices(_ keys: [Key]) -> [Int] {
        keys.indices.sorted { keys[$0] != keys[$1] ? keys[$0] > keys[$1] : $0 < $1 }
    }

    private static func pick(_ choice: VersionChoice, ids: [String], keys: [Key]) -> Int? {
        let ranked = rankedIndices(keys)
        let match: Int? = switch choice {
        case .best: nil
        case .source(let id): ranked.first { ids[$0] == id }
        case .matchingTier(let tier): ranked.first { keys[$0].tier == tier }
        }
        return match ?? ranked.first
    }
}

extension MediaItemDetail {
    /// The version Play uses. Detail badges read this so they describe that file.
    var primarySource: MediaSource? { VersionRanking.ordered(mediaSources).first }
}
```

- [ ] **Step 4: Update `Rivulet/Models/Media/MediaSource.swift`**

Replace the `fileName` line in the struct with these two lines:

```swift
    let fileName: String?          // Plex: file path. Jellyfin: the source's Name
    var versionName: String? = nil // the provider's name for this version (Jellyfin "Directors Cut"); nil on Plex
```

Replace the whole `extension MediaSource { … }` with:

```swift
extension MediaSource {
    /// Display badges for the hero quality row, e.g. ["4K", "DV", "E-AC3 5.1"].
    /// Order is stable: resolution first, then HDR/range, then audio.
    func qualityBadges() -> [String] {
        [resolutionBadge, rangeBadge, audioBadge].compactMap { $0 }
    }

    var resolutionBadge: String? { videoTracks.first.flatMap(resolutionLabel) }

    var rangeBadge: String? {
        switch videoTracks.first?.videoRange {
        case .dolbyVision: "DV"
        case .hdr10, .hdr10Plus: "HDR"
        case .hlg: "HLG"
        case .sdr, nil: nil
        }
    }

    var audioBadge: String? {
        (audioTracks.first(where: { $0.isDefault }) ?? audioTracks.first)?.qualityLabel
    }

    /// Provider label first, pixel height as the fallback (see `VersionRanking.tier`).
    /// Appends "i" for interlaced.
    private func resolutionLabel(_ video: VideoTrack) -> String? {
        func scan(_ base: String) -> String {
            video.isInterlaced ? "\(base)i" : "\(base)p"
        }
        if let raw = videoResolution, !raw.isEmpty, VersionRanking.tier(label: raw, height: nil) == 0 {
            return raw.uppercased()
        }
        switch VersionRanking.tier(label: videoResolution, height: video.height) {
        case 2160: return "4K"
        case 1080: return scan("1080")
        case 720:  return "720p"   // 720 has no interlaced broadcast form
        case 576:  return scan("576")
        case 480:  return scan("480")
        default:   return nil
        }
    }
}
```

- [ ] **Step 5: Run the new tests and the existing badge tests**

Run with `-only-testing:RivuletTests/VersionRankingTests -only-testing:RivuletTests/MediaSourceQualityBadgesTests`.
Expected: all pass. A badge failure means the refactor changed `qualityBadges()` output; fix the refactor, never the old test.

---

### Task 2: Plex player plays the chosen version

**Files:**
- Modify: `Rivulet/Views/Player/UniversalPlayerViewModel.swift` (init near line 590; `metadata` declaration near 379; `buildRivuletHLSURL` near 1601; `fetchMarkersIfNeeded` near 4579; `fetchFullMetadataIfNeeded` near 4807; preload near 5366; `preparedNextProviderPlayback` near 5409 is Task 3; swap near 5527)
- Modify: `RivuletCore/Plex/PlexNetworkManager.swift` (`buildHLSDirectPlayURL`, near 1648 and its `mediaIndex` item near 1705)
- Test: `RivuletTests/Unit/Player/PlayerVersionSelectionTests.swift` (create), `RivuletTests/Unit/Services/PlexNetworkManagerURLTests.swift`

**Interfaces:**
- Consumes: `VersionRanking.select`, `VersionRanking.key`, `VersionChoice` (Task 1)
- Produces:
  - `UniversalPlayerViewModel.init(metadata:serverURL:authToken:startOffset:shuffledQueue:loadingArtImage:loadingThumbImage:initialAudioTrackId:initialSubtitleSelection:preferredMediaID: String? = nil)`
  - `UniversalPlayerViewModel.playingMediaID: String?` and `.playingMediaServerIndex: Int` (both `private(set)`)
  - `UniversalPlayerViewModel.playingTier: Int` (private; the preload and the swap use it)
  - `PlexNetworkManager.buildHLSDirectPlayURL(serverURL:authToken:ratingKey:mediaIndex: Int = 0, offsetMs:…)`

- [ ] **Step 1: Write the failing tests**

Create `RivuletTests/Unit/Player/PlayerVersionSelectionTests.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class PlayerVersionSelectionTests: XCTestCase {

    /// Sweeney Todd with its SD file listed first, as a server might.
    private func sweeneyTodd(withMedia: Bool = true) throws -> PlexMetadata {
        let media = withMedia ? """
        ,"Media":[
         {"id":22249,"videoResolution":"sd","height":336,"bitrate":695,
          "Part":[{"id":2,"key":"/library/parts/2/b.avi","Stream":[{"id":21,"streamType":1,"codec":"mpeg4","height":336}]}]},
         {"id":260721,"videoResolution":"1080","height":1080,"bitrate":6564,
          "Part":[{"id":1,"key":"/library/parts/1/a.mkv","Stream":[{"id":11,"streamType":1,"codec":"hevc","height":1080}]}]}]
        """ : ""
        let json = #"{"ratingKey":"14675","type":"movie","title":"Sweeney Todd""# + media + "}"
        return try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
    }

    private func viewModel(_ metadata: PlexMetadata, picked: String? = nil) -> UniversalPlayerViewModel {
        UniversalPlayerViewModel(metadata: metadata, serverURL: "http://plex.local:32400", authToken: "t",
                                 preferredMediaID: picked)
    }

    func test_init_playsTheBestVersion() throws {
        let vm = viewModel(try sweeneyTodd())
        XCTAssertEqual(vm.metadata.Media?.first?.id, 260721)
        XCTAssertEqual(vm.playingMediaID, "260721")
    }

    func test_init_recordsTheServerIndexOfTheBestVersion() throws {
        // The HLS fallback sends this as mediaIndex; it must be the server's position.
        XCTAssertEqual(viewModel(try sweeneyTodd()).playingMediaServerIndex, 1)
    }

    func test_init_pickedVersionWins() throws {
        let vm = viewModel(try sweeneyTodd(), picked: "22249")
        XCTAssertEqual(vm.metadata.Media?.first?.id, 22249)
        XCTAssertEqual(vm.playingMediaServerIndex, 0)
    }

    func test_init_withoutMedia_keepsThePickedID() throws {
        let vm = viewModel(try sweeneyTodd(withMedia: false), picked: "22249")
        XCTAssertEqual(vm.playingMediaID, "22249")
    }
}
```

Append to `PlexNetworkManagerURLTests`:

```swift
    func test_buildHLSDirectPlayURL_sendsTheVersionIndex() throws {
        let result = try XCTUnwrap(networkManager.buildHLSDirectPlayURL(
            serverURL: testServerURL, authToken: testAuthToken, ratingKey: testRatingKey, mediaIndex: 1))
        let items = URLComponents(url: result.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(items.first { $0.name == "mediaIndex" }?.value, "1")
    }
```

- [ ] **Step 2: Run them and confirm they fail**

Run with `-only-testing:RivuletTests/PlayerVersionSelectionTests -only-testing:RivuletTests/PlexNetworkManagerURLTests`.
Expected: build failure on `preferredMediaID` and `mediaIndex`.

- [ ] **Step 3: `PlexNetworkManager.buildHLSDirectPlayURL` takes the index**

Add a parameter after `ratingKey: String,`:

```swift
        mediaIndex: Int = 0,
```

and change the query item:

```swift
            URLQueryItem(name: "mediaIndex", value: "\(mediaIndex)"),
```

Leave the other `mediaIndex=0` builders in this file alone; only tests call them.

- [ ] **Step 4: View model state and helpers**

Directly below `private(set) var metadata: PlexMetadata` add:

```swift
    /// Plex `Media.id` of the version playing, kept so a metadata refresh keeps it.
    private(set) var playingMediaID: String?
    /// That version's position in server order; Plex's transcoder picks by `mediaIndex`.
    private(set) var playingMediaServerIndex = 0
```

Add these members near `fetchMarkersIfNeeded`:

```swift
    /// Puts the chosen version of a server-ordered `Media` array first and records it.
    private func applyVersion(_ choice: VersionChoice, to media: [PlexMedia]?) {
        guard let media, !media.isEmpty else { return }
        let selection = VersionRanking.select(choice, in: media)
        metadata.Media = selection.media
        playingMediaID = selection.media.first.map { "\($0.id)" }
        playingMediaServerIndex = selection.serverIndex
    }

    private var currentVersionChoice: VersionChoice {
        playingMediaID.map(VersionChoice.source) ?? .best
    }

    /// Resolution tier of the version playing, for Up Next.
    private var playingTier: Int {
        if case .provider(let playback) = source { return VersionRanking.key(playback.stream.source).tier }
        return metadata.Media?.first.map { VersionRanking.key($0).tier } ?? 0
    }
```

- [ ] **Step 5: Init applies the choice before anything reads `Media`**

Add `preferredMediaID: String? = nil` as the last init parameter. Replace the first line of the init body, `self.metadata = metadata`, with:

```swift
        // The chosen version goes first, so every `Media.first` read plays it.
        var metadata = metadata
        let selection = VersionRanking.select(preferredMediaID.map(VersionChoice.source) ?? .best,
                                              in: metadata.Media ?? [])
        if !selection.media.isEmpty { metadata.Media = selection.media }
        self.playingMediaID = selection.media.first.map { "\($0.id)" } ?? preferredMediaID
        self.playingMediaServerIndex = selection.serverIndex
        self.metadata = metadata
```

The rest of the init keeps reading the local `metadata` (for example `metadata.hasDolbyVision`), which is now the reordered copy.

- [ ] **Step 6: Every server assignment of `Media` goes through `applyVersion`**

In `fetchMarkersIfNeeded`, replace `metadata.Media = media` with:

```swift
                applyVersion(currentVersionChoice, to: media)
```

In `fetchFullMetadataIfNeeded`, replace `metadata.Media = fullMetadata.Media` with:

```swift
                applyVersion(currentVersionChoice, to: fullMetadata.Media)
```

In `buildRivuletHLSURL`, add after `ratingKey: ratingKey,`:

```swift
            mediaIndex: playingMediaServerIndex,
```

- [ ] **Step 7: Up Next keeps the resolution**

In the preload function, replace:

```swift
        let metadata = preloadedNextMetadata ?? next
        if let partKey = metadata.Media?.first?.Part?.first?.key {
```

with:

```swift
        // The same choice the swap makes, so the warmed URL is the file that plays.
        let metadata = preloadedNextMetadata ?? next
        let nextMedia = VersionRanking.select(.matchingTier(playingTier), in: metadata.Media ?? []).media.first
        if let partKey = nextMedia?.Part?.first?.key {
```

`preloadedNextMetadata` stays in server order on purpose: the swap reorders it and records the server index.

In the swap, replace the `else` branch:

```swift
        } else {
            // Use preloaded metadata if available (has markers), otherwise use fetched next episode
            metadata = preloadedNextMetadata ?? next
        }
```

with:

```swift
        } else {
            // Preloaded metadata has markers. Read the outgoing tier before the swap.
            let tier = playingTier
            metadata = preloadedNextMetadata ?? next
            playingMediaID = nil
            playingMediaServerIndex = 0
            applyVersion(.matchingTier(tier), to: metadata.Media)
        }
```

- [ ] **Step 8: Run the tests**

Same command as Step 2. Expected: all pass. Then run `-only-testing:RivuletTests/ProviderPlaybackSourceTests` to confirm the provider init still builds and passes.

---

### Task 3: Provider path ranks versions and passes a choice

**Files:**
- Modify: `Rivulet/Services/MediaProvider/MediaProvider.swift` (doc on `resolveStream`)
- Modify: `Rivulet/Services/MediaProvider/Jellyfin/JellyfinProvider.swift` (`playbackInfo`, near line 342)
- Modify: `Rivulet/Services/MediaProvider/Plex/PlexProvider.swift` (`resolveStream`, near line 293)
- Modify: `Rivulet/Views/Player/ProviderPlayback+Prepare.swift`
- Modify: `Rivulet/Views/Player/UniversalPlayerViewModel.swift` (`preparedNextProviderPlayback`)
- Test: `RivuletTests/Unit/Jellyfin/JellyfinProviderTests.swift`, `RivuletTests/Unit/Player/ProviderPlaybackVersionTests.swift` (create)

**Interfaces:**
- Consumes: `VersionRanking.choose`, `VersionRanking.key`, `VersionChoice` (Task 1); `playingTier` is not used here, the provider branch computes its own tier.
- Produces:
  - `ProviderPlayback.prepare(item:provider:version: VersionChoice = .best)`
  - `ProviderPlayer.play(_:fromBeginning:sourceID: String? = nil, from:onDismiss:)`

- [ ] **Step 1: Write the failing tests**

Append to `JellyfinProviderTests` (Playback section):

```swift
    func test_resolveStream_noSourceID_picksTheBestVersion() async throws {
        server.respond("/Items/m1/PlaybackInfo", body: """
            {"PlaySessionId":"ps","MediaSources":[
              {"Id":"hd","Name":"1080p","SupportsDirectPlay":true,
               "MediaStreams":[{"Index":0,"Type":"Video","Codec":"h264","Width":1920,"Height":1080}]},
              {"Id":"uhd","Name":"2160p","SupportsDirectPlay":true,
               "MediaStreams":[{"Index":0,"Type":"Video","Codec":"hevc","Width":3840,"Height":2160}]}]}
            """)
        let stream = try await provider().resolveStream(
            for: MediaItemRef(providerID: "jellyfin:srv", itemID: "m1"), sourceID: nil)
        XCTAssertEqual(stream.source.id, "uhd")
    }
```

Create `RivuletTests/Unit/Player/ProviderPlaybackVersionTests.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class ProviderPlaybackVersionTests: XCTestCase {

    private func source(_ id: String, height: Int) -> MediaSource {
        MediaSource(
            id: id, container: "mkv", duration: 100, bitrate: nil, fileSize: nil, fileName: nil,
            videoResolution: nil,
            videoTracks: [VideoTrack(id: "v\(id)", codec: "hevc", profile: nil, level: nil, width: nil,
                                     height: height, frameRate: nil, bitrate: nil, videoRange: .sdr,
                                     isDefault: true, scanType: nil)],
            audioTracks: [], subtitleTracks: [], streamKind: .directPlay, streamURL: nil)
    }

    private func stub() -> StubMediaProvider {
        let provider = StubMediaProvider(id: "jellyfin:srv", kind: .jellyfin)
        provider.detailResult = MediaItemDetail(
            item: JellyfinFixtures.mediaItem("m1"), tagline: nil, genres: [], studios: [], cast: [],
            directors: [], writers: [], chapters: [],
            mediaSources: [source("uhd", height: 2160), source("hd", height: 1080)],
            trailerURL: nil, contentRating: nil, rating: nil, nextEpisode: nil, collections: [])
        provider.streamResult = StreamInfo(source: source("hd", height: 1080), playSessionID: nil,
                                           trackInfoAvailable: true)
        return provider
    }

    private func prepare(_ version: VersionChoice) async throws -> [String] {
        let provider = stub()
        _ = try await ProviderPlayback.prepare(item: JellyfinFixtures.mediaItem("m1"), provider: provider,
                                               version: version)
        return provider.playbackCalls
    }

    func test_best_leavesTheChoiceToTheProvider() async throws {
        let calls = try await prepare(.best)
        XCTAssertTrue(calls.contains("stream(m1,nil)"), "\(calls)")
    }

    func test_source_asksForThatVersion() async throws {
        let calls = try await prepare(.source("uhd"))
        XCTAssertTrue(calls.contains("stream(m1,uhd)"), "\(calls)")
    }

    func test_matchingTier_readsTheListThenAsksForTheMatch() async throws {
        let calls = try await prepare(.matchingTier(1080))
        XCTAssertEqual(calls.first, "detail(m1)")
        XCTAssertTrue(calls.contains("stream(m1,hd)"), "\(calls)")
    }
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run with `-only-testing:RivuletTests/JellyfinProviderTests -only-testing:RivuletTests/ProviderPlaybackVersionTests`.
Expected: build failure on `version:`. After Step 3 alone the Jellyfin test fails with `"hd"` until Step 4.

- [ ] **Step 3: `ProviderPlayback.prepare` takes a choice**

Replace `prepare(item:provider:)` with:

```swift
    /// Everything the player needs for `item`, fetched from its provider. The
    /// detail and the stream run concurrently unless a tier match needs the
    /// version list first; the extras wait for the stream.
    static func prepare(item: MediaItem, provider: any MediaProvider,
                        version: VersionChoice = .best) async throws -> ProviderPlayback {
        if case .matchingTier = version {
            let detail = try await provider.fullDetail(for: item.ref)
            let sourceID = VersionRanking.choose(version, from: detail.mediaSources)?.id
            let stream = try await provider.resolveStream(for: item.ref, sourceID: sourceID)
            let extras = await provider.playbackExtras(for: item.ref, sourceID: stream.source.id)
            return ProviderPlayback(provider: provider, item: item, detail: detail, stream: stream, extras: extras)
        }
        let sourceID: String?
        if case .source(let id) = version { sourceID = id } else { sourceID = nil }
        async let detail = provider.fullDetail(for: item.ref)
        let stream = try await provider.resolveStream(for: item.ref, sourceID: sourceID)
        async let extras = provider.playbackExtras(for: item.ref, sourceID: stream.source.id)
        return try await ProviderPlayback(provider: provider, item: item, detail: detail,
                                          stream: stream, extras: extras)
    }
```

In `ProviderPlayer.play`, add `sourceID: String? = nil,` after `fromBeginning: Bool,` and change the prepare call to:

```swift
                let playback = try await ProviderPlayback.prepare(
                    item: target, provider: provider, version: sourceID.map(VersionChoice.source) ?? .best)
```

- [ ] **Step 4: Providers rank when no version is named**

In `MediaProvider.swift`, put this doc line directly above `func resolveStream`:

```swift
    /// A nil `sourceID` plays the best version by `VersionRanking`.
```

In `JellyfinProvider.playbackInfo`, replace:

```swift
        let sources = response.mediaSources ?? []
        guard let chosen = sources.first(where: { $0.id == sourceID }) ?? sources.first else {
            throw MediaProviderError.notFound
        }
```

with:

```swift
        let sources = response.mediaSources ?? []
        let ranked = sources.map {
            JellyfinMediaMapper.mediaSource($0, itemID: itemRef.itemID, playSessionID: response.playSessionId,
                                            baseURL: baseURL, token: token)
        }
        let pickedID = VersionRanking.choose(sourceID.map(VersionChoice.source) ?? .best, from: ranked)?.id
        guard let chosen = sources.first(where: { ($0.id ?? itemRef.itemID) == pickedID }) else {
            throw MediaProviderError.notFound
        }
```

In `PlexProvider.resolveStream`, replace the `if let sourceID … else if let first … else throw` block with:

```swift
        guard let chosen = VersionRanking.choose(sourceID.map(VersionChoice.source) ?? .best,
                                                 from: detail.mediaSources) else {
            throw MediaProviderError.notFound
        }
```

(and delete the now-unused `let chosen: MediaSource` declaration above it).

- [ ] **Step 5: Provider Up Next keeps the resolution**

In `UniversalPlayerViewModel.preparedNextProviderPlayback`, change the branch that builds the task:

```swift
        } else if let item = providerEpisodeItems[key] {
            let provider = playback.provider
            let tier = VersionRanking.key(playback.stream.source).tier
            task = Task {
                do {
                    return try await ProviderPlayback.prepare(item: item, provider: provider,
                                                              version: .matchingTier(tier))
```

- [ ] **Step 6: Run the tests**

Same command as Step 2, plus `-only-testing:RivuletTests/ProviderPlaybackSourceTests`. Expected: all pass, including the existing `test_resolveStream_firstSource_withSessionID` (its 4K source still ranks first).

---

### Task 4: VersionPicker and version names

**Files:**
- Create: `Rivulet/Views/Media/UIKit/VersionPicker.swift`
- Modify: `Rivulet/Services/MediaProvider/Jellyfin/JellyfinMediaMapper.swift` (`mediaSource(…)`, set `versionName`)
- Modify: detail badge readers to use `primarySource`: `MediaDetailChromeView.swift:995`, `MediaItemDetailPageViewController.swift:577`, `InfoPopupViewController.swift:350` and `:417`, `Cells/AboutInfoCells.swift:294`
- Test: `RivuletTests/Unit/VersionPickerTests.swift` (create)

**Interfaces:**
- Consumes: `VersionRanking.ordered`, `MediaSource.resolutionBadge/.rangeBadge/.audioBadge/.versionName`, `MediaItemDetail.primarySource` (Task 1); `TileMenuPopupViewController`, `TileMenuAction`, `TileMenuHeader`, `UIViewController.topmostPresented`, `PlayerInfoSheetStyle.fileSize` (existing)
- Produces:
  - `VersionPicker.versions(in: MediaItemDetail) -> [MediaSource]` (best first; empty when fewer than two)
  - `VersionPicker.labels(for: [MediaSource]) -> [String]`
  - `VersionPicker.present(_ versions: [MediaSource], from: UIViewController, sourceFrame: CGRect?, onPick: @escaping (String) -> Void)`

- [ ] **Step 1: Write the failing tests**

Create `RivuletTests/Unit/VersionPickerTests.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class VersionPickerTests: XCTestCase {

    private func source(_ id: String, res: String = "1080", height: Int = 1080, codec: String = "hevc",
                        range: VideoTrack.VideoRange = .sdr, size: Int64? = 5_730_000_000,
                        file: String? = nil, name: String? = nil) -> MediaSource {
        let video = VideoTrack(id: "v\(id)", codec: codec, profile: nil, level: nil, width: nil, height: height,
                               frameRate: nil, bitrate: nil, videoRange: range, isDefault: true, scanType: nil)
        let audio = AudioTrack(id: "a\(id)", index: 0, codec: "aac", profile: nil, channels: 6,
                               channelLayout: "5.1", language: "en", title: nil, extendedTitle: nil,
                               bitrate: nil, samplingRate: nil, isDefault: true, isForced: false, isSelected: true)
        return MediaSource(id: id, container: "mkv", duration: 100, bitrate: nil, fileSize: size,
                           fileName: file, versionName: name, videoResolution: res,
                           videoTracks: [video], audioTracks: [audio], subtitleTracks: [],
                           streamKind: .directPlay, streamURL: nil)
    }

    private func detail(_ sources: [MediaSource]) -> MediaItemDetail {
        MediaItemDetail(item: JellyfinFixtures.mediaItem("m1"), tagline: nil, genres: [], studios: [], cast: [],
                        directors: [], writers: [], chapters: [], mediaSources: sources, trailerURL: nil,
                        contentRating: nil, rating: nil, nextEpisode: nil, collections: [])
    }

    func test_label_isResolutionRangeCodecAudioSize() {
        let label = VersionPicker.labels(for: [source("a", res: "4k", height: 2160,
                                                      range: .dolbyVision(profile: 8))])[0]
        XCTAssertTrue(label.hasPrefix("4K · DV · HEVC · AAC 5.1 · "), label)
        XCTAssertTrue(label.hasSuffix("GB"), label)
    }

    func test_label_leadsWithAVersionName() {
        XCTAssertTrue(VersionPicker.labels(for: [source("a", name: "Directors Cut")])[0]
            .hasPrefix("Directors Cut · 1080p"))
    }

    func test_label_skipsResolutionNames() {
        XCTAssertTrue(VersionPicker.labels(for: [source("a", name: "1080P")])[0].hasPrefix("1080p · HEVC"))
        XCTAssertTrue(VersionPicker.labels(for: [source("a", name: "4K")])[0].hasPrefix("1080p · HEVC"))
    }

    func test_labels_collision_appendsTheFileName() {
        let labels = VersionPicker.labels(for: [source("a", file: "/m/Heat (Bluray).mkv"),
                                                source("b", file: "/m/Heat (WEB).mkv")])
        XCTAssertTrue(labels[0].hasSuffix(" · Heat (Bluray)"), labels[0])
        XCTAssertTrue(labels[1].hasSuffix(" · Heat (WEB)"), labels[1])
    }

    func test_codecName() {
        XCTAssertEqual(VersionPicker.codecName("h264"), "H.264")
        XCTAssertEqual(VersionPicker.codecName("mpeg2video"), "MPEG-2")
        XCTAssertEqual(VersionPicker.codecName("prores"), "PRORES")
        XCTAssertNil(VersionPicker.codecName("unknown"))
    }

    func test_versions_bestFirst_andEmptyForOne() {
        XCTAssertEqual(VersionPicker.versions(in: detail([source("hd"), source("uhd", res: "4k", height: 2160)]))
            .map(\.id), ["uhd", "hd"])
        XCTAssertTrue(VersionPicker.versions(in: detail([source("only")])).isEmpty)
    }

    func test_versions_stackedFileIsOneVersion() {
        // One Plex Media with two Parts maps to two MediaSources sharing an id.
        XCTAssertTrue(VersionPicker.versions(in: detail([source("m"), source("m")])).isEmpty)
    }
}
```

- [ ] **Step 2: Run them and confirm they fail**

Run with `-only-testing:RivuletTests/VersionPickerTests`. Expected: build failure, "cannot find 'VersionPicker' in scope".

- [ ] **Step 3: Create `Rivulet/Views/Media/UIKit/VersionPicker.swift`**

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  VersionPicker.swift
//  Rivulet
//
//  The "Play Version" list for an item with more than one file. Built on the
//  tile menu popup; the pick plays once and is not remembered.
//

import UIKit

enum VersionPicker {
    /// The item's versions, best first, or empty when it has only one.
    static func versions(in detail: MediaItemDetail) -> [MediaSource] {
        let ranked = VersionRanking.ordered(detail.mediaSources)
        return ranked.count >= 2 ? ranked : []
    }

    /// One row label per version, same order. Identical labels get the file name.
    static func labels(for sources: [MediaSource]) -> [String] {
        let base = sources.map(rowLabel)
        return zip(sources, base).map { source, label in
            guard base.filter({ $0 == label }).count > 1, let stem = fileStem(source.fileName) else { return label }
            return "\(label) · \(stem)"
        }
    }

    static func present(_ versions: [MediaSource], from host: UIViewController,
                        sourceFrame: CGRect?, onPick: @escaping (String) -> Void) {
        guard versions.count >= 2 else { return }
        let rows = zip(versions, labels(for: versions)).map { source, label in
            TileMenuAction(title: label, systemImage: "play.fill") { onPick(source.id) }
        }
        let popup = TileMenuPopupViewController(sections: [rows], sourceFrame: sourceFrame,
                                                header: TileMenuHeader(title: "Play Version"))
        // The popup runs its own entrance from `sourceFrame`.
        host.topmostPresented.present(popup, animated: false)
    }

    /// Jellyfin treats a name ending in p or i after digits as a resolution; "4K" too.
    static func isResolutionName(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard let last = lower.last, "pik".contains(last) else { return false }
        let digits = lower.dropLast()
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    static func codecName(_ codec: String) -> String? {
        switch codec.lowercased() {
        case "hevc", "h265": "HEVC"
        case "h264", "avc": "H.264"
        case "av1": "AV1"
        case "vp9": "VP9"
        case "mpeg2video": "MPEG-2"
        case "mpeg4": "MPEG-4"
        case "vc1": "VC-1"
        case "", "unknown": nil
        default: codec.uppercased()
        }
    }

    private static func rowLabel(_ source: MediaSource) -> String {
        let name = source.versionName.flatMap { isResolutionName($0) ? nil : $0 }
        return [name, source.resolutionBadge, source.rangeBadge,
                source.videoTracks.first.flatMap { codecName($0.codec) },
                source.audioBadge, source.fileSize.map(PlayerInfoSheetStyle.fileSize)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private static func fileStem(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }
}
```

- [ ] **Step 4: Jellyfin sources carry their name**

In `JellyfinMediaMapper.mediaSource(…)`, in the `MediaSource(` call, add after `fileName: src.name,`:

```swift
            versionName: src.name,
```

- [ ] **Step 5: Detail badges describe the file Play uses**

In each of the five readers listed under Files, replace `detail.mediaSources.first` (or `detail?.mediaSources.first`) with `detail.primarySource` (or `detail?.primarySource`).

- [ ] **Step 6: Run the tests**

Run with `-only-testing:RivuletTests/VersionPickerTests -only-testing:RivuletTests/JellyfinMediaMapperTests`. Expected: all pass. If `test_label_isResolutionRangeCodecAudioSize` fails on the audio part, read `AudioTrack.qualityLabel` and correct the expected text in the test, since that label is existing behavior.

---

### Task 5: Versions button on the detail pages, and the pick reaches the player

**Files:**
- Modify: `Rivulet/Views/Media/MediaDetail/UIKit/MediaDetailChromeView.swift` (callbacks near 108, `rebuildActionButtons` near 689, `applyDetail` near 660)
- Modify: `Rivulet/Views/Media/PreviewCarousel/UIKit/PreviewCardView.swift` (callbacks near 331, `applyItem` near 351)
- Modify: `Rivulet/Views/Media/PreviewCarousel/UIKit/PreviewCarouselViewController.swift` (episode page creators near 351 and 374, `playMediaItem` near 1124, `presentPlayer(ratingKey:resumeOffset:)` near 1142, `present(playItem:…)` near 1253, `cell.onPlay` near 1832)
- Modify: `Rivulet/Views/Media/MediaDetail/UIKit/MediaItemDetailPageViewController.swift` (`onPlay` type, `pressesBegan` near 185, `makeActionRow` near 350, `applyDetail` near 567)
- Modify: `Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift` (play chain near 5059 to 5180, `playResolvingEpisode` near 4038, `selectMediaItem` near 5222)
- Modify: `Rivulet/Views/TVNavigation/TVSidebarView.swift` (deep-link episode page near 652, `playDeepLinkItem` near 677, `presentPlayerForDeepLink` near 698)

**Interfaces:**
- Consumes: `VersionPicker.versions/present` (Task 4); `UniversalPlayerViewModel(…, preferredMediaID:)` (Task 2); `ProviderPlayer.play(_:fromBeginning:sourceID:from:onDismiss:)` (Task 3)
- Produces:
  - `MediaDetailChromeView.onPlayVersion: ((String) -> Void)?`
  - `PreviewCardView.onPlayVersion: ((MediaItem, String) -> Void)?`
  - `MediaItemDetailPageViewController.init(item:seriesTitle:onPlay: @escaping (MediaItem, String?) -> Void)`
  - `PlexHomeViewController.playItem(_:fromBeginning:sourceID: String? = nil)` (Task 6 calls it)

This task has no unit test of its own: the logic it calls is tested in Tasks 1 to 4, and the rest is wiring checked by the build and on device (Task 8).

- [ ] **Step 1: Chrome view (carousel and standalone detail)**

Next to `var onPlay: (() -> Void)?` add:

```swift
    var onPlayVersion: ((String) -> Void)?
```

Next to the other private button references add:

```swift
    private weak var infoButton: FocusableActionButton?
    private weak var versionsButton: FocusableActionButton?
```

In `rebuildActionButtons`, after `let info = makeCircleButton(systemImage: "text.page")` add `infoButton = info`.

At the end of `applyDetail(item:detail:)` add `addVersionsButton(detail)`, and add:

```swift
    /// Versions button after Info, once the detail shows two or more files.
    private func addVersionsButton(_ detail: MediaItemDetail) {
        let versions = VersionPicker.versions(in: detail)
        guard !versions.isEmpty, versionsButton == nil, let info = infoButton,
              let index = actionButtonsStack.arrangedSubviews.firstIndex(of: info) else { return }
        let button = makeCircleButton(systemImage: "square.stack")
        button.onPrimaryAction = { [weak self, weak button] in
            guard let self, let button, let host = self.hostViewController else { return }
            VersionPicker.present(versions, from: host, sourceFrame: button.convert(button.bounds, to: nil)) {
                [weak self] id in self?.onPlayVersion?(id)
            }
        }
        actionButtonsStack.insertArrangedSubview(button, at: index + 1)
        versionsButton = button
    }
```

- [ ] **Step 2: Card and carousel**

In `PreviewCardView`, next to `var onPlay` add:

```swift
    /// Versions → play `item` from the picked file. Set by the VC in cellForItemAt.
    var onPlayVersion: ((MediaItem, String) -> Void)?
```

and in `applyItem`, after the `chromeView.onPlay = …` block:

```swift
        chromeView.onPlayVersion = { [weak self] sourceID in
            guard let self, let item = self.chromeView.item else { return }
            self.onPlayVersion?(item, sourceID)
        }
```

In `PreviewCarouselViewController`:

```swift
        cell.onPlay = { [weak self] item in self?.playHeroItem(item) }
        cell.onPlayVersion = { [weak self] item, sourceID in self?.playMediaItem(item, sourceID: sourceID) }
```

Replace `playMediaItem` with:

```swift
    private func playMediaItem(_ item: MediaItem, sourceID: String? = nil) {
        // presentPlayer resolves a Plex ratingKey; any other item plays through
        // its own provider.
        if !item.ref.isPlex {
            ProviderPlayer.play(item, fromBeginning: false, sourceID: sourceID, from: self, onDismiss: nil)
            return
        }
        let offsetSec = item.userState.viewOffset
        presentPlayer(ratingKey: item.ref.itemID, resumeOffset: offsetSec > 0 ? offsetSec : nil, mediaID: sourceID)
    }
```

Add `mediaID: String? = nil` to `presentPlayer(ratingKey:resumeOffset:)` and pass it on: `self?.present(playItem: playItem, serverURL: serverURL, token: token, resumeOffset: resumeOffset ?? serverResume, mediaID: mediaID)`. Add `mediaID: String? = nil` to `present(playItem:serverURL:token:resumeOffset:)` and pass `preferredMediaID: mediaID` to the `UniversalPlayerViewModel` init.

Episode page creators in the carousel:

```swift
                onPlay: { [weak self] ep, sourceID in self?.playMediaItem(ep, sourceID: sourceID) })
```

```swift
                onPlay: { [weak self] season, _ in self?.playHeroItem(season) })
```

- [ ] **Step 3: Episode page**

Change the stored closure and init parameter to `(MediaItem, String?) -> Void`. The Play pill calls `self.onPlay(self.item, nil)`.

Open `pressesBegan` with the presenter guard (a press the picker declines would otherwise scroll this page):

```swift
        guard presentedViewController == nil else { super.pressesBegan(presses, with: event); return }
```

Add `private weak var actionRow: UIStackView?` and `private weak var versionsButton: FocusableActionButton?`. In `makeActionRow`, after `let row = UIStackView(arrangedSubviews: [pill, watched, watchlist])` add `actionRow = row`.

At the end of `applyDetail(_:fallbackGenres:)` add `addVersionsButton(detail)`, and add:

```swift
    /// Versions button after Watchlist, once the detail shows two or more files.
    private func addVersionsButton(_ detail: MediaItemDetail) {
        let versions = VersionPicker.versions(in: detail)
        guard !versions.isEmpty, versionsButton == nil, let row = actionRow, let watchlist = watchlistButton,
              let index = row.arrangedSubviews.firstIndex(of: watchlist) else { return }
        let button = circleButton(systemImage: "square.stack")
        button.onPrimaryAction = { [weak self, weak button] in
            guard let self, let button else { return }
            VersionPicker.present(versions, from: self, sourceFrame: button.convert(button.bounds, to: nil)) {
                [weak self] id in
                guard let self else { return }
                self.onPlay(self.item, id)
            }
        }
        row.insertArrangedSubview(button, at: index + 1)
        versionsButton = button
    }
```

- [ ] **Step 4: Home play chain carries the id**

In `PlexHomeViewController`, add a defaulted parameter to each function and pass it to the next call. Every existing caller keeps compiling because each default is nil.

| Function | New parameter | Passes it to |
|---|---|---|
| `playItem(_:fromBeginning:)` | `sourceID: String? = nil` | both `presentResumeChoice(forMediaItem:…)` calls, `resolveAndPlay`, `playItemDirectly(meta, fromBeginning:, mediaID: sourceID)` |
| `presentResumeChoice(forMediaItem:offsetSec:)` | `sourceID: String? = nil` | both `resolveAndPlay` calls |
| `resolveAndPlay(_:fromBeginning:)` | `sourceID: String? = nil` | `ProviderPlayer.play(…, sourceID: sourceID, …)`, `presentPlayer(for:fromBeginning:mediaID: sourceID)` |
| `playItemDirectly(_:fromBeginning:)` | `mediaID: String? = nil` | `presentResumeChoice(for:offsetMs:mediaID:)`, `presentPlayer(…, mediaID:)` |
| `presentResumeChoice(for:offsetMs:)` | `mediaID: String? = nil` | both `presentPlayer` calls |
| `presentPlayer(for:fromBeginning:)` | `mediaID: String? = nil` | `UniversalPlayerViewModel(…, preferredMediaID: mediaID)` |
| `playResolvingEpisode(_:)` | `sourceID: String? = nil` | the non-show branch: `playItem(item, sourceID: sourceID)` |

The episode page creator in `selectMediaItem`:

```swift
                onPlay: { [weak self] target, sourceID in self?.playResolvingEpisode(target, sourceID: sourceID) })
```

- [ ] **Step 5: Deep-link episode page**

In `TVSidebarView`:

```swift
                onPlay: { episode, sourceID in
                    // Close the page first so the player isn't presented
                    // underneath it, then resolve full metadata to play.
                    top.dismiss(animated: true) {
                        playDeepLinkItem(episode, sourceID: sourceID)
                    }
                })
```

`playDeepLinkItem(_:sourceID: String? = nil)` passes `sourceID` to `ProviderPlayer.play(…, sourceID: sourceID, …)` and to `presentPlayerForDeepLink(meta, mediaID: sourceID)`. `presentPlayerForDeepLink(_:mediaID: String? = nil)` passes `preferredMediaID: mediaID` to the view model.

- [ ] **Step 6: Build**

Run the app build command. Expected: BUILD SUCCEEDED. Then run the whole unit suite once (`xcodebuild test` without `-only-testing`) and compare failures against `main` before this work; `sourceBadge` tests fail on Plex-signed-in simulators and are not regressions.

---

### Task 6: "Play Version…" in the tile menu

**Files:**
- Modify: `Rivulet/Models/Media/MediaItem.swift` (field, init, `withLogoIfMissing`)
- Modify: `Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift` (watchlist stub copy near 5506, `tileMenuSections` near 6341, `providerTileMenuSections` near 6468)
- Modify: `Rivulet/Services/MediaProvider/Plex/PlexMediaMapper.swift` (`item`)
- Modify: `Rivulet/Services/MediaProvider/Jellyfin/JellyfinModels.swift` (`JFItem`), `JellyfinMediaMapper.swift` (`item`), `JellyfinProvider.swift` (list `fields`, near 45 and 199)
- Test: `RivuletTests/Unit/PlexMediaMapperTests.swift`, `RivuletTests/Unit/Jellyfin/JellyfinMediaMapperTests.swift`, `RivuletTests/Unit/Jellyfin/JellyfinBrowseSurfaceTests.swift`, `RivuletTests/Unit/MediaItemCodableTests.swift` (create)

**Interfaces:**
- Consumes: `VersionPicker.versions/present` (Task 4); `playItem(_:fromBeginning:sourceID:)` (Task 5)
- Produces:
  - `MediaItem.versionCount: Int?` (init parameter `versionCount: Int? = nil`)
  - `PlexHomeViewController.providerTileMenuSections(…, onPlayVersion: (() -> Void)? = nil)`

- [ ] **Step 1: Confirm Jellyfin returns the count**

Jellyfin documents `MediaSourceCount` on `BaseItemDto` and in the `ItemFields` enum. Confirm on the jellyfin-test server (address and login in the maintainer's notes) before writing the Jellyfin part:

```bash
curl -s "$JF/Items?Recursive=true&IncludeItemTypes=Movie&Limit=2&Fields=MediaSourceCount" \
  -H "Authorization: MediaBrowser Token=$JF_TOKEN" | python3 -c "import sys,json;[print(i['Name'],i.get('MediaSourceCount')) for i in json.load(sys.stdin)['Items']]"
```

Expected: a number per movie. If the field is missing, skip every Jellyfin line in this task and its Jellyfin test; Jellyfin tiles then show no row and the detail page still works.

- [ ] **Step 2: Write the failing tests**

Create `RivuletTests/Unit/MediaItemCodableTests.swift`:

```swift
// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class MediaItemCodableTests: XCTestCase {
    func test_decodesJSONWrittenBeforeTheVersionFields() throws {
        let item = JellyfinFixtures.mediaItem("m1")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(item)) as? [String: Any])
        json.removeValue(forKey: "versionCount")
        json.removeValue(forKey: "editionTitle")
        let decoded = try JSONDecoder().decode(MediaItem.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, item)
    }
}
```

Append to `PlexMediaMapperTests`:

```swift
    func test_item_countsDistinctVersions() throws {
        let json = #"{"ratingKey":"7","type":"movie","title":"Heat","Media":[{"id":1},{"id":2}]}"#
        let meta = try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
        let item = PlexMediaMapper.item(meta, providerID: "plex:abc", serverURL: "http://s", authToken: "t")
        XCTAssertEqual(item.versionCount, 2)
    }
```

Append to `JellyfinMediaMapperTests`:

```swift
    func test_item_versionCount_fromMediaSourceCount() {
        XCTAssertEqual(item(#"{"Id":"m1","Name":"Heat","Type":"Movie","MediaSourceCount":2}"#).versionCount, 2)
    }
```

In `JellyfinBrowseSurfaceTests`, make the `menu` helper pass `onPlayVersion: {}` as its last argument, then append:

```swift
    func test_providerTileMenu_playVersion_onlyWithTwoVersions() {
        func titles(_ json: String) -> [String] {
            let item = JellyfinMediaMapper.item(JellyfinFixtures.decode(json), providerID: "jellyfin:srv",
                                                baseURL: JellyfinFixtures.baseURL)
            return menu(item).flatMap { $0 }.map(\.title)
        }
        XCTAssertTrue(titles(#"{"Id":"m1","Name":"Heat","Type":"Movie","MediaSourceCount":2}"#)
            .contains("Play Version…"))
        XCTAssertFalse(titles(#"{"Id":"m1","Name":"Heat","Type":"Movie","MediaSourceCount":1}"#)
            .contains("Play Version…"))
    }
```

- [ ] **Step 3: Run them and confirm they fail**

Run with `-only-testing:RivuletTests/MediaItemCodableTests -only-testing:RivuletTests/PlexMediaMapperTests -only-testing:RivuletTests/JellyfinMediaMapperTests -only-testing:RivuletTests/JellyfinBrowseSurfaceTests`.
Expected: build failure on `versionCount` and `onPlayVersion`.

- [ ] **Step 4: `MediaItem.versionCount`**

Add below `let grandparentArtwork: MediaArtwork?`:

```swift
    /// Distinct files behind a movie or episode; nil when the list didn't say.
    let versionCount: Int?
```

Add `versionCount: Int? = nil` as the last init parameter and `self.versionCount = versionCount` in the body. In `withLogoIfMissing`, pass `versionCount: versionCount`. In `PlexHomeViewController`'s watchlist `stub = MediaItem(…)` copy, pass `versionCount: base.versionCount`.

`MediaItem` keeps synthesized `Codable`; an optional `let` decodes as nil when the key is missing, which the new test pins.

- [ ] **Step 5: Mappers**

`PlexMediaMapper.item`, in the `MediaItem(` call:

```swift
            grandparentArtwork: grandparentArtwork,
            versionCount: meta.Media.map { Set($0.map(\.id)).count }
```

`JFItem`: add `let mediaSourceCount: Int?`. `JellyfinMediaMapper.item`: pass `versionCount: dto.mediaSourceCount`. `JellyfinProvider`: append `,MediaSourceCount` to the `fields` value in `listFields` and in `latestItems`.

- [ ] **Step 6: Menu rows**

Add to `PlexHomeViewController`:

```swift
    /// "Play Version…" for a movie or episode with more than one file.
    static func playVersionAction(for item: MediaItem, handler: (() -> Void)?) -> TileMenuAction? {
        guard let handler, (item.versionCount ?? 0) >= 2, item.kind == .movie || item.kind == .episode else {
            return nil
        }
        return TileMenuAction(title: "Play Version…", systemImage: "square.stack", handler: handler)
    }

    /// Tile menu "Play Version…": fetch the versions, then play the pick.
    private func presentVersionPicker(for item: MediaItem, from tileFrame: CGRect?) {
        guard let provider = MediaProviderRegistry.shared.provider(for: item.ref.providerID) else { return }
        Task { @MainActor [weak self] in
            guard let self, let detail = try? await provider.fullDetail(for: item.ref) else { return }
            VersionPicker.present(VersionPicker.versions(in: detail), from: self, sourceFrame: tileFrame) {
                [weak self] sourceID in self?.playItem(item, sourceID: sourceID)
            }
        }
    }
```

In `tileMenuSections(for:isContinueWatching:shelfLocation:)`, after the collection early return add:

```swift
        // Read now: the frame is gone once the menu covers the tile.
        let tileFrame = focusedTileFrame()
```

Pass `onPlayVersion: { [weak self] in self?.presentVersionPicker(for: item, from: tileFrame) }` as the last argument of the `providerTileMenuSections` call. Insert the row right after "Watch from Beginning" in both Plex groups. After `cwFirst += goToEntries(for: item)`:

```swift
            if let version = Self.playVersionAction(for: item, handler: { [weak self] in
                self?.presentVersionPicker(for: item, from: tileFrame)
            }) {
                cwFirst.insert(version, at: 1)
            }
```

And after the generic `var first = [ … ]` array:

```swift
        if let version = Self.playVersionAction(for: item, handler: { [weak self] in
            self?.presentVersionPicker(for: item, from: tileFrame)
        }) {
            first.insert(version, at: 1)
        }
```

In `providerTileMenuSections`, add the parameter `onPlayVersion: (() -> Void)? = nil` and, after `var first = [...]`:

```swift
        if let version = playVersionAction(for: item, handler: onPlayVersion) { first.insert(version, at: 1) }
```

- [ ] **Step 7: Run the tests**

Same command as Step 3. Expected: all pass, including the existing `test_providerTileMenu_matchesThePlexMenu`.

- [ ] **Step 8: Verify the version-selection goal and commit it**

```bash
xcodebuild test -scheme Rivulet -destination "$DEST" -derivedDataPath "$DD" 2>&1 | grep -E "error:|failed|TEST (SUCCEEDED|FAILED)" | tail -40
xcodebuild build -scheme "Rivulet iOS" -configuration Debug -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DD-ios" 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)" | tail -10
swiftlint lint --strict
```

Expected: tests pass apart from known environment failures (`sourceBadge` on signed-in simulators), the iOS build succeeds (RivuletCore changed), lint is clean. Read the whole diff, then commit only these paths (`git commit -- <paths>` commits their working-tree state, so nothing else rides along):

```bash
NEW="Rivulet/Models/Media/VersionRanking.swift Rivulet/Views/Media/UIKit/VersionPicker.swift \
  RivuletTests/Unit/VersionRankingTests.swift RivuletTests/Unit/VersionPickerTests.swift \
  RivuletTests/Unit/Player/PlayerVersionSelectionTests.swift RivuletTests/Unit/Player/ProviderPlaybackVersionTests.swift \
  RivuletTests/Unit/MediaItemCodableTests.swift"
git add $NEW
git commit -m "Play the best version of multi-file items, with a version picker" -- $NEW \
  Rivulet/Models/Media/MediaSource.swift Rivulet/Models/Media/MediaItem.swift \
  Rivulet/Views/Player/UniversalPlayerViewModel.swift Rivulet/Views/Player/ProviderPlayback+Prepare.swift \
  RivuletCore/Plex/PlexNetworkManager.swift \
  Rivulet/Services/MediaProvider/MediaProvider.swift \
  Rivulet/Services/MediaProvider/Plex/PlexProvider.swift Rivulet/Services/MediaProvider/Plex/PlexMediaMapper.swift \
  Rivulet/Services/MediaProvider/Jellyfin/JellyfinProvider.swift Rivulet/Services/MediaProvider/Jellyfin/JellyfinMediaMapper.swift \
  Rivulet/Services/MediaProvider/Jellyfin/JellyfinModels.swift \
  Rivulet/Views/Media/MediaDetail/UIKit/MediaDetailChromeView.swift \
  Rivulet/Views/Media/MediaDetail/UIKit/MediaItemDetailPageViewController.swift \
  Rivulet/Views/Media/MediaDetail/UIKit/InfoPopupViewController.swift \
  Rivulet/Views/Media/MediaDetail/UIKit/Cells/AboutInfoCells.swift \
  Rivulet/Views/Media/PreviewCarousel/UIKit/PreviewCardView.swift \
  Rivulet/Views/Media/PreviewCarousel/UIKit/PreviewCarouselViewController.swift \
  Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift \
  Rivulet/Views/TVNavigation/TVSidebarView.swift \
  RivuletTests/Unit/Services/PlexNetworkManagerURLTests.swift RivuletTests/Unit/PlexMediaMapperTests.swift \
  RivuletTests/Unit/Jellyfin/JellyfinProviderTests.swift RivuletTests/Unit/Jellyfin/JellyfinMediaMapperTests.swift \
  RivuletTests/Unit/Jellyfin/JellyfinBrowseSurfaceTests.swift
git show --stat HEAD
```

If `git show --stat` lists a file this plan never touched, or misses one it did, stop and fix the commit before going on.

---

### Task 7: Show Plex edition names

**Files:**
- Modify: `RivuletCore/Models/Plex/PlexMetadata.swift` (Display Info block near 288)
- Modify: `Rivulet/Models/Media/MediaItem.swift`, `Rivulet/Services/MediaProvider/Plex/PlexMediaMapper.swift`, `PlexHomeViewController.swift` (stub copy)
- Modify: `MediaDetailChromeView.rebuildQualityRow` (near 955), `MediaItemDetailPageViewController.dateRuntimeText` (near 531)
- Test: `RivuletTests/Unit/PlexMediaMapperTests.swift`

**Interfaces:**
- Produces: `PlexMetadata.editionTitle: String?`, `MediaItem.editionTitle: String?` (init parameter `editionTitle: String? = nil`)

- [ ] **Step 1: Write the failing test**

Append to `PlexMediaMapperTests`:

```swift
    func test_item_mapsEditionTitle() throws {
        let json = #"{"ratingKey":"7","type":"movie","title":"Blade Runner","editionTitle":"Final Cut"}"#
        let meta = try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
        let item = PlexMediaMapper.item(meta, providerID: "plex:abc", serverURL: "http://s", authToken: "t")
        XCTAssertEqual(item.editionTitle, "Final Cut")
    }
```

- [ ] **Step 2: Run it and confirm it fails**

Run with `-only-testing:RivuletTests/PlexMediaMapperTests`. Expected: build failure on `editionTitle`.

- [ ] **Step 3: Decode and map**

`PlexMetadata`, under `var originalTitle: String?`:

```swift
    var editionTitle: String?     // Plex movie edition, e.g. "Director's Cut"
```

`MediaItem`: add `let editionTitle: String?` below `versionCount`, an init parameter `editionTitle: String? = nil` after `versionCount`, the assignment, and pass-throughs in `withLogoIfMissing` (`editionTitle: editionTitle`) and the PlexHome stub (`editionTitle: base.editionTitle`).

`PlexMediaMapper.item`: pass `editionTitle: meta.editionTitle` after `versionCount:`.

- [ ] **Step 4: Show it**

`MediaDetailChromeView.rebuildQualityRow`, after the runtime line:

```swift
        if let edition = detail?.item.editionTitle ?? item.editionTitle, !edition.isEmpty { parts.append(edition) }
```

`MediaItemDetailPageViewController.dateRuntimeText`, after the runtime line:

```swift
        if let edition = item.editionTitle, !edition.isEmpty { parts.append(edition) }
```

- [ ] **Step 5: Run the tests and build**

Run with `-only-testing:RivuletTests/PlexMediaMapperTests -only-testing:RivuletTests/MediaItemCodableTests`, then the app build command. Expected: pass and BUILD SUCCEEDED. RivuletCore changed again, so repeat the iOS build from Task 6 Step 8.

- [ ] **Step 6: Commit**

```bash
git commit -m "Detail: show Plex edition names" -- \
  RivuletCore/Models/Plex/PlexMetadata.swift Rivulet/Models/Media/MediaItem.swift \
  Rivulet/Services/MediaProvider/Plex/PlexMediaMapper.swift \
  Rivulet/Views/Media/PlexHome/UIKit/PlexHomeViewController.swift \
  Rivulet/Views/Media/MediaDetail/UIKit/MediaDetailChromeView.swift \
  Rivulet/Views/Media/MediaDetail/UIKit/MediaItemDetailPageViewController.swift \
  RivuletTests/Unit/PlexMediaMapperTests.swift
git show --stat HEAD
```

---

### Task 8: Changelog and device checks

**Files:**
- Modify: `Rivulet/Views/Components/WhatsNewView.swift` (through the skill)

- [ ] **Step 1: Changelog**

Invoke the `rivulet-changelog` skill. User-facing bullets, two lines or less each, no dashes:
- "Movies and episodes with more than one file play the best one. Pick another from Versions on the detail page or Play Version in the long-press menu."
- "Detail pages show a movie's edition name, such as Director's Cut."

- [ ] **Step 2: Build and commit the changelog**

Run the app build command (Debug). Then:

```bash
git commit -m "docs: changelog for version selection and edition names" -- Rivulet/Views/Components/WhatsNewView.swift
```

- [ ] **Step 3: Device checks (Apple TV, not the Simulator)**

1. Sweeney Todd: Play plays the 1080p file (player info FILE section).
2. Sweeney Todd: Versions lists 1080p first; the SD row plays the SD file. Back out and press Play: 1080p again.
3. Sweeney Todd with SD picked, Aether startup forced to fail: the HLS fallback transcodes the SD file.
4. An Office episode with two files: pick the 720p one and let Up Next advance; the next episode plays its 720p file.
5. Long-press a two-file movie tile: "Play Version…" sits under "Watch from Beginning" and works. A one-file tile has no such row.
6. In the picker, Menu returns focus to the Versions button, and Down on the last row does not scroll the episode page or the carousel behind it.
7. An episode with two files shows six action buttons on the carousel detail; check none is clipped.
8. Jellyfin: on the test server, add a second file to one movie's folder named after the folder with a ` - 1080p` suffix, and a third with ` - Directors Cut`. Repeat checks 1, 2 and 5; the Directors Cut row starts with that name.
9. Plex edition: on a test library, add `Movie (Year) {edition-Test Cut}.mkv` next to an existing movie. Both tiles open detail pages; the edition's page shows "Test Cut" in the year and runtime row.
