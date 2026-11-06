// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
@testable import Rivulet

@MainActor
final class SiloSubtitleActionsTests: XCTestCase {
    func testUnavailableOrDeniedServerCapabilitiesDoNotExposeActions() {
        for state in ["disabled", "not_configured", "unsupported"] {
            let search = SiloSubtitleProviderStatus(enabled: true, providers: ["opensubtitles"], allowed: true, state: state)
            let ai = SiloSubtitleAIStatus(enabled: true, transcribeEnabled: true, allowed: true, state: state)
            XCTAssertFalse(search.canSearch, state)
            XCTAssertFalse(ai.canTranslate, state)
            XCTAssertFalse(ai.canTranscribe, state)
        }
        let denied = SiloSubtitleAIStatus(enabled: true, transcribeEnabled: true, allowed: false, state: "available")
        XCTAssertFalse(denied.canTranslate)
        XCTAssertFalse(denied.canTranscribe)
        let transcription = SiloSubtitleAIStatus(enabled: false, transcribeEnabled: true, allowed: true, state: "available")
        XCTAssertTrue(transcription.canTranscribe)
        XCTAssertFalse(transcription.canTranslate)
        let translation = SiloSubtitleAIStatus(enabled: true, transcribeEnabled: false, allowed: true, state: "available")
        XCTAssertTrue(translation.canTranslate)
        XCTAssertFalse(translation.canTranscribe)
    }

    func testTranslationEligibilityAndRequestIdentityUseTheActualTextSource() {
        func track(_ index: Int, codec: String, language: String) -> SubtitleTrack {
            SubtitleTrack(id: "file:158:subtitle:\(index)", index: index, codec: codec, language: language,
                          title: nil, extendedTitle: nil, isDefault: false, isForced: false, isHearingImpaired: false,
                          isEmbedded: true, externalURL: nil, isSelected: false, nativeStreamIndex: index + 14)
        }
        let source = MediaSource(id: "158", container: "mkv", duration: 600, bitrate: nil, fileSize: nil,
                                 fileName: nil, videoResolution: nil, videoTracks: [], audioTracks: [], subtitleTracks: [
                                    track(16, codec: "subrip", language: "eng"),
                                    track(17, codec: "hdmv_pgs_subtitle", language: "eng"),
                                    track(18, codec: "ass", language: "nld"),
                                    track(19, codec: "unknown", language: "eng")
                                 ], streamKind: .directPlay, streamURL: nil)
        let enabled = SiloSubtitleAIStatus(enabled: true, transcribeEnabled: false, allowed: true, state: "available")
        let options = enabled.generationOptions(for: source, targetLanguage: "nl")
        XCTAssertEqual(options.map(\.kind), [.translate])
        XCTAssertEqual(options.map(\.sourceIndex), [16], "the FFmpeg index is not a Silo AI source ordinal")
        XCTAssertEqual(options.map(\.targetLanguage), ["nl"])
        let disabled = SiloSubtitleAIStatus(enabled: false, transcribeEnabled: false, allowed: true, state: "available")
        XCTAssertTrue(disabled.generationOptions(for: source, targetLanguage: "nl").isEmpty)
    }

    func testOnlyPendingAndRunningJobsContinuePollingOrOfferCancellation() throws {
        for status in ["pending", "running", "completed", "failed", "cancelled", "unrecognized"] {
            let json = """
            {"id":"90071992547409931234","media_file_id":"158","kind":"translate","status":"\(status)",
             "progress":0.5,"progress_message":null,"result_subtitle_id":null,"error_message":null,
             "source_language":"en","target_language":"nl"}
            """
            let job = try SiloJSON.decoder().decode(SiloSubtitleAIJob.self, from: Data(json.utf8))
            let active = status == "pending" || status == "running"
            XCTAssertEqual(job.isActive, active, status)
            XCTAssertEqual(PlayerSubtitleOperation.job(job).cancellableJobID != nil, active, status)
        }
    }

