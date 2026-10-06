# iOS Downloads Implementation Plan

> **For agentic workers:** implement task by task; agents never commit.

**Goal:** Reliable iPhone/iPad downloads (Original as a direct part download, converted sizes through the PMS download queue), offline playback, offline progress sync.

**Spec:** `Docs/superpowers/specs/2026-10-06-ios-downloads-design.md`

## Global Constraints
- No `#if os(...)` under RivuletCore/. RivuletCore holds Plex endpoint code and pure rules only; transfer, files and UI live in RivuletiOS/Downloads/.
- Never put the token in a URL query for downloads (use the `X-Plex-Token` header), in records, manifests, logs or Sentry.
- Swift 6 with default MainActor isolation: the URLSession delegate and all model/manifest types are `nonisolated`; the temp file is moved synchronously inside `didFinishDownloadingTo` (no Task hop first).
- Background session identifier `com.gstudios.rivulet.downloads`. Files in `Application Support/Downloads/`, excluded from backup, default data protection. Manifest `Application Support/Downloads/manifest.json`, versioned, atomic writes.
- Settings keys: `downloadQuality` (StreamingQuality raw value; default `original`; allowed: original and steps 8000, 4000, 2000, 1500, 720), `downloadOverCellular` (Bool, default false).
- Measured PMS facts to honor: send X-Plex-Platform/Product/Version/Client-Identifier on queue calls (else decision 2004); never send Client-Profile-Name Generic; queue item status values deciding/waiting/processing/available/error/expired; `/media` is 503 until available; DELETE is `/downloadQueue/{q}/items/{id}`; queue status is not a completion signal; single Range headers only; PMS ignores If-Range so the app checks ETag (HEAD) before an app-initiated resume and checks final size.
- No em or en dashes. Short comments. Agents never commit.

## Review Focus
1. App killed (system) mid-download, relaunched: the download continues or resumes, never duplicates, never shows a stuck state.
2. No network at launch: the Downloads list and local playback work with no request, auth or profile prompt.
3. A converted download whose server job errors shows the server's reason and offers Retry; cancel deletes the server queue item.
4. Offline progress replays once on reconnect and never overwrites a later server-side view.
5. Deleting a download removes its files, its record, any task and any server queue item.

---

### Task A: RivuletCore Plex download endpoints
Create `RivuletCore/Plex/PlexDownloadQueue.swift` as a `PlexNetworkManager` extension using its existing request helpers and headers:
- `func serverIdentity(serverURL:authToken:) async throws -> String` (GET /identity, machineIdentifier).
- `func downloadQueueID(serverURL:authToken:) async throws -> Int` (POST /downloadQueue, idempotent per client id).
- `func addToDownloadQueue(serverURL:authToken:queueID:ratingKey:mediaIndex:maxVideoBitrateKbps:) async throws -> Int` (POST /downloadQueue/{q}/add with `keys=/library/metadata/{ratingKey}`, `mediaIndex`, `maxVideoBitrate`, header `X-Plex-Client-Profile-Extra: append-transcode-target-codec(type=videoProfile&context=static&protocol=http&videoCodec=hevc)`; returns the AddedQueueItems id).
- `func downloadQueueItem(serverURL:authToken:queueID:itemID:) async throws -> PlexDownloadQueueItem` (GET /downloadQueue/{q}/items/{id}); `PlexDownloadQueueItem { id, status: Status (deciding, waiting, processing, available, error, expired, unknown(String)), progress: Double?, errorText: String? }` decoded from the measured JSON (TranscodeSession.progress; DecisionResult/generalDecisionText or error).
- `func downloadQueueDecision(...) async throws -> (width: Int?, height: Int?, bitrateKbps: Int?, sizeBytes: Int?)` (GET .../item/{id}/decision, Metadata.Media).
- `func removeDownloadQueueItem(...) async` (DELETE /downloadQueue/{q}/items/{id}, errors ignored).
- `func downloadQueueMediaRequest(serverURL:authToken:queueID:itemID:) -> URLRequest?` and `func partDownloadRequest(serverURL:authToken:partKey:) -> URLRequest?` (GET `{partKey}?download=1`; token and identity headers, never in the query).
Tests `RivuletTests/Unit/Plex/PlexDownloadQueueTests.swift`: request URL/method/header building (no token in query), item decoding for each status from fixtures copied (token-free) from measured PMS responses.

