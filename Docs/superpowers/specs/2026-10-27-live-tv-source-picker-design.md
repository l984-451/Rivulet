# Live TV source picker: one row per app, Tvheadend support

Date: 2026-10-27. Issue #415 (Tvheadend).

## Why

The Add Live TV Source page has three rows: Xtream Codes, Playlist URL and My
Own Server. My Own Server is a Dispatcharr form with address presets for other
apps, but every server added through it is fetched at Dispatcharr's paths
(`/output/m3u`, `/output/epg`, `DispatcharrService.outputURL`). The Threadfin,
xTeVe, ErsatzTV and Cabernet presets therefore point at paths those apps do
not serve. Tvheadend (#415) has no way in at all: different paths, and its
streams usually need a login.

The fix is to name each app on the top page, the way Plex and Jellyfin each
have their own sign-in, and give each one a form that asks only for what that
app needs. Rivulet knows each app's paths, so nobody types one.

Success: someone running Dispatcharr, Tvheadend or Threadfin picks their app,
confirms a prefilled address, and has channels and a guide. A Tvheadend user
who signs in can schedule recordings from the guide and player exactly as a
Dispatcharr user can.

## Goals

- Top page lists every source kind directly. My Own Server is removed.
- Per-app forms with per-app fields and a prefilled address.
- Threadfin works (today's preset is broken).
- Tvheadend: live channels, guide, and recording (single airing, series, new
  episodes, scheduled list, cancel, rules), on tvOS and iOS.

## Non-goals

- Watching finished recordings. No Live TV source has a recordings library;
  that is its own project.
- xTeVe, ErsatzTV, Cabernet. Dropped (decided). Their presets go away.
- Tvheadend's HTSP protocol, persistent-auth codes, or transcoding profiles.
  Streams use `profile=pass` (raw TS), which Aether demuxes.
- Threadfin authentication. Address only.
- Migrating existing sources. Saved Dispatcharr sources keep working
  unchanged. A Threadfin server added through the old preset never loaded
  channels, so there is nothing to migrate.

## Anti-goals (a failure even if it works)

- A generic "any server" form that guesses paths.
- A field on a form that the app does not use.
- An extra page between a row and its keyboard (the `EntryStep` rule in
  CLAUDE.md "Adding Settings").
- A Tvheadend password or ticket in a log, an error message, or Sentry.
- Any change in behavior for an existing Dispatcharr, M3U or Xtream source.

## The page (decided)

```
Add Live TV Source
  ── Your Server ──────
  Dispatcharr
  Tvheadend
  Threadfin
  ── Provider ─────────
  Xtream Codes
  Playlist URL
```

tvOS: the headers are `SettingsRowItem.header(_:)`. iOS: two `Section`s in
`IOSLiveAddSourceSheet`. No Plex or Jellyfin row (unchanged).

## The forms

Every server form prefills Server Address with
`http://<LiveTVSourceConnector.suggestedHost>:<default port>` when the draft
begins. The address row stays editable.

| App | Fields | Default port |
|---|---|---|
| Dispatcharr | Server Address, Username, Password, Channel Profile, Name | 9191 |
| Tvheadend | Server Address, Username, Password, Name | 9981 |
| Threadfin | Server Address, Name | 34400 |
| Xtream Codes | unchanged | n/a |
| Playlist URL | unchanged | n/a |

- **Dispatcharr** is today's My Own Server form with the presets removed and
  its copy rewritten to name only Dispatcharr. Same `ServerRequest`, same
  `.dispatcharr` source type.
- **Threadfin** is saved as a generic M3U source
  (`addM3USource`) with `<base>/m3u/threadfin.m3u` and
  `<base>/xmltv/threadfin.xml`. No new source type (my call: a type would add
  maintenance for nothing the M3U path doesn't already do). Its verify is the
  existing playlist check.
- **Tvheadend** username and password are optional. Without them Rivulet
  watches anonymously (a common home setup) and offers no recording. Copy
  says so, as Dispatcharr's does.

Each form and field gets a `SettingsDescriptors` entry (description panel). The
`addOwnServer` page, its descriptor, `serverSuggestions` and the iOS
`IOSLiveServerForm` presets are removed; the `SettingsPage` cases become
`addDispatcharr`, `addTvheadend`, `addThreadfin`. The setup landing
(`SetupLandingViewController` → `.addLiveTVSource`) picks the change up with
no edit.

## Tvheadend source

New `LiveTVSourceType.tvheadend` (display name "Tvheadend"). A
`TvheadendService` actor in `RivuletCore/IPTV/`, beside `XtreamService`, owns
every Tvheadend request. `IPTVProvider` gains a Tvheadend init, as it has for
Xtream. All of it in RivuletCore, no `#if os`.

**Persistence.** `SourceConfiguration` type `"tvheadend"`, `baseURL`,
`username`; the password in the Keychain under `apiTokenKey(sourceId:)`, as
Xtream does. Source id: `"tvheadend:"` + a hash of server and username, as
`xtreamSourceId` does, so neither appears in channel ids.

**Auth.** Tvheadend answers with HTTP Digest by default (Basic if configured).
Requests answer the challenge with the stored credential through a
URLSession delegate. Anonymous sources send none.

**Verify (connect).** `GET /api/serverinfo` must return Tvheadend's reply
(it carries `sw_version` / `api_version`); anything else is "That address
isn't a Tvheadend server." Then the channel list must be non-empty. Errors map
to copy the way `xtreamFailureCopy` does: wrong login (401), no rights (403),
not Tvheadend, no channels, unreachable.

**Channels and guide come from the JSON API** (my call):
`/api/channel/grid` (uuid, number, name, icon, tags) and
`/api/epg/events/grid` (eventId, channelUuid, start, stop, title, subtitle,
description, episode, series link). Reason: recording needs Tvheadend's
`eventId` and channel uuid, and XMLTV carries neither, so the API avoids a
second id-matching layer. Channel tags (`/api/channeltag/grid`) become the
channel's group, as Xtream categories do. Grids return 50 rows unless `limit`
is passed; fetch everything the guide window needs. The EPG fetch window and
paging are the builder's call; keep it within `BoundedDownload` limits.

**Playback.** Anonymous: `<base>/stream/channel/<uuid>?profile=pass`. Signed
in: `IPTVProvider.resolveStreamURL` fetches a one-entry ticketed playlist
(`/playlist/ticket/channel/<uuid>`) just before each play and returns its
stream URL, because tickets expire after five minutes. Every playback path
(tvOS player, multiview, iOS) already calls `LiveTVDataStore.resolveStreamURL`.
A ticket is never reused: each play and each retry fetches a new one.

Ticket failure (my call): verify, when signed in, fetches a ticket for the
first channel. If that fails the source is not added, with copy that names
the cause (the user has no streaming right, or the server is too old to
issue tickets). There is no version floor beyond that check and no fallback
that puts the login in a URL. A ticket failure at play time fails playback
with the same copy.

Channel logos (my call): use the channel's original `icon` when it is an
absolute public http(s) URL (picons usually are). Otherwise use the
`/imagecache/` URL, which anonymous servers serve. For a signed-in source whose
imagecache needs the login, the logo stays blank: the image loader gets no
credentials. Measure which case a default server is in before shipping.

## Tvheadend recording

`IPTVProvider` conforms through the existing `LiveTVRecordingProvider` seam
(as `IPTVProvider+DVR.swift` does for Dispatcharr), in a separate
`IPTVProvider+TvheadendDVR.swift` or within `TvheadendService`; builder's call.
No UI changes: the guide, player and scheduled/rules pages already drive the
seam.

- `supportsRecording`: a Tvheadend source with a username (my call). Login
  and recording permission are separate in Tvheadend. If verify can read the
  user's DVR right cheaply (the web UI's `accessUpdate` carries a `dvr`
  flag; measure it), store it and require it too. If not, the options show
  and a 403 reports "This Tvheadend user can't record."
- Movies (my call): Tvheadend's EPG has no movie flag, and DVB genre 0x1 ("movie/drama")
  covers drama series too, so every Tvheadend programme counts as a show and
  gets the series options. A title-match rule on a film just records its
  repeats, which is harmless. The title-match fallback is the common path,
  not the rare one, because most DVB guides outside the UK have no series link.
- **Record**: `dvr/entry/create_by_event` with the programme's `eventId` and
  the server's default DVR config.
- **Record Series**: `dvr/autorec/create_by_series` when the event has a series
  link; otherwise `dvr/autorec/create` matching the title on that channel.
  Offered only for non-movies, as Dispatcharr does.
- **Record New Episodes**: the same rule with Tvheadend's duplicate-skipping
  setting. The exact autorec field and value must be measured on a real server
  before it ships; if no setting fits, drop this option for Tvheadend.
- **Scheduled list**: `dvr/entry/grid_upcoming` plus recording/finished/failed
  from `dvr/entry/grid`, mapped to `LiveTVScheduledRecording.Status`, with
  `ruleId` from the entry's autorec.
- **Cancel one airing**: `dvr/entry/cancel`. **Delete a rule**: `idnode/delete`
  with the autorec uuid (removes its pending timers).
- `UnifiedProgram` must carry the `eventId` so Record can use it; how it rides
  (`sourceGuid` or a new field) is the builder's call.

## Constraints

- RivuletCore holds the service, provider, connector and persistence; no
  platform conditionals (lint-enforced).
- Never send a stream URL, ticket or reply body to Sentry or a log.
- Every `switch` over `LiveTVSourceType` gains the case; the compiler finds
  them.
- iOS mirrors the page and forms in SwiftUI (`IOSLiveTVSettingsView.swift`).
- Changelog lines on both platforms at release (`rivulet-changelog` skill).

## Verification

- Unit tests: `TvheadendService` reply parsing (fixtures captured from a real
  server, credentials stripped), connector request checks, Threadfin URL
  building, the new source type's save/load round trip, recording option
  building and status mapping.
- A real Tvheadend: `linuxserver/tvheadend` in Docker on Unraid with an IPTV
  Automatic Network fed by an M3U (Dispatcharr's output works). No tuner and no
  GPU needed. Test anonymous and Digest login; play a channel; let one session
  run past five minutes and re-tune to prove ticket refresh; record one airing,
  one series, cancel, delete the rule.
- A real Threadfin, or a measured reply, to confirm both paths.
- tvOS simulator for the forms; device for playback of a real DVB-style TS if
  available.

## Left to the builder

File layout inside RivuletCore, the EPG window and paging, where `eventId`
rides, form copy and descriptor wording (plain, short, no em dashes), and test
structure.