    func testSyncCapabilitiesAndInventoryNeverInventTargets() throws {
        let key = "external-" + String(repeating: "a", count: 64)
        func inventory(source: String, syncKey: String?) throws -> SiloPlanSubtitleTrack {
            let keyField = syncKey.map { #","sync_key":"\#($0)""# } ?? ""
            let json = """
            {"track_id":"opaque:selection","combined_index":9,"source":"\(source)",
             "codec":"srt","label":"English.srt","forced":false,"default":false,
             "hearing_impaired":false,"delivery":"sidecar",
             "url":"/stream/subtitle.srt?external_key=not-a-sync-key\(source == "downloaded" ? "&downloaded_subtitle_id=90071992547409931234" : "")"\(keyField)}
            """
            return try SiloJSON.decoder().decode(SiloPlanSubtitleTrack.self, from: Data(json.utf8))
        }
        let target = SiloSubtitleSyncTarget(fileID: "158", key: key)
        XCTAssertEqual(try inventory(source: "external", syncKey: key).syncTarget(fileID: "158"), target)
        XCTAssertNil(try inventory(source: "external", syncKey: nil).syncTarget(fileID: "158"))
        XCTAssertNil(try inventory(source: "external", syncKey: "").syncTarget(fileID: "158"))
        XCTAssertNil(try inventory(source: "embedded", syncKey: key).syncTarget(fileID: "158"))
        XCTAssertNil(try inventory(source: "future", syncKey: key).syncTarget(fileID: "158"))
        XCTAssertEqual(try inventory(source: "downloaded", syncKey: "stored-90071992547409931234").storedSubtitleID,
                       "90071992547409931234")
        XCTAssertNil(try inventory(source: "external", syncKey: key).storedSubtitleID)

        let state = try SiloJSON.decoder().decode(SiloSubtitleSyncState.self, from: Data(syncState(key: key).utf8))
        for status in ["disabled", "not_configured", "unsupported", "future"] {
            XCTAssertFalse(SiloSubtitleSyncStatus(revision: "1", state: status, allowed: true,
                                                  autoSync: true, external: true).canSync(state))
        }
        XCTAssertFalse(SiloSubtitleSyncStatus(revision: "1", state: "available", allowed: false,
                                              autoSync: true, external: true).canSync(state))
        XCTAssertFalse(SiloSubtitleSyncStatus(revision: "1", state: "available", allowed: true,
                                              autoSync: true, external: nil).isAvailable)
        XCTAssertFalse(SiloSubtitleSyncStatus(revision: "1", state: "available", allowed: true,
                                              autoSync: true, external: false).canSync(state))
        XCTAssertTrue(SiloSubtitleSyncStatus(revision: "1", state: "available", allowed: true,
                                             autoSync: false, external: true).canSync(state))
    }

    func testSyncJobsRetainProgressOutcomeAndOpaqueIdentifiers() throws {
        for status in ["pending", "running", "synced", "already_synced", "no_match", "failed", "future"] {
            let json = """
            {"id":"90071992547409931234","status":"\(status)","trigger":"auto",
             "phase":"analyzing","progress":0.42,"failure":"subtitle_changed","confidence":0.91,
             "result":{"offset_ms":-1500,"scale":1.001},"created_at":"2026-10-01T12:00:00.000Z",
             "finished_at":null}
            """
            let job = try SiloJSON.decoder().decode(SiloSubtitleSyncJob.self, from: Data(json.utf8))
            XCTAssertEqual(job.isActive, status == "pending" || status == "running")
            XCTAssertEqual(job.id, "90071992547409931234")
            XCTAssertEqual(job.progress, 0.42)
            XCTAssertEqual(job.phase, "analyzing")
            XCTAssertEqual(job.failure, "subtitle_changed")
            XCTAssertEqual(job.confidence, 0.91)
            XCTAssertEqual(job.result, SiloSubtitleTiming(offsetMs: -1500, scale: 1.001))
            XCTAssertNil(job.subtitleId)
            XCTAssertNil(job.finishedAt)
        }
    }

    func testKeyedSyncUsesNativeRoutesCapturedAuthorityAndExactResetValidator() async throws {
        let target = SiloSubtitleSyncTarget(fileID: "158", key: "external-" + String(repeating: "a", count: 64))
        let state = syncState(key: target.key)
        let envelope = #"{"subtitle":\#(state)}"#
        let server = SiloSubtitleSyncFixture([
            .init(body: #"{"revision":"1","state":"available","allowed":true,"auto_sync":true,"external":true}"#),
            .init(body: envelope, entityTag: #""viewer-timing-7""#),
            .init(status: 202, body: #"{"subtitle":\#(syncState(key: target.key, job: true))}"#),
            .init(body: envelope, entityTag: #""viewer-timing-9""#),
            .init(body: envelope, entityTag: #""viewer-timing-10""#)
        ])
        let provider = syncProvider(server)
        let status = try await provider.subtitleSyncStatus()
        XCTAssertTrue(status.autoSync)
        let read = try await provider.subtitleSyncState(target: target)
        XCTAssertEqual(read.entityTag, #""viewer-timing-7""#)
        XCTAssertEqual(read.subtitle.timing.offsetMs, -1500, "metadata is not a second client-side correction")
        let started = try await provider.startSubtitleSync(target: target)
        XCTAssertTrue(started.sync?.isActive == true)
        let reset = try await provider.resetSubtitleTiming(target: target)
        XCTAssertEqual(reset.entityTag, #""viewer-timing-10""#)
        let requests = await server.requests()
        let root = "/proxy/silo/api/v2/subtitles"
        let keyed = root + "/158/sync/" + target.key
        XCTAssertEqual(requests.map { $0.httpMethod ?? "" }, ["GET", "GET", "POST", "GET", "PUT"])
        XCTAssertEqual(requests.map { $0.url!.path }, [root + "/sync/status", keyed, keyed, keyed, keyed + "/timing"])
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "If-Match"), #""viewer-timing-9""#)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Profile-Id") == "profile-a" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Profile-Token") == "pin-a" })
        let body = try XCTUnwrap(requests.last?.httpBody)
        let timing = try SiloJSON.decoder().decode(SiloSubtitleTiming.self, from: body)
        XCTAssertEqual(timing, .identity)
    }

    func testResetRefusesMissingValidatorOrMismatchedTargetBeforeWriting() async {
        let target = SiloSubtitleSyncTarget(fileID: "158", key: "stored-5")
        for wrongTarget in [false, true] {
            let state = syncState(key: wrongTarget ? "stored-6" : target.key)
            let server = SiloSubtitleSyncFixture([.init(body: #"{"subtitle":\#(state)}"#,
                                                       entityTag: wrongTarget ? #""timing-1""# : nil)])
            do {
                _ = try await syncProvider(server).resetSubtitleTiming(target: target)
                XCTFail("No write is authorized by an absent validator or another target.")
            } catch {}
            let requests = await server.requests()
            XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
        }
    }

    func testResetDoesNotReplaceWeakOrWildcardValidatorsWithInventedPreconditions() async {
        let target = SiloSubtitleSyncTarget(fileID: "158", key: "stored-5")
        for validator in ["", "*", #"W/"timing-1""#] {
            let server = SiloSubtitleSyncFixture([
                .init(body: #"{"subtitle":\#(syncState(key: target.key))}"#, entityTag: validator)
            ])
            do {
                _ = try await syncProvider(server).resetSubtitleTiming(target: target)
                XCTFail("A reset requires the exact strong read validator.")
            } catch {}
            let requests = await server.requests()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testSyncMutationsNeverReplayOrFallBackOnFailure() async {
        let target = SiloSubtitleSyncTarget(fileID: "158", key: "stored-5")
        let envelope = #"{"subtitle":\#(syncState(key: target.key))}"#
        for code in [401, 403, 404, 412, 422, 428, 503] {
            for reset in [false, true] {
                let failure = SiloAuthTestServer.problem(status: code, code: "refused", detail: "Not available.")
                let replies: [SiloSubtitleSyncFixture.Reply] = reset
                    ? [.init(body: envelope, entityTag: #""exact-validator""#), .init(status: code, body: failure)]
                    : [.init(status: code, body: failure)]
                let server = SiloSubtitleSyncFixture(replies)
                do {
                    if reset { _ = try await syncProvider(server).resetSubtitleTiming(target: target) }
                    else { _ = try await syncProvider(server).startSubtitleSync(target: target) }
                    XCTFail("The native error must reach the caller.")
                } catch { XCTAssertEqual((error as? SiloAPIError)?.status, code) }
                let requests = await server.requests()
                XCTAssertEqual(requests.count, reset ? 2 : 1)
                XCTAssertEqual(requests.last?.httpMethod, reset ? "PUT" : "POST")
                XCTAssertFalse(requests.contains { $0.url!.path.contains("/stored/") })
            }
        }
    }

    func testSyncIdentitySurvivesSelectedArtifactProjectionWithoutRetimingIt() async throws {
        let key = "external-" + String(repeating: "a", count: 64)
        let json = """
        {"protocol_version":3,"plan_id":"plan-a","plan_attempt_key":"attempt-a",
         "session_id":"session-a","delivery":"original_http","effective_media_file_id":"158",
         "stream":{"url":"/stream/session-a","protocol":"http_progressive","container":"mkv",
                   "headers":{},"header_refresh":"none"},
         "timeline":{"source_start_seconds":0,"stream_origin_seconds":0,"player_start_seconds":0,
                     "timeline_offset_seconds":0,"can_seek_anywhere":true,"seek_restoration":"player_position"},
         "source":{"media_file_id":"158","duration_seconds":600},
         "selected_tracks":{"subtitle":{"id":"opaque:external","index":8}},
         "subtitle":{"mode":"render","track_id":"opaque:external",
          "artifact":{"url":"/stream/session-a/subtitle/8.vtt","mime_type":"text/vtt",
                      "format":"vtt","timing_origin_seconds":0},
          "inventory":[
           {"track_id":"opaque:external","combined_index":8,"source":"external","codec":"srt",
            "forced":false,"default":false,"hearing_impaired":false,"delivery":"sidecar",
            "url":"/stream/session-a/subtitle/8.vtt","sync_key":"\(key)"},
           {"track_id":"opaque:stored","combined_index":11,"source":"downloaded","codec":"srt",
            "forced":false,"default":false,"hearing_impaired":false,"delivery":"sidecar",
            "url":"/stream/session-a/subtitle/11.vtt?downloaded_subtitle_id=90071992547409931234",
            "sync_key":"stored-90071992547409931234"},
           {"track_id":"opaque:embedded","combined_index":13,"source":"embedded","codec":"srt",
            "forced":false,"default":false,"hearing_impaired":false,"delivery":"sidecar",
            "sync_key":"\(key)"}]}}
        """
        let plan = try SiloJSON.decoder().decode(SiloPlaybackPlan.self, from: Data(json.utf8))
        let provider = syncProvider(SiloSubtitleSyncFixture([]))
        let relay = try await SiloMediaRelay.start(client: provider.client)
        defer { relay.stop() }
        let tracks = try provider.planSubtitles(plan, relay: relay)
        XCTAssertEqual(tracks.map(\.id), ["opaque:external", "opaque:stored", "opaque:embedded"])
        XCTAssertEqual(tracks[0].siloSyncTarget, SiloSubtitleSyncTarget(fileID: "158", key: key))
        XCTAssertEqual(tracks[0].codec, "vtt", "selected delivery keeps the server's corrected artifact format")
        XCTAssertNotNil(tracks[0].externalURL)
        XCTAssertEqual(tracks[1].siloSyncTarget?.key, "stored-90071992547409931234")
        XCTAssertNil(tracks[1].externalURL, "inventory identity must not mount or prefetch an unselected artifact")
        XCTAssertNil(tracks[2].siloSyncTarget, "an embedded stream never becomes syncable")
    }

    private func syncProvider(_ server: SiloSubtitleSyncFixture) -> SiloProvider {
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid/proxy/silo")!, token: "access-a",
                                profileID: "profile-a", profileToken: "pin-a", transport: server.transport)
        return SiloProvider(serverID: "server-a", displayName: "Silo", profileID: "profile-a", client: client)
    }

    func testUncertainSyncMutationIsSentOnceWithoutAuthenticationReplay() async {
        let target = SiloSubtitleSyncTarget(fileID: "158", key: "stored-5")
        let envelope = #"{"subtitle":\#(syncState(key: target.key))}"#
        for reset in [false, true] {
            let uncertain = SiloSubtitleSyncFixture.Reply(body: "", error: .networkConnectionLost)
            let server = SiloSubtitleSyncFixture(reset
                ? [.init(body: envelope, entityTag: #""exact-validator""#), uncertain] : [uncertain])
            let tokens = SiloAuthTokenRecorder()
            let client = SiloClient(baseURL: URL(string: "https://silo.invalid/proxy/silo")!,
                                    profileID: "profile-a", transport: server.transport,
                                    tokenSource: { await tokens.token($0) })
            let provider = SiloProvider(serverID: "server-a", displayName: "Silo", profileID: "profile-a", client: client)
            do {
                if reset { _ = try await provider.resetSubtitleTiming(target: target) }
                else { _ = try await provider.startSubtitleSync(target: target) }
                XCTFail("A lost mutation response is not success.")
            } catch {
                guard case MediaProviderError.unreachable = error else { XCTFail("Unexpected error: \(error)"); continue }
            }
            let requests = await server.requests()
            let refreshes = await tokens.calls()
            XCTAssertEqual(requests.count, reset ? 2 : 1)
            XCTAssertFalse(refreshes.contains(true))
        }
    }

    func testCancelledResetReadCannotIssueItsGuardedMutation() async throws {
        let target = SiloSubtitleSyncTarget(fileID: "158", key: "stored-5")
        let gate = SiloAuthRequestGate()
        let server = SiloSubtitleSyncFixture([
            .init(body: #"{"subtitle":\#(syncState(key: target.key))}"#, entityTag: #""exact-validator""#, gate: gate)
        ])
        let provider = syncProvider(server)
        let task = Task { try await provider.resetSubtitleTiming(target: target) }
        await fulfillment(of: [gate.entered], timeout: 2)
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("Cancellation must stop the write even if the read transport returns successfully.")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let requests = await server.requests()
        XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
    }

    func testCancelledSyncWaitingForCapturedTokenNeverDispatchesMutation() async {
        let gate = SiloAuthRequestGate()
        let server = SiloSubtitleSyncFixture([])
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid")!, profileID: "profile-a",
                                transport: server.transport, tokenSource: { _ in
            await gate.pause()
            return "captured-access"
        })
        let provider = SiloProvider(serverID: "server-a", displayName: "Silo", profileID: "profile-a", client: client)
        let task = Task { try await provider.startSubtitleSync(target: .init(fileID: "158", key: "stored-5")) }
        await fulfillment(of: [gate.entered], timeout: 2)
        task.cancel()
        await gate.release()
        do {
            _ = try await task.value
            XCTFail("A cancelled token wait must not dispatch the mutation.")
        } catch is CancellationError {
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let requests = await server.requests()
        XCTAssertTrue(requests.isEmpty)
    }

    private func syncState(key: String, job: Bool = false) -> String {
        let latest = job ? """
        {"id":"90071992547409931234","status":"running","trigger":"manual","phase":"matching",
         "progress":0.8,"confidence":null,"created_at":"2026-10-01T12:00:00.000Z","finished_at":null}
        """ : "null"
        let source = key.hasPrefix("stored-") ? "downloaded" : "external"
        let storedID = source == "downloaded" ? #","stored_subtitle_id":"\#(key.dropFirst("stored-".count))""# : ""
        return """
        {"key":"\(key)","media_file_id":"158","source":"\(source)"\(storedID),"language":"en","format":"srt",
         "label":"English.srt","timing":{"offset_ms":-1500,"scale":1.001},"sync":\(latest)}
        """
    }
}

private actor SiloSubtitleSyncFixture {
    nonisolated struct Reply: Sendable {
        var status = 200
        let body: String
        var entityTag: String? = nil
        var error: URLError.Code? = nil
        var gate: SiloAuthRequestGate? = nil
    }

    private var replies: [Reply]
    private var received: [URLRequest] = []

    init(_ replies: [Reply]) { self.replies = replies }

    nonisolated var transport: SiloClient.Transport {
        { request in try await self.handle(request) }
    }

    func requests() -> [URLRequest] { received }

    private func handle(_ request: URLRequest) async throws -> (Data, URLResponse) {
        received.append(request)
        guard !replies.isEmpty, let url = request.url else { throw URLError(.resourceUnavailable) }
        let reply = replies.removeFirst()
        if let gate = reply.gate { await gate.pause() }
        if let error = reply.error { throw URLError(error) }
        let headers = reply.entityTag.map { ["ETag": $0] } ?? [:]
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data(reply.body.utf8), response)
    }
}