### Task B: RivuletCore download records and offline progress
Create `RivuletCore/Downloads/DownloadRecord.swift`, `DownloadManifest.swift`, `OfflineProgressLog.swift` (all `nonisolated`, Codable, Sendable):
- `DownloadRecord { id: String (UUID); serverID: String; profileID: String?; ratingKey: String; mediaID: Int; partID: Int?; quality: String (StreamingQuality raw); state: DownloadState; expectedBytes: Int64?; receivedBytes: Int64; etag: String?; queueItemID: Int?; fileName: String?; posterFileName: String?; subtitleFiles: [SubtitleFile]; metadata: PlexMetadata; outputLabel: String?; createdAt: Date; completedAt: Date? }`; `DownloadState { waitingForNetwork, waitingForServer, preparing(progress: Double), downloading, paused, failed(reason: String), completed }`; `SubtitleFile { fileName, language, title, codec, isForced }`.
- `DownloadManifest { version: Int; records: [DownloadRecord] }` with `load(from:)` (missing or corrupt file gives an empty manifest; corrupt file is renamed `.corrupt`) and `save(to:)` using `Data.write(options: .atomic)`; `reconciled(filesPresent: Set<String>) -> DownloadManifest` marks a completed record whose file is missing as `failed("File missing")` and drops nothing.
- `OfflineProgressLog { entries: [Entry] }`, `Entry { serverID, profileID?, ratingKey, offsetMs, durationMs?, watched: Bool, at: Date }`; `mutating func record(_:)` coalesces by (serverID, profileID, ratingKey) keeping the latest `at` and OR-ing `watched`; `static func shouldReplay(_ entry:, serverLastViewedAt: Date?) -> Bool` (true when the server has no later view).
Tests: coding round trip, corrupt manifest recovery, reconciliation, coalescing, replay rule.

### Task C: iOS transfer engine
`RivuletiOS/Downloads/IOSDownloadTransfer.swift`: `nonisolated final class IOSDownloadTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable` with a shared instance, the background configuration (isDiscretionary false, sessionSendsLaunchEvents true, httpMaximumConnectionsPerHost 2, allowsCellularAccess true; expensive/constrained set per request from `downloadOverCellular`), a serial delegate OperationQueue, plex.direct trust reusing `PlexCertificateDelegate`'s challenge handling, `func start(request:recordID:expectedBytes:)`, `func resume(data:recordID:)`, `func cancel(recordID:produceResumeData:)`, `func allTasks() async`, callbacks to the download center (progress, finished file URL already moved, failure with resume data). `didFinishDownloadingTo`: reject non-200/206 and size mismatches, remove an existing destination, move into `Application Support/Downloads/<recordID>.<ext>`, set isExcludedFromBackup on file and directory. `didCompleteWithError`: persist `NSURLSessionDownloadTaskResumeData` to `Downloads/<recordID>.resume`; map force-quit cancellation to `paused`.
`RivuletiOS/IOSAppDelegate.swift` with `@UIApplicationDelegateAdaptor` in `RivuletiOSApp` implementing only `application(_:handleEventsForBackgroundURLSession:completionHandler:)` (store the handler, touch the shared session); call it from `urlSessionDidFinishEvents` on the main queue.
Add `NSPrivacyAccessedAPICategoryDiskSpace` with reason `E174.1` to `RivuletiOS/PrivacyInfo.xcprivacy`.

