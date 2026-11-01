# Live TV Source Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace My Own Server with one add-source row per app (Dispatcharr, Tvheadend, Threadfin, Xtream Codes, Playlist URL), fix Threadfin, and add Tvheadend live TV, guide and recording on tvOS and iOS.

**Architecture:** Threadfin becomes a playlist source with known paths. Tvheadend is a new `LiveTVSourceType` served by a `TvheadendService` actor in `RivuletCore/IPTV/`, plugged into `IPTVProvider` the way `XtreamService` is, and into the existing `LiveTVRecordingProvider` seam the way Dispatcharr DVR is. The UI changes are the tvOS add-source pages (`AddLiveTVSourceContent.swift`) and the iOS sheet (`IOSLiveTVSettingsView.swift`).

**Tech Stack:** Swift 6, UIKit (tvOS settings), SwiftUI (iOS settings), XCTest with `MockURLProtocol`.

**Spec:** `Docs/superpowers/specs/2026-10-27-live-tv-source-picker-design.md`

## Global Constraints

- No commits per task. Subagents never commit. The coordinating session makes ONE commit at the end (spec, plan and code together, `git add -f` for the two `Docs/` files), after build, tests and diff review.
- Everything except views goes in `RivuletCore/`. No `#if os(...)` there (lint-enforced).
- `AetherPlayer` and engine types are untouched.
- Never put a Tvheadend password, ticket, stream URL or reply body in a log, an error string or Sentry.
- No behavior change for saved Dispatcharr, M3U or Xtream sources.
- Copy: plain, short, no em or en dashes. Settings rows are title-only; descriptions go in `SettingsDescriptors.swift`.
- Streams use `profile=pass`.
- Test command (from repo root; reuse one scratch derived data path):
  `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath /private/tmp/claude-501/rivulet-dd -only-testing:RivuletTests/<Class>`
- Tests are XCTest: `final class FooTests: XCTestCase`, `@testable import Rivulet`, `MockURLProtocol` sessions as in `XtreamServiceTests`. Fixtures load with `loadFixture(_:extension:subdirectory:)` from `RivuletTests/Fixtures/<dir>/`.

## Review Focus

1. A Tvheadend channel replayed more than 5 minutes after its last play must get a new ticket; a cached ticket fails. (Task 3 test `test_ticketedStreamURL_fetchesEveryTime`.)
2. A password holding `/ + ? @ :` must never appear in any request URL. (Task 3 test `test_password_neverInAnyRequestURL`.)
3. A programme title with regex characters ("Who Wants to Be a Millionaire?") must make a series rule that matches exactly that title. (Task 5 test `test_titleRule_escapesRegex`.)
4. Re-adding the same server and user replaces the source; the same server added anonymously and signed in stays two sources. (Task 4 test `test_tvheadendSourceId_stableAndPerUser`.)
5. A channel grid holding disabled channels, a channel with no number and one with no icon. Disabled ones are skipped, the rest load. (Task 3 test `test_channels_skipDisabled_keepMissingNumberAndIcon`.)

---

### Task 1: Measure a real Tvheadend and capture fixtures

No product code. Everything later tests against what this task records.

**Files:**
- Create: `RivuletTests/Fixtures/Tvheadend/serverinfo.json`, `channel_grid.json`, `channeltag_grid.json`, `epg_events_grid.json`, `dvr_entry_grid.json`, `dvr_autorec_grid.json`, `ticket_playlist.m3u`

