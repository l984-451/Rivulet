// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import Combine
import XCTest
@testable import Rivulet

@MainActor
final class PlexPlaybackLifecycleTests: XCTestCase {
    private final class Requests {
        var events: [String] = []
        var urls: [URL] = []
        var stopFailures = 0
        var stopError: Error = URLError(.timedOut)
        var holdStop = false
        var holdFirst = false
        var firstArrived: XCTestExpectation?
        var releaseFirst: CheckedContinuation<Void, Never>?
        var failScrobble = false

        func releaseHeldRequest() {
            holdFirst = false
            holdStop = false
            releaseFirst?.resume()
            releaseFirst = nil
        }

        func respond(_ url: URL) async throws -> Data {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            func value(_ name: String) -> String { query.first { $0.name == name }?.value ?? "" }
            events.append(url.path == "/:/scrobble" ? "watched:\(value("key"))" : "\(value("state")):\(value("ratingKey"))")
            urls.append(url)
            if (holdFirst && events.count == 1) || (holdStop && value("state") == "stopped") {
                holdStop = false
                await withCheckedContinuation { continuation in
                    releaseFirst = continuation
                    firstArrived?.fulfill()
                }
            }
            if value("state") == "stopped", stopFailures > 0 {
                stopFailures -= 1
                throw stopError
            }
            if failScrobble, url.path == "/:/scrobble" { throw URLError(.timedOut) }
            return Data()
        }
    }

    private func player(_ requests: Requests, key: String = "100", markers: [PlexMarker] = [], type: String = "movie") async throws -> UniversalPlayerViewModel {
        var metadata = try JSONDecoder().decode(PlexMetadata.self, from: Data(
            "{\"ratingKey\":\"\(key)\",\"type\":\"movie\",\"title\":\"Test\",\"duration\":100000}".utf8))
        metadata.Marker = markers
        metadata.type = type
        let reporter = PlexProgressReporter { url, _ in try await requests.respond(url) }
        let vm = UniversalPlayerViewModel(metadata: metadata, serverURL: "http://127.0.0.1:9", authToken: "test",
                                          plexProgressReporter: reporter)
        let session = try XCTUnwrap(vm.buildRivuletHLSURL(offset: 0)?.headers["X-Plex-Session-Identifier"])
        await reporter.beginPlaybackSession(ratingKey: key, sessionIdentifier: session,
                                             server: PlexServerAddress(address: "http://127.0.0.1:9", token: "test"))
        return vm
    }

