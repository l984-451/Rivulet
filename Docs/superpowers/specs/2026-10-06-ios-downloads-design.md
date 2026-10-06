# iOS / iPadOS Downloads Design

2026-10-06. Goal: downloads on iPhone and iPad that reliably work, where Plex's own downloads
often fail. Decisions below are
grounded in measurements on PMS 1.43.4 and public failure reports
(research notes kept locally).

## Why Plex's downloads fail, and what we do instead

| Plex failure | Our answer |
|---|---|
| Every download, even "Original", goes through the server's download queue: decision, temp-dir space, one or two jobs at a time, DTS conversions, Plex Pass gate | Original is a plain ranged GET of the part file. No server job. AetherEngine plays every source codec offline. |
| Foreground-only or flaky background transfers | One background `URLSession`; resume data persisted; reconcile on launch |
| Wi-Fi Only fails the item | Waiting is a state ("Waiting for Wi-Fi"), never a failure |
| Offline launch hits a sign-in or profile wall | Downloads render from local records with no network, auth or profile gate |
| Downloaded items still stream from Home | Play prefers the local file everywhere |
| Offline progress lost or reset | Persisted, coalesced progress log; replayed with a conflict check |
| Relay downloads fail silently | Relay is refused up front with a reason |
| Server errors shown as "stuck" | Server state and decision text shown by name |

## Behavior

- **Where**: Library tab, a "Downloads" row at the top of the library list (Apple TV app
  pattern); a "Downloads" item in the iPad sidebar Library section. When Home or Library
  cannot load, the error view offers "Go to Downloads".
- **Start**: a download circle button on movie and episode detail pages (next to the
  watchlist button), "Download" in the long-press menu, and "Download Season" in a season's
  menu. The button shows Download, a progress ring, or a checkmark (menu: Play, Remove
  Download).
- **Quality**: Settings → Downloads → "Download Quality" (default Original). Choices:
  Original, 8 Mbps 1080p, 4 Mbps 720p, 2 Mbps, 1.5 Mbps, 720 kbps (shared `QualityStep`).
  Converted labels come from the server's decision, not the ladder (2 and 1.5 Mbps both
  produce 404p on PMS). Steps at or above the file's bitrate download the Original instead.
- **Cellular**: Settings → Downloads → "Download over Cellular" (default off). Off means
  "Waiting for Wi-Fi" on cellular, hotspot, or Low Data Mode.
- **States** a row shows: Waiting for Wi-Fi, Waiting for Server, Preparing on Server 40%,
  Downloading 35% · 1.2 GB of 3.4 GB, Paused (open Rivulet to continue), Failed: reason
  (Retry), Downloaded · 3.4 GB.
- **List**: Movies, then TV Shows grouped by show and season. Swipe to delete. Tap a
  downloaded row to play. Settings → Downloads shows storage used and "Delete All
  Downloads".
- **Playback**: any Play of a downloaded item (tile, detail, Up Next) plays the local file,
  online or not. The Quality menu is hidden for local files. Intro/credit markers, sidecar
  subtitles (Original), poster and Now Playing art work offline.
- **Offline progress**: position and watched state recorded while offline sync on the next
  successful connection, unless the server shows a later view of that item.
- **Scope**: downloads belong to the server and the Plex Home profile that made them; the
  list shows the current profile's downloads (the last profile when offline). Sign-out and
  profile switches never delete downloads.
- **Refused with a reason**: Relay connection ("Downloads need your home network or a direct
  remote connection"), HTTP 403 on a remote part ("Plex requires Plex Pass or Remote Watch
  Pass for remote downloads; download at home"), not enough space, multi-part Original
  ("This version is split into parts; choose a converted quality").

## Architecture

### RivuletCore (Plex behavior and pure rules, tested)
- `PlexNetworkManager` download APIs (`RivuletCore/Plex/PlexDownloadQueue.swift`):
  `downloadQueue()` (POST /downloadQueue), `addToDownloadQueue(queueID:ratingKey:mediaIndex:maxVideoBitrate:)`
  (POST /downloadQueue/{q}/add?keys=/library/metadata/{key}&maxVideoBitrate=…, with the
  `append-transcode-target-codec(type=videoProfile&context=static&protocol=http&videoCodec=hevc)`
  profile extra), `downloadQueueItem(queueID:itemID:)` (GET /downloadQueue/{q}/items/{id}:
  status deciding/waiting/processing/available/error/expired, TranscodeSession progress,
  decision error text), `downloadQueueDecision` (output width/height/bitrate for the label
  and size), `removeDownloadQueueItem` (DELETE /downloadQueue/{q}/items/{id}),
  `downloadQueueMediaURL`, `partDownloadURL(partKey:)` and `serverIdentity()` (GET
  /identity → machineIdentifier). Always send X-Plex-Platform, Product, Version and the
  stable client identifier (missing headers give decision 2004).
- `RivuletCore/Downloads/`: `DownloadRecord` (id, server machine id, profile id,
  ratingKey, media id, part id, quality, state, bytes, expected size, ETag, queue item id,
  relative file paths, stored `PlexMetadata` JSON, created/completed dates),
  `DownloadManifest` (versioned JSON, atomic writes, reconcile against files on disk),
  `OfflineProgressLog` (coalesced per server+profile+ratingKey; `shouldReplay(local:serverLastViewedAt:)`).

### RivuletiOS/Downloads (transfer, files, UI)
- `IOSDownloadCenter` (MainActor ObservableObject): records, start/cancel/retry/delete,
  queue polling for converted items (while the app runs; resumes on launch), space check,
  path and relay gating, ETag check before app-initiated resumes, host-change restart.
- `IOSDownloadTransfer` (nonisolated `URLSessionDownloadDelegate`): one background session
  `com.gstudios.rivulet.downloads`, `isDiscretionary = false`, `sessionSendsLaunchEvents`,
  `httpMaximumConnectionsPerHost = 2`, per-request cellular/expensive/constrained flags
  from the setting, `taskDescription = record id`, token in the `X-Plex-Token` header,
  plex.direct trust through `PlexCertificateDelegate`'s logic, file moved synchronously in
  `didFinishDownloadingTo` after checking status 200/206 and size, resume data persisted on
  every error, `getAllTasks` reconciliation at launch.
- `IOSAppDelegate` via `@UIApplicationDelegateAdaptor`, implementing only
  `handleEventsForBackgroundURLSession` (startup order untouched).
- Files: `Application Support/Downloads/<record id>.<ext>`, excluded from backup, default
  protection class. Poster saved as a file; sidecar subtitles saved with real extensions.
- `IOSPlexSession.playback(for:)` checks the download center first and returns a local
  request (file URL, no headers, stored metadata and markers, local sidecars, local art).
- `reportProgress` / `markWatched` append to `OfflineProgressLog` on failure; the log
  flushes after `verifyConnection` or `refresh` succeeds.
- UI: `IOSDownloadsView` (list), `IOSDownloadButton` (detail), menu items, Settings →
  Downloads page, Library row and iPad sidebar item, "Go to Downloads" on load errors.
- `PrivacyInfo.xcprivacy`: add DiskSpace E174.1 (required for the free-space check).

## Testing
Unit (RivuletTests): download queue request building and response decoding (fixtures from
the measured responses, token-free), manifest round trip and reconciliation, offline
progress coalescing and the replay conflict rule. Simulator: a real Original download from
the LAN PMS, local playback with the network unreachable, a converted download through the
queue, delete, relaunch reconciliation. Device-only and unverified until tested on
hardware: background completion after the app is suspended, relaunch events, cellular
waiting.
