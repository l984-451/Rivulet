# Streaming Quality (Home / Away, Auto) Design

Approved 2026-10-06. Applies to tvOS (Plex and Jellyfin) and iOS/iPadOS (Plex).

## Behavior

- Two settings, shared keys: **Home Streaming Quality** (default Original) and
  **Away Streaming Quality** (default Auto). Options: Original, Auto, 20 Mbps 1080p,
  12 Mbps 1080p, 8 Mbps 1080p, 4 Mbps 720p, 2 Mbps 720p, 1.5 Mbps 480p, 720 kbps.
- **Home** = the playback server URL is a local address AND the device path is not
  cellular, not expensive (personal hotspot) and not constrained (Low Data Mode).
  Everything else is **Away**. A Plex Relay connection is always capped at 1.5 Mbps
  480p as today (`min(step, relay)`; Original is impossible on relay).
- **Original** plays the untouched file (the aether route), exactly as today.
- **Fixed step**: transcode at that step, unless the source bitrate is already at or
  under the step, in which case play the original.
- **Auto**: probe throughput (ranged GET of the direct-play URL, at most ~2 s or
  4 MB, rate measured from the first byte). If source kbps <= 0.75 x measured, play
  the original; else transcode at the highest ladder step <= 0.75 x measured (floor:
  the lowest step). Unknown source bitrate (no bitrate, no size/duration) plays the
  original. A failed probe transcodes at 4 Mbps 720p when the source is above it.
  While Auto is in effect, two stalls within 60 s, or one stall lasting 10 s, step
  down one ladder step and reload at the current position. User seeks and the
  first seconds after a load never count. Never step up mid-title.
- **Versions**: with a cap in effect and `.best`/`.matchingTier`, prefer the
  best-ranked version whose bitrate fits under the cap and whose tier is at least the
  step's tier; if none fits, take the lowest-bitrate version and transcode it.
  An explicit Play Version pick (`.source`) is honored and transcoded if over the cap.
- **In-player Quality menu** (tvOS rail, iOS chrome; VOD only, hidden on Live TV):
  shows the effective quality ("Auto · 8 Mbps", "Original", "4 Mbps 720p"); a change
  reloads at the current position and persists for the rest of the player session
  (Up Next included). Leaving the player resets to the settings.
- **Up Next** re-decides under the session's choice; Auto resets steps and reuses a
  throughput measurement younger than 10 minutes instead of probing again.
- **Track changes on a transcode work**: the chosen audio/subtitle stream is PUT to
  the part (`setSelectedAudioStream` / `setSelectedSubtitleStream`) before a Plex
  transcode session starts, and changing audio or subtitles while on a transcode
  reloads at the current position.
- **iOS fallback**: a direct-play startup failure retries once as a transcode (Auto
  step, else 8 Mbps), matching tvOS.
- Detail badges stay the file's own (uncapped). Transcodes lose HDR/DV/Atmos.

## Architecture

### RivuletCore/Streaming (new, no `#if os`, `nonisolated` value types)

- `StreamingQuality`: `.original`, `.auto`, `.step(QualityStep)`; RawRepresentable
  String ("original", "auto", "8000") for AppStorage/UserDefaults. Keys
  `homeStreamingQuality`, `awayStreamingQuality`; defaults original / auto.
- `QualityStep`: kbps + videoResolution + label. Ladder:
  20000/12000/8000 at 1920x1080, 4000/2000 at 1280x720, 1500 at 720x480,
  720 at 576x320. `relay` = the 1500 step.
- `ServerLocation.classify(URL) -> .local | .remote | .relay`: relay via
  `PlexRelay.isRelayURL`; local for IP literals and plex.direct hosts whose first
  label decodes (dashes to dots/colons) to an address in 10/8, 172.16/12,
  192.168/16, 100.64/10, 169.254/16, 127/8, fc00::/7, fe80::/10, ::1; plus
  `localhost` and `*.local`. Replaces the dead `PlexNetworkManager.isLocalServer`.
- `NetworkPathMonitor.shared`: one `NWPathMonitor`; `isAwayPath` = cellular ||
  expensive || constrained.