    func testTranscodeSwitchKeepsPlaybackIdentityUntilFinalStop() async throws {
        let requests = Requests()
        let reporter = PlexProgressReporter { url, _ in try await requests.respond(url) }
        let server = PlexServerAddress(address: "http://127.0.0.1:9", token: "test")
        let metadata = try JSONDecoder().decode(PlexMetadata.self, from: Data(
            #"{"ratingKey":"100","type":"movie","title":"Test","duration":100000}"#.utf8))
        let vm = UniversalPlayerViewModel(metadata: metadata, serverURL: server.address, authToken: server.token,
                                          plexProgressReporter: reporter)
        let hls = try XCTUnwrap(vm.buildRivuletHLSURL(offset: 30))
        let session = try XCTUnwrap(hls.headers["X-Plex-Session-Identifier"])
        await reporter.beginPlaybackSession(ratingKey: "100",
                                             sessionIdentifier: session, server: server)
        vm.reportPlaybackState(.playing)
        await vm.markCurrentAsWatched()
        vm.beginHLSSwitch(to: hls)
        vm.reportPlaybackState(.playing)
        await vm.reportFinalProgress(time: 40, duration: 100)
        XCTAssertEqual(requests.events, ["playing:100", "watched:100", "stopped:100"])
        for url in requests.urls where url.path == "/:/timeline" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "X-Plex-Session-Identifier" }?.value, session)
        }
        let secondHLS = try XCTUnwrap(vm.buildRivuletHLSURL(offset: 40))
        XCTAssertNotEqual(hls.sessionId, secondHLS.sessionId)
        for stream in [hls, secondHLS] {
            let query = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "X-Plex-Session-Identifier" }?.value, session)
            XCTAssertEqual(stream.headers["X-Plex-Session-Identifier"], session)
            XCTAssertNotEqual(stream.sessionId, session)
        }
        vm.stopPlayback()
    }

    func testReplacingAVPlayerItemResetsPositionAndRejectsOutgoingTicks() async throws {
        let requests = Requests()
        let vm = try await player(requests)
        let url = URL(fileURLWithPath: "/nonexistent/playback-test.mp4")
        try vm.loadAVPlayer(url: url, headers: nil, allowEnrichment: false)
        let outgoing = try XCTUnwrap(vm.player?.currentItem)
        vm.updateAVPlayerTime(95, for: outgoing)
        XCTAssertEqual(vm.currentTime, 95)
        try vm.loadAVPlayer(url: url, headers: nil, allowEnrichment: false)
        let incoming = try XCTUnwrap(vm.player?.currentItem)
        XCTAssertFalse(outgoing === incoming)
        XCTAssertEqual(vm.currentTime, 0)
        vm.updateAVPlayerTime(96, for: outgoing)
        XCTAssertEqual(vm.currentTime, 0)
        vm.reportPlaybackState(.playing)
        await vm.reportFinalProgress(time: 0, duration: 100)
        let query = URLComponents(url: try XCTUnwrap(requests.urls.first), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "time" }?.value, "0")
        vm.updateAVPlayerTime(2, for: incoming)
        XCTAssertEqual(vm.currentTime, 2)
        vm.stopPlayback()
    }

    func testReloadSuppressesTransientZeroReportsUntilPositionSettles() async throws {
        let requests = Requests()
        let vm = try await player(requests)
        let url = URL(fileURLWithPath: "/nonexistent/reload-test.mp4")
        try vm.loadAVPlayer(url: url, headers: nil, allowEnrichment: false, initialTime: 42)
        vm.reportPlaybackState(.playing)
        await vm.markCurrentAsWatched()
        await vm.enqueueStreamWork { vm in
            do {
                try vm.loadAVPlayer(url: url, headers: nil, allowEnrichment: false, initialTime: 42)
            } catch {
                XCTFail("Reload setup failed: \(error)")
                return
            }
            if let item = vm.player?.currentItem { vm.updateAVPlayerTime(0, for: item) }
            XCTAssertEqual(vm.currentTime, 42)
            vm.reportPlaybackState(.playing)
            vm.reportPlaybackState(.paused)
            vm.reportPlaybackProgress(time: 0, force: true)
            await vm.markCurrentAsWatched()
            XCTAssertEqual(requests.events, ["playing:100", "watched:100"])
        }.value
        let item = try XCTUnwrap(vm.player?.currentItem)
        vm.updateAVPlayerTime(48, for: item)
        vm.reportPlaybackState(.playing)
        await vm.reportFinalProgress(time: 48, duration: 100)
        let times = requests.urls.filter { $0.path == "/:/timeline" }.compactMap {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "time" }?.value
        }
        XCTAssertEqual(times, ["42000", "48000", "48000"])
        vm.stopPlayback()
    }

    func testExitDuringReloadStopsAtRetainedPositionWithoutLatePlay() async throws {
        let requests = Requests()
        let vm = try await player(requests)
        let url = URL(fileURLWithPath: "/nonexistent/reload-test.mp4")
        try vm.loadAVPlayer(url: url, headers: nil, allowEnrichment: false, initialTime: 42)
        vm.reportPlaybackState(.playing)
        await vm.markCurrentAsWatched()
        await vm.enqueueStreamWork { vm in
            do {
                try vm.loadAVPlayer(url: url, headers: nil, allowEnrichment: false, initialTime: 42)
            } catch {
                XCTFail("Reload setup failed: \(error)")
                return
            }
            if let item = vm.player?.currentItem { vm.updateAVPlayerTime(0, for: item) }
            vm.stopPlayback()
            vm.reportPlaybackState(.playing)
        }.value
        await vm.reportFinalProgress(time: 42, duration: 100)
        XCTAssertEqual(requests.events, ["playing:100", "watched:100", "stopped:100"])
        let query = URLComponents(url: try XCTUnwrap(requests.urls.last), resolvingAgainstBaseURL: false)?.queryItems
        XCTAssertEqual(query?.first { $0.name == "time" }?.value, "42000")
    }

    func testIncomingTimelineIgnoresReplayedDurationAndAcceptsFreshEngineDuration() async throws {
        let requests = Requests()
        let vm = try await player(requests)
        let durations = CurrentValueSubject<TimeInterval, Never>(300)
        vm.bindAetherDuration(durations.eraseToAnyPublisher())
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        vm.reportPlaybackState(.playing)
        await vm.markCurrentAsWatched()
        XCTAssertEqual(vm.duration, 100)
        let firstQuery = try XCTUnwrap(URLComponents(url: XCTUnwrap(requests.urls.first), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(firstQuery.first { $0.name == "duration" }?.value, "100000")

        let updated = expectation(description: "fresh engine duration applied")
        let observation = vm.$duration.filter { $0 == 123 }.sink { _ in updated.fulfill() }
        durations.send(0)
        durations.send(.infinity)
        durations.send(123)
        await fulfillment(of: [updated], timeout: 2)
        observation.cancel()
        await vm.reportFinalProgress(time: 20, duration: vm.duration)
        let finalQuery = try XCTUnwrap(URLComponents(url: XCTUnwrap(requests.urls.last), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(finalQuery.first { $0.name == "duration" }?.value, "123000")
    }

    func testCreditsMarkWatchedWithoutStoppingAndPlaybackCanContinue() async throws {
        let requests = Requests()
        let vm = try await player(requests)
        vm.reportPlaybackState(.playing)
        await vm.handlePlaybackEnded()
        XCTAssertEqual(requests.events, ["playing:100", "watched:100"])

        vm.reportPlaybackState(.paused)
        vm.reportPlaybackState(.playing)
        await vm.reportFinalProgress(time: 95, duration: 100)
        XCTAssertEqual(requests.events, ["playing:100", "watched:100", "paused:100", "playing:100", "stopped:100"])
    }

    func testEpisodeCreditsChoicesPreserveReportingUntilPlaybackFinishes() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: CreditsBehavior.storageKey)
        defer { defaults.set(previous, forKey: CreditsBehavior.storageKey) }
        let credits = PlexMarker(id: 1, type: "credits", startTimeOffset: 90000, endTimeOffset: 100000)

        for choice in [CreditsBehavior.upNext, .skipButton, .nothing] {
            CreditsBehavior.set(choice)
            let requests = Requests()
            let vm = try await player(requests, markers: [credits], type: "episode")
            let transition = expectation(description: "Credits transition for \(choice)")
            transition.isInverted = choice != .upNext
            var loading = false
            let subscription = vm.$postVideoState.sink { state in
                if state == .loading { loading = true }
                if loading && state == .hidden { transition.fulfill() }
            }

            vm.reportPlaybackState(.playing)
            vm.checkMarkers(at: 90)
            await fulfillment(of: [transition], timeout: 1)
            subscription.cancel()
            XCTAssertEqual(loading, choice == .upNext)
            XCTAssertEqual(vm.activeMarker != nil, choice != .nothing)
            XCTAssertFalse(requests.events.contains("stopped:100"))

            await vm.finishPlayback()
            await vm.reportFinalProgress(time: 100, duration: 100)
            XCTAssertEqual(requests.events.filter { $0 == "stopped:100" }.count, 1)
            XCTAssertTrue(vm.shouldDismiss)
            vm.stopPlayback()
        }
    }

    func testMultipleCreditsSkipsKeepPostCreditsSceneOpenAndStopOnlyAtFinalCredits() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: CreditsBehavior.storageKey)
        defer { defaults.set(previous, forKey: CreditsBehavior.storageKey) }
        CreditsBehavior.set(.skipButton)
        let first = PlexMarker(id: 1, type: "credits", startTimeOffset: 60000, endTimeOffset: 70000)
        let final = PlexMarker(id: 2, type: "credits", startTimeOffset: 90000, endTimeOffset: 100000)
        let requests = Requests()
        let vm = try await player(requests, markers: [first, final])
        vm.reportPlaybackState(.playing)
        vm.checkMarkers(at: 60)
        await vm.markCurrentAsWatched()
        XCTAssertEqual(vm.activeMarker?.id, first.id)
        await vm.skipActiveMarker()
        XCTAssertFalse(vm.shouldDismiss)
        XCTAssertFalse(requests.events.contains("stopped:100"))

        vm.checkMarkers(at: 75)
        XCTAssertNil(vm.activeMarker)
        vm.reportPlaybackState(.paused)
        vm.reportPlaybackState(.playing)
        await vm.markCurrentAsWatched()
        XCTAssertEqual(requests.events, ["playing:100", "watched:100", "paused:100", "playing:100"])

        vm.checkMarkers(at: 30)
        vm.checkMarkers(at: 60)
        XCTAssertEqual(vm.activeMarker?.id, first.id)
        await vm.skipActiveMarker()
        await vm.markCurrentAsWatched()
        XCTAssertEqual(requests.events.filter { $0 == "watched:100" }.count, 1)

        vm.checkMarkers(at: 90)
        XCTAssertEqual(vm.activeMarker?.id, final.id)
        await vm.skipActiveMarker()
        XCTAssertTrue(vm.shouldDismiss)
        vm.reportPlaybackState(.paused)
        vm.reportPlaybackState(.playing)
        vm.stopPlayback()
        await vm.reportFinalProgress(time: 90, duration: 100)
        XCTAssertEqual(requests.events, ["playing:100", "watched:100", "paused:100", "playing:100", "stopped:100"])
    }

    func testStartupPauseRemainsSuppressed() async throws {
        let requests = Requests()
        let vm = try await player(requests)
        vm.reportPlaybackState(.paused)
        vm.reportPlaybackState(.playing)
        vm.reportPlaybackState(.paused)
        vm.reportPlaybackState(.playing)
        await vm.reportFinalProgress(time: 20, duration: 100)
        XCTAssertEqual(requests.events, ["playing:100", "paused:100", "playing:100", "stopped:100"])
    }

    func testEndedThenExitSendsOneStopAndRejectsLatePlaying() async throws {
        let requests = Requests()
        let vm = try await player(requests)
        vm.reportPlaybackState(.playing)
        vm.reportPlaybackState(.ended)
        vm.reportPlaybackState(.playing)
        vm.reportPlaybackState(.paused)
        vm.stopPlayback()
        await vm.reportFinalProgress(time: 20, duration: 100)
        XCTAssertEqual(requests.events, ["playing:100", "stopped:100"])
    }

    func testStopWaitsForInFlightPlayingAndRejectsLaterReports() async throws {
        let requests = Requests()
        requests.holdFirst = true
        let arrived = expectation(description: "playing request arrived")
        requests.firstArrived = arrived
        let vm = try await player(requests)
        vm.reportPlaybackState(.playing)
        await fulfillment(of: [arrived], timeout: 2)
        vm.stopPlayback()
        vm.reportPlaybackState(.playing)
        XCTAssertEqual(requests.events, ["playing:100"])
        requests.releaseHeldRequest()
        await vm.reportFinalProgress(time: 20, duration: 100)
        XCTAssertEqual(requests.events, ["playing:100", "stopped:100"])
    }

    func testNaturalEndStopsEvenWithoutAViewObservingState() async throws {
        let requests = Requests()
        let vm = try await player(requests)
        defer { vm.stopPlayback() }
        vm.postVideoState = .showingEpisodeSummary
        vm.updatePlaybackState(.playing)
        vm.updatePlaybackState(.ended)
        await vm.markCurrentAsWatched()
        XCTAssertEqual(requests.events, ["playing:100", "stopped:100", "watched:100"])
    }

    func testExitWhileEpisodeTransitionAwaitsWatchedDoesNotStartNextItem() async throws {
        let requests = Requests()
        requests.holdFirst = true
        let arrived = expectation(description: "watched request arrived")
        requests.firstArrived = arrived
        let vm = try await player(requests)
        let next = try JSONDecoder().decode(PlexMetadata.self, from: Data(
            #"{"ratingKey":"200","type":"episode","title":"Next","duration":100000}"#.utf8))
        let transition = Task { await vm.playEpisode(next) }
        await fulfillment(of: [arrived], timeout: 2)
        vm.stopPlayback()
        requests.releaseHeldRequest()
        await transition.value
        await vm.reportFinalProgress(time: 20, duration: 100)
        XCTAssertEqual(vm.metadata.ratingKey, "100")
        XCTAssertEqual(requests.events, ["watched:100", "stopped:100"])
    }

    func testNextEpisodeStopsOutgoingItemBeforeReportingIncomingItem() async throws {
        let requests = Requests()
        let vm = try await player(requests)
        let outgoingSession = try XCTUnwrap(vm.buildRivuletHLSURL(offset: 0)?.headers["X-Plex-Session-Identifier"])
        vm.reportPlaybackState(.playing)
        await vm.markCurrentAsWatched()
        let next = try JSONDecoder().decode(PlexMetadata.self, from: Data(
            #"{"ratingKey":"200","type":"episode","title":"Next","parentRatingKey":"season","index":2,"duration":100000,"Media":[{"id":1,"Part":[{"id":1,"key":"/library/parts/1/next.mkv"}]}]}"#.utf8))
        await vm.playEpisode(next)
        XCTAssertEqual(vm.metadata.ratingKey, "200")
        vm.reportPlaybackState(.playing)
        await vm.reportFinalProgress(time: 20, duration: 100)
        XCTAssertEqual(requests.events, ["playing:100", "watched:100", "stopped:100", "playing:200", "stopped:200"])
        let incomingSession = try XCTUnwrap(vm.buildRivuletHLSURL(offset: 0)?.headers["X-Plex-Session-Identifier"])
        XCTAssertNotEqual(outgoingSession, incomingSession)
        let incomingReports = requests.urls.filter {
            URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "ratingKey" }?.value == "200"
        }
        XCTAssertEqual(incomingReports.count, 2)
        for url in incomingReports {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "X-Plex-Session-Identifier" }?.value, incomingSession)
        }
        vm.stopPlayback()
    }

    func testRepeatedPlayingAfterBufferingDoesNotDuplicateTimeline() async throws {
        let requests = Requests()
        let vm = try await player(requests)
        vm.reportPlaybackState(.playing)
        vm.reportPlaybackState(.buffering)
        vm.reportPlaybackState(.playing)
        vm.reportPlaybackState(.paused)
        vm.reportPlaybackState(.playing)
        await vm.reportFinalProgress(time: 20, duration: 100)
        XCTAssertEqual(requests.events, ["playing:100", "paused:100", "playing:100", "stopped:100"])
    }

    func testExitCancelsPendingAutoplayCountdown() async throws {
        let previous = UserDefaults.standard.object(forKey: AutoplayCountdown.storageKey)
        defer { UserDefaults.standard.set(previous, forKey: AutoplayCountdown.storageKey) }
        UserDefaults.standard.set(20, forKey: AutoplayCountdown.storageKey)
        let requests = Requests()
        let vm = try await player(requests)
        vm.startAutoplayCountdown()
        XCTAssertEqual(vm.countdownSeconds, 20)
        vm.stopPlayback()
        await vm.reportFinalProgress(time: 20, duration: 100)
        XCTAssertEqual(vm.countdownSeconds, 0)
        XCTAssertEqual(requests.events, ["stopped:100"])
    }

    func testNaturalEndDuringCountdownStopsWithoutRestartingCountdown() async throws {
        let previous = UserDefaults.standard.object(forKey: AutoplayCountdown.storageKey)
        defer { UserDefaults.standard.set(previous, forKey: AutoplayCountdown.storageKey) }
        UserDefaults.standard.set(20, forKey: AutoplayCountdown.storageKey)
        let requests = Requests()
        let vm = try await player(requests)
        vm.reportPlaybackState(.playing)
        vm.postVideoState = .showingEpisodeSummary
        vm.startAutoplayCountdown()
        vm.countdownSeconds = 12
        await vm.finishPlayback()
        XCTAssertFalse(vm.shouldDismiss)
        XCTAssertEqual(vm.countdownSeconds, 12)
        vm.reportPlaybackState(.playing)
        vm.stopPlayback()
        await vm.reportFinalProgress(time: 20, duration: 100)
        XCTAssertEqual(requests.events, ["playing:100", "stopped:100"])
    }

    func testFailedWatchedReportCanRetryWithoutStopping() async throws {
        let requests = Requests()
        requests.failScrobble = true
        let vm = try await player(requests)
        await vm.markCurrentAsWatched()
        requests.failScrobble = false
        await vm.markCurrentAsWatched()
        await vm.markCurrentAsWatched()
        XCTAssertEqual(requests.events, ["watched:100", "watched:100"])
    }

    func testEOFOvershootIsBoundedInTheActualTimelineRequest() async throws {
        let requests = Requests()
        let reporter = PlexProgressReporter { url, _ in try await requests.respond(url) }
        await reporter.reportProgress(ratingKey: "100", time: 2548.109, duration: 2548.096,
                                      state: "stopped", server: PlexServerAddress(address: "http://127.0.0.1:9", token: "test"))
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(requests.urls.first), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first { $0.name == "time" }?.value, query.first { $0.name == "duration" }?.value)
        XCTAssertEqual(query.first { $0.name == "duration" }?.value, "2548096")
    }

    func testInvalidTimelineTimesRemainFiniteAndWithinDuration() async throws {
        let requests = Requests()
        let reporter = PlexProgressReporter { url, _ in try await requests.respond(url) }
        let cases: [(time: Double, duration: Double, expectedTime: Int, expectedDuration: Int)] = [
            (-1, 100, 0, 100000), (.nan, 100, 0, 100000), (.infinity, 100, 0, 100000),
            (10, 0, 10000, 0), (10, -1, 10000, 0), (10, .nan, 10000, 0), (10, .infinity, 10000, 0),
            (Double.greatestFiniteMagnitude, 100, 100000, 100000), (12.345, 100, 12345, 100000)
        ]
        for state in ["playing", "paused", "stopped"] {
            for (time, duration, expectedTime, expectedDuration) in cases {
                let count = requests.urls.count
                await reporter.reportProgress(ratingKey: "100", time: time, duration: duration, state: state,
                                              forceReport: true, server: PlexServerAddress(address: "http://127.0.0.1:9", token: "test"))
                XCTAssertEqual(requests.urls.count, count + 1)
                let url = try XCTUnwrap(requests.urls.last)
                let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
                let time = try XCTUnwrap(Int(query.first { $0.name == "time" }?.value ?? ""))
                let duration = try XCTUnwrap(Int(query.first { $0.name == "duration" }?.value ?? ""))
                XCTAssertEqual(time, expectedTime)
                XCTAssertEqual(duration, expectedDuration)
            }
        }
    }

    func testFailedStopRetainsSessionAcrossBoundedAndLaterRetries() async throws {
        let requests = Requests()
        let reporter = PlexProgressReporter { url, _ in try await requests.respond(url) }
        let server = PlexServerAddress(address: "http://127.0.0.1:9", token: "test")
        await reporter.beginPlaybackSession(ratingKey: "100", server: server)
        requests.stopFailures = 2
        let failed = await reporter.reportProgress(ratingKey: "100", time: 101, duration: 100,
                                                   state: "stopped", forceReport: true, server: server)
        guard case .failed = failed else { return XCTFail("Exhausted retries must report failure") }
        XCTAssertEqual(requests.urls.count, 2)
        let delivered = await reporter.reportProgress(ratingKey: "100", time: 101, duration: 100,
                                                      state: "stopped", forceReport: true, server: server)
        guard case .sent = delivered else { return XCTFail("A later stop must be retryable") }
        XCTAssertEqual(requests.urls.count, 3)
        XCTAssertEqual(Set(requests.urls).count, 1)
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(requests.urls.first), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertFalse(try XCTUnwrap(query.first { $0.name == "X-Plex-Session-Identifier" }?.value).isEmpty)
    }

    func testQueuedExitRetriesRejectedStopButNeverRestartsPlayback() async throws {
        let requests = Requests()
        requests.holdStop = true
        requests.stopFailures = 1
        requests.stopError = PlexAPIError.httpError(statusCode: 400, data: nil)
        let arrived = expectation(description: "stop request arrived")
        requests.firstArrived = arrived
        let vm = try await player(requests)
        vm.reportPlaybackState(.playing)
        vm.reportPlaybackState(.ended)
        await fulfillment(of: [arrived], timeout: 2)
        vm.reportPlaybackState(.playing)
        vm.stopPlayback()
        let final = Task { await vm.reportFinalProgress(time: 100, duration: 100) }
        requests.releaseHeldRequest()
        await final.value
        XCTAssertEqual(requests.events, ["playing:100", "stopped:100", "stopped:100", "watched:100"])
    }

    func testStopRetriesAfterPlayerHasAlreadyExited() async throws {
        let requests = Requests()
        requests.stopFailures = 1
        let vm = try await player(requests)
        vm.reportPlaybackState(.playing)
        vm.stopPlayback()
        vm.reportPlaybackState(.playing)
        await vm.reportFinalProgress(time: 20, duration: 100)
        XCTAssertEqual(requests.events, ["playing:100", "stopped:100", "stopped:100"])
    }

    func testQueuedStopKeepsItsIdentityAfterSameItemStartsAgain() async throws {
        for failures in 0...1 {
            let requests = Requests()
            let reporter = PlexProgressReporter { url, _ in try await requests.respond(url) }
            let server = PlexServerAddress(address: "http://127.0.0.1:9", token: "test")
            let metadata = try JSONDecoder().decode(PlexMetadata.self, from: Data(
                #"{"ratingKey":"100","type":"movie","title":"Test","duration":100000}"#.utf8))
            let vm = UniversalPlayerViewModel(metadata: metadata, serverURL: server.address, authToken: server.token,
                                              plexProgressReporter: reporter)
            let outgoing = try XCTUnwrap(vm.buildRivuletHLSURL(offset: 0)?.headers["X-Plex-Session-Identifier"])
            await reporter.beginPlaybackSession(ratingKey: "100", sessionIdentifier: outgoing, server: server)
            requests.holdFirst = true
            let arrived = expectation(description: "outgoing playing request arrived")
            requests.firstArrived = arrived
            vm.reportPlaybackState(.playing)
            await fulfillment(of: [arrived], timeout: 2)
            vm.stopPlayback()
            let incoming = UUID().uuidString
            await reporter.beginPlaybackSession(ratingKey: "100", sessionIdentifier: incoming, server: server)
            await reporter.reportProgress(ratingKey: "100", time: 0, duration: 100, state: "playing", server: server)
            requests.stopFailures = failures
            requests.stopError = PlexAPIError.httpError(statusCode: 400, data: nil)
            requests.releaseHeldRequest()
            await vm.reportFinalProgress(time: 20, duration: 100)
            let throttled = await reporter.reportProgress(ratingKey: "100", time: 1, duration: 100,
                                                          state: "playing", server: server)
            if case .skipped = throttled {} else { XCTFail("Old stop must preserve the new session's throttle") }
            await reporter.reportProgress(ratingKey: "100", time: 10, duration: 100, state: "playing", server: server)
            let stops = requests.urls.filter {
                URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?
                    .first { $0.name == "state" }?.value == "stopped"
            }
            XCTAssertEqual(stops.count, failures + 1)
            for url in stops {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first { $0.name == "X-Plex-Session-Identifier" }?.value, outgoing)
            }
            let lastQuery = URLComponents(url: try XCTUnwrap(requests.urls.last), resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(lastQuery?.first { $0.name == "X-Plex-Session-Identifier" }?.value, incoming)
        }
    }

    func testOldStopRetryKeepsItsIdentityAfterSameItemStartsAgain() async throws {
        let requests = Requests()
        let reporter = PlexProgressReporter { url, _ in try await requests.respond(url) }
        let server = PlexServerAddress(address: "http://127.0.0.1:9", token: "test")
        await reporter.beginPlaybackSession(ratingKey: "100", server: server)
        requests.stopFailures = 1
        requests.stopError = PlexAPIError.httpError(statusCode: 400, data: nil)
        let result = await reporter.reportProgress(ratingKey: "100", time: 100, duration: 100,
                                                   state: "stopped", forceReport: true, server: server)
        guard case .failed(let pending?) = result else { return XCTFail("Failed stop must retain its request") }
        await reporter.beginPlaybackSession(ratingKey: "100", server: server)
        await reporter.reportProgress(ratingKey: "100", time: 0, duration: 100, state: "playing", server: server)
        let retried = await reporter.send(pending)
        guard case .sent = retried else { return XCTFail("Retry should succeed") }
        await reporter.reportProgress(ratingKey: "100", time: 10, duration: 100, state: "playing", server: server)
        XCTAssertEqual(requests.urls.count, 4)
        guard requests.urls.count == 4 else { return }
        func session(_ url: URL) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first { $0.name == "X-Plex-Session-Identifier" }?.value
        }
        XCTAssertEqual(requests.urls[0], requests.urls[2])
        XCTAssertNotEqual(session(requests.urls[0]), session(requests.urls[1]))
        XCTAssertEqual(session(requests.urls[1]), session(requests.urls[3]))
        XCTAssertNotNil(session(requests.urls[3]))
    }

    func testEpisodeHandoffRetriesFailedEOFStopBeforeIncomingPlaying() async throws {
        let requests = Requests()
        let vm = try await player(requests)
        vm.reportPlaybackState(.playing)
        requests.stopFailures = 1
        requests.stopError = PlexAPIError.httpError(statusCode: 400, data: nil)
        vm.reportPlaybackState(.ended)
        await vm.markCurrentAsWatched()
        vm.reportPlaybackState(.playing)
        let next = try JSONDecoder().decode(PlexMetadata.self, from: Data(
            #"{"ratingKey":"200","type":"episode","title":"Next","parentRatingKey":"season","index":2,"duration":100000,"Media":[{"id":1,"Part":[{"id":1,"key":"/library/parts/1/next.mkv"}]}]}"#.utf8))
        await vm.playEpisode(next)
        vm.reportPlaybackState(.playing)
        await vm.reportFinalProgress(time: 20, duration: 100)
        XCTAssertEqual(requests.events, ["playing:100", "stopped:100", "watched:100", "stopped:100", "playing:200", "stopped:200"])
        XCTAssertEqual(requests.urls[1], requests.urls[3])
        vm.stopPlayback()
    }

    func testExitDuringIncomingMetadataLoadStopsIncomingItemAndPreventsStartup() async throws {
        let requests = Requests()
        let vm = try await player(requests)
        let next = try JSONDecoder().decode(PlexMetadata.self, from: Data(
            #"{"ratingKey":"200","type":"episode","title":"Next","parentRatingKey":"season","index":2,"duration":100000,"Media":[{"id":1,"Part":[{"id":1,"key":"/library/parts/1/next.mkv"}]}]}"#.utf8))
        let arrived = expectation(description: "incoming metadata requested")
        var release: CheckedContinuation<Void, Never>?
        var released = false
        vm.plexMetadataFetch = { _, _, key in
            XCTAssertEqual(key, "200")
            if !released {
                await withCheckedContinuation { continuation in
                    release = continuation
                    arrived.fulfill()
                }
            }
            return next
        }
        vm.reportPlaybackState(.playing)
        let handoff = Task { await vm.playEpisode(next) }
        await fulfillment(of: [arrived], timeout: 5)
        vm.stopPlayback()
        released = true
        release?.resume()
        await handoff.value
        await vm.reportFinalProgress(time: 0, duration: 100)
        XCTAssertEqual(requests.events, ["playing:100", "watched:100", "stopped:100", "stopped:200"])
        XCTAssertNil(vm.player)
        XCTAssertNil(vm.aetherPlayer)
    }

    func testFinishedCreditsReplayRequiresUserActionAndCannotRestartAfterExit() async throws {
        let defaults = UserDefaults.standard
        let previous = defaults.object(forKey: CreditsBehavior.storageKey)
        defer { defaults.set(previous, forKey: CreditsBehavior.storageKey) }
        CreditsBehavior.set(.skipButton)
        let credits = PlexMarker(id: 1, type: "credits", startTimeOffset: 90000, endTimeOffset: 100000)
        let actions: [(String, (UniversalPlayerViewModel) -> Void)] = [
            ("seek", { $0.reopenPlexTimeline(at: 20) }),
            ("toggle", { $0.togglePlayPause() }),
            ("resume", { $0.resume() })
        ]
        for (name, replayAction) in actions {
            for exitBeforeReplay in [false, true] {
                let requests = Requests()
                let vm = try await player(requests, markers: [credits])
                defer { vm.stopPlayback() }
                let hls = try XCTUnwrap(vm.buildRivuletHLSURL(offset: 0))
                vm.beginHLSSwitch(to: hls)
                vm.reportPlaybackState(.playing)
                vm.checkMarkers(at: 90)
                XCTAssertEqual(vm.activeMarker?.id, credits.id)
                vm.postVideoState = .showingEpisodeSummary
                await vm.markCurrentAsWatched()
                try vm.loadAVPlayer(url: URL(fileURLWithPath: "/nonexistent/credits-replay-test.mp4"),
                                    headers: nil, allowEnrichment: false)
                await vm.skipActiveMarker()
                vm.updatePlaybackState(.paused)
                XCTAssertFalse(vm.shouldDismiss)
                vm.closePostVideo()
                XCTAssertEqual(vm.postVideoState, .hidden)
                vm.reportPlaybackState(.playing)
                await vm.markCurrentAsWatched()
                XCTAssertEqual(requests.events, ["playing:100", "watched:100", "stopped:100"],
                               "A late callback must not reopen reporting")
                vm.updatePlaybackState(.paused)
                if exitBeforeReplay { vm.stopPlayback() }
                replayAction(vm)
                vm.reportPlaybackState(.playing)
                vm.reportPlaybackState(.paused)
                await vm.reportFinalProgress(time: 20, duration: 100)
                let replay = exitBeforeReplay ? [] : ["playing:100", "paused:100", "stopped:100"]
                XCTAssertEqual(requests.events, ["playing:100", "watched:100", "stopped:100"] + replay, "action=\(name), exited=\(exitBeforeReplay)")
            }
        }
    }

    func testHLSReplayAfterEOFRestoresTimelineSessionIdentity() async throws {
        let requests = Requests()
        let reporter = PlexProgressReporter { url, _ in try await requests.respond(url) }
        let server = PlexServerAddress(address: "http://127.0.0.1:9", token: "test")
        let metadata = try JSONDecoder().decode(PlexMetadata.self, from: Data(
            #"{"ratingKey":"100","type":"episode","title":"Test","duration":100000}"#.utf8))
        let vm = UniversalPlayerViewModel(metadata: metadata, serverURL: server.address, authToken: server.token,
                                          plexProgressReporter: reporter)
        let hls = try XCTUnwrap(vm.buildRivuletHLSURL(offset: 0))
        let session = try XCTUnwrap(hls.headers["X-Plex-Session-Identifier"])
        await reporter.beginPlaybackSession(ratingKey: "100", sessionIdentifier: session, server: server)
        vm.beginHLSSwitch(to: hls)
        try vm.loadAVPlayer(url: URL(fileURLWithPath: "/nonexistent/replay-test.mp4"), headers: nil, allowEnrichment: false)
        vm.postVideoState = .showingEpisodeSummary
        vm.reportPlaybackState(.playing)
        await vm.markCurrentAsWatched()
        vm.updatePlaybackState(.ended)
        vm.reopenPlexTimeline(at: 20)
        vm.reportPlaybackState(.playing)
        await vm.reportFinalProgress(time: 20, duration: 100)
        XCTAssertEqual(requests.events, ["playing:100", "watched:100", "stopped:100", "playing:100", "stopped:100"])
        for url in requests.urls where url.path == "/:/timeline" {
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "X-Plex-Session-Identifier" }?.value, session)
        }
        vm.stopPlayback()
    }

    func testCinemaClipHandoffDoesNotSendTimelineForTheClip() async throws {
        let previous = UserDefaults.standard.object(forKey: CinemaExtras.countKey)
        defer { UserDefaults.standard.set(previous, forKey: CinemaExtras.countKey) }
        UserDefaults.standard.set(1, forKey: CinemaExtras.countKey)
        let requests = Requests()
        let vm = try await player(requests)
        var clip = PlexMetadata()
        clip.ratingKey = "22"
        clip.type = "clip"
        let movie = vm.metadata
        vm.plexCinemaExtras = { _, _, _, _ in [clip] }
        vm.plexMetadataFetch = { _, _, key in key == "22" ? clip : movie }
        await vm.startPlayback()
        XCTAssertEqual(vm.metadata.ratingKey, "100")
        XCTAssertFalse(vm.isPlayingCinemaExtra)
        vm.reportPlaybackState(.playing)
        await vm.reportFinalProgress(time: 20, duration: 100)
        XCTAssertEqual(requests.events, ["playing:100", "stopped:100"])
        vm.stopPlayback()
    }
}