### Task D: iOS download center
`RivuletiOS/Downloads/IOSDownloadCenter.swift` (`@MainActor final class: ObservableObject`, shared, injected as environment object at the root):
- Published records; `state(for ratingKey:)`; `localPlayback(for ratingKey:) -> IOSPlexPlaybackRequest?` (file URL, `[:]` headers, stored metadata with markers, local sidecars, local poster URL).
- `download(_ item: PlexMetadata, quality: StreamingQuality?)`: refuse relay (`ServerLocation.classify == .relay`), check free space (`volumeAvailableCapacityForImportantUsage` >= expected + 1 GB), fetch full metadata, server identity, `VersionRanking.select(.best, in:, capKbps:)` for the media, save poster (and Original sidecar subtitles with real extensions), then: Original (or a step at or above the source bitrate) and single part: HEAD for ETag and size, start the part transfer; multi-part Original: fail with the spec's reason; converted: add to the download queue, set `preparing`, and poll every 3 s while the app runs (and on launch/foreground) until `available` (then start the media transfer), `error`/`expired` (fail with the server's text). 403 maps to the spec's remote-pass reason; 401 retries once with the current token.
- `downloadSeason(_ season: PlexMetadata, quality:)`: fetch children, start each episode in one pass (all tasks created in the foreground at once).
- `cancel`, `retry`, `delete(recordID:)` (cancel task, delete files and resume data, remove the server queue item, drop the record), `deleteAll()`, `storageUsed`.
- Launch reconciliation: load the manifest, reconcile with files on disk and `allTasks()` (re-attach by `taskDescription`, cancel orphan tasks, restart records without tasks from resume data after an ETag HEAD check, or from zero), resume polling preparing items. On foreground: if a record's task host differs from the current server URL host, restart it on the current URL.
- Path gating: when `downloadOverCellular` is off and `NetworkPathMonitor.shared.isAwayPath` is true, new and waiting items show `waitingForNetwork`.
- Profile scoping: list filters by current `PlexUserProfileManager` user id (fall back to all when none).

### Task E: Playback, offline progress, UI
- `IOSPlexSession.playback(for:quality:)`: return `IOSDownloadCenter.shared.localPlayback(for:)` first when a completed download exists (Up Next benefits automatically). The Quality menu is hidden for local requests (`plan == .original` and a file URL: pass nil to the chrome).
- `IOSPlexSession.reportProgress` / `markWatched`: on failure append to `OfflineProgressLog` (persisted next to the manifest); flush after `verifyConnection` or `refresh` succeeds: fetch metadata, apply `shouldReplay`, send timeline `stopped` at the offset, scrobble when watched, drop on success.
- UI (SwiftUI, follow the existing glass/list idioms in RivuletiOS):
  - `IOSDownloadsView`: Movies, then TV shows grouped by show and season; rows with poster, title, size and state text from the spec; swipe to delete; tap plays completed items via `plexActions.play`; empty state.
  - Library tab: a "Downloads" row at the top of `IOSPlexLibrariesView`, shown even when libraries fail to load; iPad sidebar: a "Downloads" tab in the Library `TabSection` (regular width only, like the libraries).
  - `IOSDownloadButton` in the detail action row next to the watchlist button (movie/episode): Download, progress ring, checkmark with a menu (Play, Remove Download); "Download Season" in the season menu; "Download" / "Remove Download" in `IOSPlexItemMenu` via a new `IOSPlexActions.download` closure.
  - Settings: a "Downloads" NavigationLink in the Account sheet's Settings section: Download Quality picker, Download over Cellular toggle, storage used, Delete All Downloads (confirmation dialog).
  - Home and Library error views: "Go to Downloads" when downloads exist.
- Build iOS; run the full tvOS suite (RivuletCore tests).

### Task F: Verification (coordinator)
Simulator: download an Original episode from the LAN PMS; play it with networking blocked (server URL unreachable); download a converted episode (watch preparing → downloading → done); delete; relaunch reconciliation; offline progress replays after reconnect. Device-only items stay labelled unverified.