- [ ] **Step 1: Run Tvheadend on Unraid** (`unraid-server` skill). Container `lscr.io/linuxserver/tvheadend:latest`, ports 9981 and 9982, appdata under `/mnt/user/appdata/tvheadend-test`. No GPU, so no GPU hold is needed.
- [ ] **Step 2: Give it channels without a tuner.** Add an IPTV Automatic Network whose URL is an M3U the box already serves (Dispatcharr's `/output/m3u` on the same server), scan, map services to channels, and enable the XMLTV/EPG grabber so events exist. Create user `rivulet` with streaming and DVR rights. Leave anonymous streaming off at first.
- [ ] **Step 3: Capture replies** with `curl --digest -u rivulet:<pw>`: `/api/serverinfo`, `/api/channel/grid?limit=5`, `/api/channeltag/grid?limit=50`, `/api/epg/events/grid?limit=5`, `/playlist/ticket/channel/<uuid>`. Schedule one recording and one series rule in the web UI, then capture `/api/dvr/entry/grid?limit=5` and `/api/dvr/autorec/grid?limit=5`. Replace host, tickets and any usernames with `tvh.test`, `TICKET`, `user`. Edit `channel_grid.json` so it holds one disabled channel, one with no `number`, and one with no `icon`.
- [ ] **Step 4: Record these measurements as a header comment for `TvheadendServiceTests` (Task 3)**:
  - Default HTTP auth type (Digest, Plain or both) and the status an unauthenticated API call gets.
  - Whether `/imagecache/<n>` serves without a login. Check both with anonymous access off and with it on.
  - The exact `record` (duplicate handling) enum value that means "new episodes only", from `/api/dvr/autorec/class`. If no value fits, write "none". Task 5 then drops Record New Episodes for Tvheadend.
  - Whether `/comet/poll` returns an `accessUpdate` message with a `dvr` field for a non-admin user without DVR rights. Test this with a second user.
  - Every `sched_status` value seen in `dvr/entry/grid`.
  - The `/playlist/ticket/...` reply: whether the stream line is absolute, and the URL shape.
- [ ] **Step 5: Verify:** every fixture parses with `python3 -I -m json.tool <file>` (except the `.m3u`), and `grep -ri "rivulet:\|password" RivuletTests/Fixtures/Tvheadend` finds nothing.

---

### Task 2: Credentials on BoundedDownload

**Files:**
- Modify: `RivuletCore/IPTV/BoundedDownload.swift`
- Test: `RivuletTests/Unit/LiveTV/BoundedDownloadCredentialTests.swift`

**Interfaces:**
- Produces: `BoundedDownload.data(for: URLRequest, limit: Int, configuration: URLSessionConfiguration = .default, credential: URLCredential? = nil) async throws -> (Data, URLResponse)`

- [ ] **Step 1: Write failing test** `test_noCredential_401_returnsResponse`: a `MockURLProtocol` 401 for `http://tvh.test/api/serverinfo` comes back as a response with `statusCode == 401` and no thrown error, both with `credential: nil` and with a credential.
- [ ] **Step 2: Run it.** Expected: compile failure (no `credential:` parameter).
- [ ] **Step 3: Implement.** `Loader` takes the credential and implements `urlSession(_:task:didReceive:completionHandler:)`. For `NSURLAuthenticationMethodHTTPBasic` and `NSURLAuthenticationMethodHTTPDigest`, when `credential != nil && challenge.previousFailureCount == 0`, call `.useCredential`. Otherwise call `.performDefaultHandling`, so a wrong login comes back as its 401. Any other method also gets `.performDefaultHandling`.
- [ ] **Step 4: Run** `-only-testing:RivuletTests/BoundedDownloadCredentialTests`, and also `XtreamServiceTests` and `IPTVGuideMatchTests` for regressions. Expected: PASS. (Digest itself is proven against the real server in Task 9.)

---

### Task 3: TvheadendService (connection, channels, guide, streams)

**Files:**
- Create: `RivuletCore/IPTV/TvheadendService.swift`
- Test: `RivuletTests/Unit/LiveTV/TvheadendServiceTests.swift` (header comment = Task 1 measurements)

**Interfaces:**
- Consumes: `BoundedDownload.data(... credential:)` (Task 2), Task 1 fixtures.
- Produces:
```swift
struct TvheadendAccount: Sendable, Equatable { let server: URL; let username: String?; let password: String? }
// nil username = anonymous. `credential: URLCredential?` computed, .forSession.
enum TvheadendError: Error, Equatable { case loginRequired, invalidLogin, forbidden, notTvheadend, noTicket, httpError(Int) }
struct TvheadendChannel: Sendable, Equatable { let uuid: String; let name: String; let number: Int?; let iconURL: URL?; let group: String? }
struct TvheadendEvent: Sendable, Equatable { let eventId: Int; let channelUUID: String; let start: Date; let stop: Date
    let title: String; let subtitle: String?; let description: String?; let episode: String?; let seriesLink: String? }
actor TvheadendService {
    let account: TvheadendAccount
    init(account: TvheadendAccount, session: URLSession? = nil)
    func verify() async throws                       // GET api/serverinfo, else .notTvheadend
    func fetchChannels() async throws -> [TvheadendChannel]   // channel/grid?limit=10000 + channeltag/grid?limit=1000
    func fetchEvents() async throws -> [TvheadendEvent]       // epg/events/grid?limit=50000, guideLimit
    nonisolated func streamURL(channelUUID: String) -> URL     // <base>/stream/channel/<uuid>?profile=pass
    func ticketedStreamURL(channelUUID: String) async throws -> URL  // playlist/ticket/channel/<uuid>
    nonisolated static func parse(_ data: Data, status: Int) throws -> Any
    nonisolated static func channels(from grid: Any, tags: Any?, server: URL) -> [TvheadendChannel]
    nonisolated static func events(from grid: Any) -> [TvheadendEvent]
    nonisolated static func ticketURL(fromPlaylist data: Data, server: URL) -> URL?
}
```

Status mapping in `parse`: 401 → `loginRequired` when `account.username == nil`, otherwise `invalidLogin`. 403 → `forbidden`. Any other non-2xx → `httpError`. A 2xx that is not a JSON object → `notTvheadend`. `verify` also throws `notTvheadend` when the object lacks `sw_version`. A channel's group is the name of its first non-internal tag. Icon: `icon` if it is an absolute http(s) URL, else `<base>/<icon_public_url>`, else nil. Read field names from the fixtures, which win over this plan.

- [ ] **Step 1: Write failing tests:**
  - `test_verify_serverinfo_passes`
  - `test_verify_htmlPage_isNotTvheadend`
  - `test_401_anonymous_isLoginRequired_signedIn_isInvalidLogin`
  - `test_403_isForbidden`
  - `test_channels_skipDisabled_keepMissingNumberAndIcon` (counts and fields against `channel_grid.json`)
  - `test_channels_groupFromFirstTag`
  - `test_channels_iconPrefersAbsoluteThenImagecache`
  - `test_events_mapTimesAndOptionalFields` (`start`/`stop` epoch seconds → `Date`, missing subtitle → nil)
  - `test_streamURL_isPassProfile`: `streamURL(channelUUID: "abc").absoluteString == "http://tvh.test:9981/stream/channel/abc?profile=pass"`
  - `test_ticketURL_fromPlaylist`
  - `test_ticketedStreamURL_fetchesEveryTime`: two calls make two requests in `MockURLProtocol.requestHistory`
  - `test_ticket_emptyPlaylist_isNoTicket`
  - `test_password_neverInAnyRequestURL`: account password `p/ss+w@rd?:x`; after verify, channels, events and a ticket, no `requestHistory` URL contains `p/ss` or `w@rd`
- [ ] **Step 2: Run** `-only-testing:RivuletTests/TvheadendServiceTests`. Expected: compile failure.
- [ ] **Step 3: Implement** `TvheadendService.swift` to the interface above. Copy XtreamService's session setup and its rule of walking replies by hand.
- [ ] **Step 4: Run it again.** Expected: PASS.

---

### Task 4: Tvheadend as a Live TV source

**Files:**
- Modify: `RivuletCore/LiveTV/LiveTVProvider.swift` (enum case, `displayName` "Tvheadend", icon `"tv"`)
- Modify: `RivuletCore/LiveTV/IPTVProvider.swift`
- Modify: `RivuletCore/LiveTV/LiveTVDataStore.swift` (add, id, save/load `"tvheadend"`)
- Modify: `RivuletCore/LiveTV/LiveTVSourceConnector.swift`
- Test: `RivuletTests/Unit/LiveTV/TvheadendSourceTests.swift`

**Interfaces:**
- Consumes: Task 3 types.
- Produces:
```swift
// IPTVProvider
let tvheadendService: TvheadendService?
init(tvheadend account: TvheadendAccount, sourceId: String, displayName: String, canRecord: Bool? = nil)
nonisolated var tvheadendAccount: TvheadendAccount? { get }
nonisolated let tvheadendCanRecord: Bool?   // persisted as SourceConfiguration.canRecord; set by Task 5
func resolveStreamURL(for channel: UnifiedChannel) async throws -> URL?
// LiveTVDataStore
func addTvheadendSource(account: TvheadendAccount, name: String, canRecord: Bool? = nil) async
static func tvheadendSourceId(for account: TvheadendAccount) -> String   // "tvheadend:" + 8-byte SHA256 hex of lowercased server + "\n" + (username ?? "")
// LiveTVSourceConnector
struct TvheadendRequest { let account: TvheadendAccount; let service: TvheadendService }
static let defaultTvheadendName = "Tvheadend"
func tvheadendRequest(address: String, username: String, password: String) throws -> TvheadendRequest
func connect(_ request: TvheadendRequest, name: String) async throws
static func tvheadendFailureCopy(for error: Error) -> String
```

Behavior:
- **Channels:** `refreshChannels` maps each `TvheadendChannel` to `M3UParser.ParsedChannel`, with `tvgId: uuid`, `key: "tvh\(uuid)"`, `streamURL: service.streamURL(channelUUID:)`. The existing occurrence/candidates pipeline runs unchanged.
- **Guide:** `fetchEPG` takes a Tvheadend branch before the `epgURL` guard. Events are grouped by the channel whose `tvgId == channelUUID`, which drops unknown channels. Each becomes a `UnifiedProgram` with `id "\(channelId):\(Int(start))"`, `sourceGuid: String(eventId)`, `episodeNumber: episode`, and `isMovie: false`. Caching is the same as the XMLTV path.
- **Playback:** `resolveStreamURL` returns `ticketedStreamURL(channelUUID: channel.tvgId)` when the account has a username, `channel.streamURL` otherwise, and the protocol default for non-Tvheadend sources. `isConnected` calls `verify()`.
- **Saving:** `SourceConfiguration` gets type `"tvheadend"`, `baseURL`, and `username` (nil = anonymous). The password goes in the Keychain under `apiTokenKey`, via `storeAPIToken`. `removeSource` already deletes that key.
- **Connecting:** verify, then fetch channels (an empty list gives "Connected, but found no channels."). If signed in, `ticketedStreamURL` for the first channel; a failure there blocks the add. Then add, then `load`.
- **Form check:** an empty address gives "Enter your server's address first." A username without a password, or a password without a username, gives "Enter both your username and password, or neither." The address goes through `sanitizeURL`.
- **Copy** (exact):
  - `loginRequired`: "This Tvheadend server needs a username and password."
  - `invalidLogin`: "Tvheadend didn't accept that username and password."
  - `forbidden`: "This Tvheadend user isn't allowed to stream. Check its rights in Tvheadend."
  - `notTvheadend`: "That address isn't a Tvheadend server. Check the address and port."
  - `noTicket`: "Tvheadend didn't give Rivulet a stream for this user. Check its streaming rights, or update Tvheadend."
  - Anything else: `failureCopy(for:)`.

- [ ] **Step 1: Write failing tests:**
  - `test_tvheadendSourceId_stableAndPerUser`
  - `test_saveLoad_roundTrip_keepsUsernamePasswordInKeychain` (follow how existing store tests isolate `UserDefaults`; if there are none, test `SourceConfiguration` encoding plus `tvheadendSourceId` only)
  - `test_refreshChannels_mapsUUIDToTvgIdAndPassStream`
  - `test_fetchEPG_groupsByChannelUUID_setsSourceGuid`
  - `test_resolveStreamURL_anonymousUsesChannelURL_signedInFetchesTicket`
  - `test_request_formChecks`
  - `test_connect_emptyChannels`, `test_connect_ticketFailureBlocksAdd`
  - `test_failureCopy_eachError`
- [ ] **Step 2: Run** `-only-testing:RivuletTests/TvheadendSourceTests`. Expected: compile failure.
- [ ] **Step 3: Implement.** Add the enum case first and let the compiler find every `switch` (`saveSources`, `LiveTVSourceType` properties, anything in `Rivulet/` or `RivuletiOS/`).
- [ ] **Step 4: Run** `TvheadendSourceTests`, `LiveTVSourceConnectorTests` and `IPTVGuideMatchTests`. Expected: PASS.

---

### Task 5: Tvheadend recording

**Files:**
- Create: `RivuletCore/IPTV/TvheadendService+DVR.swift`
- Create: `RivuletCore/LiveTV/IPTVProvider+TvheadendDVR.swift`
- Modify: `RivuletCore/LiveTV/IPTVProvider+DVR.swift` (`supportsRecording` and each requirement branch to the Tvheadend implementation when `tvheadendService != nil`)
- Modify: `RivuletCore/LiveTV/LiveTVSourceConnector.swift`, `RivuletCore/LiveTV/LiveTVDataStore.swift` (`canRecord` at connect, persisted)
- Test: `RivuletTests/Unit/LiveTV/TvheadendDVRTests.swift`

**Interfaces:**
- Consumes: `TvheadendService`, `TvheadendEvent`, `UnifiedProgram.sourceGuid` (= eventId), `UnifiedChannel.tvgId` (= channel uuid).
- Produces:
```swift
struct TvheadendRecording: Sendable, Equatable { let uuid: String; let title: String; let subtitle: String?; let start: Date; let stop: Date
    let channelUUID: String?; let channelName: String?; let eventId: Int?; let autorecUUID: String?; let status: LiveTVScheduledRecording.Status }
struct TvheadendRule: Sendable, Equatable { let uuid: String; let title: String; let channelName: String? }
extension TvheadendService {
    func recordEvent(eventId: Int) async throws                                 // POST api/dvr/entry/create_by_event event_id, config_uuid ""
    func recordSeries(eventId: Int, seriesLink: String?, title: String, channelUUID: String, newOnly: Bool) async throws
    func recordings() async throws -> [TvheadendRecording]                      // api/dvr/entry/grid?limit=1000
    func rules() async throws -> [TvheadendRule]                                // api/dvr/autorec/grid?limit=1000
    func cancel(recordingUUID: String) async throws                             // api/dvr/entry/cancel uuid
    func deleteRule(uuid: String) async throws                                  // api/idnode/delete uuid
    func canRecord() async -> Bool?                                             // nil when unmeasurable (Task 1)
    nonisolated static func titleRuleConf(title: String, channelUUID: String, newOnly: Bool) -> [String: Any]
    nonisolated static func recordings(from grid: Any) -> [TvheadendRecording]
    nonisolated static func status(_ schedStatus: String) -> LiveTVScheduledRecording.Status
}
```

Behavior:
- **Requests:** POSTs are `application/x-www-form-urlencoded`. A 403 on any DVR call becomes the error "This Tvheadend user can't record."
- **Series rule:** with a series link and `newOnly == false`, call `autorec/create_by_series`. Otherwise call `autorec/create`, passing `conf` = `titleRuleConf` and `config_uuid` "". The `conf` title is `"^" + NSRegularExpression.escapedPattern(for: title) + "$"`, plus `channel`, `enabled: 1`, `comment: "Rivulet"`, and `record` set to the Task 1 "new only" value when `newOnly` (else 0).
- **Record options:** Record, Record Series, and Record New Episodes (the last only if Task 1 found a value), all with the same id scheme as Dispatcharr (`"\(program.id)#once|#all|#new"`). They need `program.sourceGuid` to be an Int and `program.endTime > now`; otherwise throw `LiveTVRecordingError.noGuideIdentity` or `.programEnded`.
- **Scheduled list:** each entry maps to `LiveTVScheduledRecording`: `programGuid = eventId` string, `ruleId = autorecUUID`, `ruleIsSeries = autorecUUID != nil`, and `channelId` resolved through the provider's channels by uuid. Status values come from the Task 1 list: scheduled → `.scheduled`, recording → `.recording`, a completed with no error → `.completed`, anything with error, missed or failed → `.failed`.
- **`supportsRecording`:** a Tvheadend account with a username, AND `tvheadendCanRecord != false`. This task also edits `connect(_ TvheadendRequest, name:)` to call `canRecord()` when signed in and pass the result to `addTvheadendSource(..., canRecord:)`. `SourceConfiguration` gains an optional `canRecord: Bool?`; older configs decode it as nil.

- [ ] **Step 1: Write failing tests:**
  - `test_titleRule_escapesRegex`: title "Who Wants to Be a Millionaire?" gives `conf["title"] == "^Who Wants to Be a Millionaire\\?$"`
  - `test_recordSeries_usesSeriesLinkWhenPresent_elseTitleRule`
  - `test_recordOptions_needEventIdAndFutureEnd`
  - `test_recordOptions_newEpisodesOnlyWhenMeasured`
  - `test_recordings_mapStatusRuleAndGuid` (against `dvr_entry_grid.json`)
  - `test_status_eachMeasuredValue`
  - `test_dvr403_isCantRecord`
  - `test_supportsRecording_anonymousFalse_signedInTrue_storedFalseWins`
- [ ] **Step 2: Run** `-only-testing:RivuletTests/TvheadendDVRTests`. Expected: compile failure.
- [ ] **Step 3: Implement** to the interfaces above.
- [ ] **Step 4: Run** `TvheadendDVRTests` and `DispatcharrDVRTests`. Expected: PASS.

---

### Task 6: Per-app server defaults and Threadfin

**Files:**
- Modify: `RivuletCore/LiveTV/LiveTVSourceConnector.swift`
- Modify: `RivuletTests/Unit/LiveTV/LiveTVSourceConnectorTests.swift` (replace the `serverSuggestions` assertion at line 167)

**Interfaces:**
- Produces:
```swift
enum LiveTVServerApp: CaseIterable { case dispatcharr, tvheadend, threadfin
    var defaultPort: Int { get } }                       // 9191, 9981, 34400
static func defaultAddress(for app: LiveTVServerApp, host: String = suggestedHost) -> String  // "http://<host>:<port>"
static let defaultThreadfinName = "Threadfin"
static func threadfinRequest(address: String) throws -> PlaylistRequest
// m3u <base>/m3u/threadfin.m3u, epg <base>/xmltv/threadfin.xml; base = sanitizeURL(address) with path kept
```
- Removes: `serverSuggestions(host:)`.

- [ ] **Step 1: Write failing tests:**
  - `test_defaultAddress_perApp`: `defaultAddress(for: .tvheadend, host: "h") == "http://h:9981"`
  - `test_threadfinRequest_buildsBothURLs`: `"10.0.0.5:34400/"` gives `http://10.0.0.5:34400/m3u/threadfin.m3u` and `.../xmltv/threadfin.xml`
  - `test_threadfinRequest_emptyAddress` throws "Enter your server's address first."
- [ ] **Step 2: Run** `-only-testing:RivuletTests/LiveTVSourceConnectorTests`. Expected: FAIL.
- [ ] **Step 3: Implement.** Delete `serverSuggestions`. Its two call sites are fixed in Tasks 7 and 8; until then the app target won't compile.
- [ ] **Step 4: Run** after Task 7, since the tvOS test target needs `AddLiveTVSourceContent.swift` to compile.

---

### Task 7: tvOS add-source pages

**Files:**
- Modify: `Rivulet/Views/Settings/UIKit/AddLiveTVSourceContent.swift`
- Modify: `Rivulet/Views/Settings/SettingsModels.swift:53,76-78` (`addOwnServer` → `addDispatcharr`, `addTvheadend`, `addThreadfin`; titles "Dispatcharr", "Tvheadend", "Threadfin")
- Modify: `Rivulet/Views/Settings/UIKit/SettingsPageModels.swift:205-207`
- Modify: `Rivulet/Views/Settings/SettingsDescriptors.swift` (row descriptors near line 383, icons near 562)
- Modify: `RivuletTests/Unit/SettingsFormFailurePopupTests.swift:67,72` (`.addOwnServer` → `.addDispatcharr`)

**Interfaces:**
- Consumes: Task 4 `tvheadendRequest` / `connect`, Task 6 `defaultAddress` / `threadfinRequest`.

Behavior:
- **Picker** (`addLiveTVSource`): `.header("Your Server")`, Dispatcharr, Tvheadend, Threadfin, `.header("Provider")`, Xtream Codes, Playlist URL. Row ids are `addDispatcharr`, `addTvheadend`, `addThreadfin`; the other two keep theirs. App rows have no trailing value, since the title is the app. The provider rows keep "Provider login" and "M3U link".
- **Address prefill:** `beginDraft` takes an optional `LiveTVServerApp` and sets `draft.serverURL = defaultAddress(for:)`.
- **Dispatcharr form:** today's `ownServerSteps` without `suggestions:`; its message says "Enter your Dispatcharr server's address, with its port."
- **Tvheadend form:** Server Address (Required), Username and Password (Optional; message: "Only needed if your server asks for a login, and to record. Leave both empty to just watch."), Name (fallback `defaultTvheadendName`), Add Source.
- **Threadfin form:** Server Address (Required), Name (fallback `defaultThreadfinName`), Add Source. It saves through `connect(PlaylistRequest, name:)`.
- **Descriptors:** one per new row and field id. Tvheadend fields use their own ids (`tvhServerField`, `tvhUsernameField`, `tvhPasswordField`) so their descriptors can name Tvheadend. Delete the `addOwnServer` descriptor and its "xTeVe or ErsatzTV" copy.

- [ ] **Step 1: Write failing test** `test_picker_rowsAndHeadersInOrder` in `SettingsFormFailurePopupTests` (or a new `AddLiveTVSourcePickerTests`): `SettingsContent.rows(for: .addLiveTVSource).map(\.id) == ["hdr_Your Server", "addDispatcharr", "addTvheadend", "addThreadfin", "hdr_Provider", "addXtream", "addPlaylistURL"]`. Add `test_tvheadendForm_fieldIds` and `test_threadfinForm_fieldIds`.
- [ ] **Step 2: Run them.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** `SettingsFormFailurePopupTests`, the picker tests and `LiveTVSourceConnectorTests`. Expected: PASS. Then `swiftlint lint --strict`: no violations.
- [ ] **Step 5: Check in the simulator.** Every row opens its form. Selecting a text row opens the keyboard directly. Menu goes back. The description panel follows focus. The setup landing's Live TV card shows the new picker. Treat focus checks done only in the simulator as provisional.

---

### Task 8: iOS add-source sheet

**Files:**
- Modify: `RivuletiOS/Settings/IOSLiveTVSettingsView.swift:160-300`

Behavior:
- **Sheet layout:** `IOSLiveAddSourceSheet` gets two `Section`s, "Your Server" (Dispatcharr, Tvheadend, Threadfin) and "Provider" (Xtream Codes, Playlist URL). Icons: `antenna.radiowaves.left.and.right`, `tv`, `server.rack`; the provider rows keep theirs.
- **Dispatcharr form:** `IOSLiveServerForm` becomes `IOSLiveDispatcharrForm`. The suggestions `Menu` is removed, the address starts as `defaultAddress(for: .dispatcharr)`, and the title is "Dispatcharr".
- **New forms:** `IOSLiveTvheadendForm` (Address, then a Sign-In section with Username and Password, then Name) and `IOSLiveThreadfinForm` (Address, Name). Both call the Task 4 and Task 6 connector APIs, using the same add/fail pattern as the existing forms.

- [ ] **Step 1: Build iOS:** `xcodebuild build -scheme "Rivulet iOS" -destination 'generic/platform=iOS Simulator' -derivedDataPath /private/tmp/claude-501/rivulet-dd-ios`. Expected: BUILD SUCCEEDED.
- [ ] **Step 2: Check in the iOS simulator:** each row opens its form and the address is prefilled. Then add the Task 1 Tvheadend server signed in and play a channel.

---

### Task 9: End-to-end on the real server, then the one commit

- [ ] **Step 1: Run the full suite:** `xcodebuild test -scheme Rivulet -destination 'platform=tvOS Simulator,name=Apple TV' -derivedDataPath /private/tmp/claude-501/rivulet-dd`. Expected: no new failures against `main` (compare with the known environment failures noted in memory).
- [ ] **Step 2: Test against the Task 1 Tvheadend in the tvOS simulator:**
  - Add it signed in. Channels, groups, logos and the guide show.
  - A channel plays. Stop it, wait at least 6 minutes, and play it again: it still plays.
  - Multiview runs two Tvheadend tiles.
  - Wrong password gives the `invalidLogin` copy. Removing the login on a server that requires one gives the `loginRequired` copy.
  - Turn anonymous streaming on, then add the server with no login. It plays, and no Record options show.
- [ ] **Step 3: Recording, signed in:**
  - Record one airing from the guide. It appears in the Tvheadend web UI and in Rivulet's scheduled list.
  - Record Series on a title with a `?` in it. The autorec title regex is escaped in the web UI.
  - Cancel the single airing.
  - Delete the series rule. Its timers are gone.
  - Repeat with the user who has no DVR right: no Record options show, or the "can't record" copy appears, depending on what Task 1 measured.
- [ ] **Step 4: Threadfin.** Point the Threadfin form at a Threadfin instance, or at a static server that answers the two paths with Task 1's M3U and XMLTV. Channels and guide load.
- [ ] **Step 5: Saved sources are untouched.** An existing Dispatcharr source, saved before this change, still loads after relaunch.
- [ ] **Step 6: Changelog** (`rivulet-changelog` skill). Add one tvOS bullet and one iOS bullet, along the lines of "Add Live TV sources by app: Dispatcharr, Tvheadend and Threadfin each have their own sign-in. Tvheadend can record."
- [ ] **Step 7: Review the full diff,** then make one commit: `git add -f` the spec and plan, plus all code and fixtures. Message: "Live TV: one add-source row per app, Tvheadend support (#415)". Do not push.