- `StreamingQuality.effective(serverURL:)`: picks the home or away setting.
- `ThroughputProbe.measure(url:headers:) async -> Int?` (kbps); rate math is a
  pure function with tests.
- `QualityDecision.decide(setting:sourceKbps:measuredKbps:isRelay:) -> StreamPlan`
  (`.original` / `.transcode(QualityStep)`) and `stepDown(from:sourceKbps:)`.
- `StallTracker`: pure; `bufferingStarted(at:)` returns step-down on the 2nd stall
  in 60 s; ignores stalls within 5 s after a seek or load; `isLongStall(since:now:)`
  at 10 s.
- `VersionRanking` pure core moves here (Key, tier, rankedIndices, pick with an
  optional cap, `select(_:in: [PlexMedia], capKbps:)`); the `MediaSource`
  adapter (`key(MediaSource)`, `choose`, `primarySource`) stays in `Rivulet/`.
- `PlexNetworkManager.buildHLSDirectPlayURL` gains `step: QualityStep? = nil`.
  Effective cap = relay ? min(step, relay) : step. A cap forces transcode
  (h264, DV off), sets `maxVideoBitrate`, `videoResolution`, and the
  `add-limitation video.bitrate` clause; audio is transcoded (320 kbps) only
  for steps under 4 Mbps. Relay output stays byte-identical to today.

### tvOS (Rivulet/)

- `UniversalPlayerViewModel.prepareStreamURL`: resolve location, setting (session
  override first), probe if Auto needs it, decide; store the plan; pass the step
  through `ContentRoutingContext` (a step means HLS-only, like relay) and
  `buildRivuletHLSURL`.
- One reload helper extracted from `attemptRivuletHLSFallback` (build at the current
  offset, stop the OUTGOING Plex transcode session, preflight, load, seek); used by
  the menu, the stall step-down and HLS track changes. The one-shot fallback keeps
  its guards and telemetry. Switching to Original re-runs the normal start path at
  the current position.
- Stall step-down hooks the existing buffering funnel, stamps user seeks, cancels
  the aether stall watchdog when it fires, and runs only while Auto is in effect.
- The next-episode preload honors the active plan.
- Rail: a `qualityButton` (hidden by default; VOD only) presenting
  `CardTrackListView` like the Content Filter menu.
- Settings: two `.navigationValue` rows on Playback with picker pages,
  descriptors and pageInfo; a reader at play time (grep each key).
- Jellyfin: `MediaProvider.resolveStream/transcodeStream` take an optional max
  bitrate (bps); `JFPlaybackInfoRequest.playback` uses it instead of the 400 Mbps
  constant when set; the client-side `choose` uses the same cap;
  `ProviderPlayback.prepare` decides; step-down uses `switchToProviderTranscode`.
- Diagnostics: `quality` and `location` tags; never URLs.

### iOS (RivuletiOS/)

- `IOSPlexSession.playback(for:quality:)`: version select with cap, decide, build
  the direct URL or the shared transcode URL (auth in headers). The request carries
  the plan, the transcode session id and the source kbps.
- `IOSPlexPlayback.switchQuality(_:)`: stop the old transcode session, rebuild at
  `player.currentTime`, load without `onItemChange` (keeps PiP and Now Playing),
  keep rate and paused state. Stop the transcode session on end.
- `AetherPlayer` (iOS) publishes stall starts from `engine.playbackPhase`
  (`.rebuffering`, `.stalled`), excluding seeks and startup.
- Chrome: an optional quality Menu+Picker beside the speed menu (nil hides it;
  Live TV passes nil). Settings: a Streaming Quality section with Home and Away
  pickers on the same keys.

## Testing

Unit (RivuletTests): decision table, ladder/step-down, location classifier
(plex.direct dashes, IPv6, CGNAT, 172.16/12 edges), stall tracker, probe rate
math, version ranking with a cap (existing VersionRankingTests unchanged),
`buildHLSDirectPlayURL` with a step (relay tests unchanged), Jellyfin request
bitrate. Simulator: forced Away via a temporary debug hook on both apps; play a
transcode, switch quality in the player, step down via a forced stall. Device
behavior on a real slow link is unverified until tested on hardware.
