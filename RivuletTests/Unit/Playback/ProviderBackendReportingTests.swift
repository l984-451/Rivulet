// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Testing
@testable import Rivulet

@MainActor
struct ProviderBackendReportingTests {
    @MainActor
    private final class SlowReporter: Rivulet.ProgressReporter {
        var slowOperation: String
        private(set) var events: [String] = []

        init(slowOperation: String) { self.slowOperation = slowOperation }

        private func record(_ operation: String, position: TimeInterval) async throws {
            events.append("\(operation):\(Int(position))")
            guard operation == slowOperation else { return }
            do {
                try await Task.sleep(for: .seconds(60))
                events.append("completedWithoutDeadline")
            } catch {
                events.append("cancelled:\(operation)")
                throw error
            }
        }

        func start(position: TimeInterval) async throws { try await record("start", position: position) }
        func progress(position: TimeInterval) async { try? await record("progress", position: position) }
        func paused(at position: TimeInterval) async { try? await record("paused", position: position) }
        func stopped(at position: TimeInterval) async { try? await record("stopped", position: position) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["start", "first-report-start", "progress", "stopped", "retirement"])
    func slowProviderRequestsReleaseFinalReporting(_ slowOperation: String) async throws {
        let delayedOperation = switch slowOperation {
        case "retirement": "stopped"
        case "first-report-start": "start"
        default: slowOperation
        }
        let reporter = SlowReporter(slowOperation: delayedOperation)
        let provider = StubMediaProvider(id: "provider:test", kind: .jellyfin)
        provider.reporter = reporter
        let item = JellyfinFixtures.mediaItem("item", providerID: provider.id)
        let source = MediaSource(id: "source", container: "mp4", duration: 100, bitrate: nil,
                                 fileSize: nil, fileName: nil, videoResolution: nil, videoTracks: [],
                                 audioTracks: [], subtitleTracks: [], streamKind: .directPlay,
                                 streamURL: URL(string: "https://media.invalid/video.mp4"))
        provider.detailResult = MediaItemDetail(item: item, tagline: nil, genres: [], studios: [], cast: [],
                                               directors: [], writers: [], chapters: [], mediaSources: [source],
                                               trailerURL: nil, contentRating: nil, nextEpisode: nil, collections: [])
        provider.streamResult = StreamInfo(source: source, playSessionID: "session", trackInfoAvailable: true)
        let backend = ProviderBackend(provider: provider, reportTimeout: .milliseconds(20))
        let request = try await backend.firstPlayback(of: item, fromBeginning: true, quality: .original)
        let queue = PlaybackReportQueue()
        if slowOperation != "first-report-start" {
            await backend.openPlaySession(request)
        } else {
            await backend.reportProgress(for: request, time: 10, state: "playing")
        }
        if slowOperation == "start" || slowOperation == "first-report-start" { reporter.slowOperation = "" }
        queue.enqueue { await backend.reportProgress(for: request, time: 40, state: "playing") }
        if slowOperation != "retirement" {
            queue.enqueue { await backend.reportProgress(for: request, time: 95, state: "stopped") }
        }
        await queue.enqueue {
            await backend.markWatched(request)
            await backend.stopTranscode(request)
        }.value
        let events = reporter.events
        #expect(events.contains("cancelled:\(delayedOperation)"))
        #expect(events.contains("completedWithoutDeadline") == false)
        #expect(events.filter { $0.hasPrefix("stopped:") } == ["stopped:\(slowOperation == "retirement" ? 40 : 95)"])
        #expect(provider.markedPlayed == [item.ref])
        if slowOperation == "start" || slowOperation == "first-report-start" {
            #expect(events.filter { $0.hasPrefix("start:") }.count == 2)
            #expect(events.contains("progress:10") == false)
            #expect(events.contains("progress:40"))
        }
    }
}

@MainActor
struct ProviderStartFailureTests {
    @MainActor
    private final class Requests {
        var paths: [String] = []
        var cancelAfterSuccessfulStart = false
        func send(_ request: URLRequest) throws -> (Data, URLResponse) {
            let url = try #require(request.url)
            paths.append(url.path)
            if paths.count == 1 {
                if cancelAfterSuccessfulStart {
                    withUnsafeCurrentTask { $0?.cancel() }
                } else {
                    throw URLError(.networkConnectionLost)
                }
            }
            return (Data(), try #require(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)))
        }
    }

    private func makeReporter(_ kind: String, requests: Requests) throws -> any Rivulet.ProgressReporter {
        let url = try #require(URL(string: "https://media.invalid"))
        if kind == "jellyfin" {
            return JellyfinProgressReporter(
                client: JellyfinClient(baseURL: url, token: "test", transport: { try await requests.send($0) }),
                itemID: "item", mediaSourceID: "source", playSessionID: "session", isTranscode: false)
        } else {
            return EmbyProgressReporter(
                client: EmbyClient(baseURL: url, token: "test", transport: { try await requests.send($0) }),
                itemID: "item", mediaSourceID: "source", playSessionID: "session", transcodeDeviceID: nil)
        }
    }

    @Test(arguments: ["jellyfin", "emby"], [false, true])
    func successfulStartSurvivesCancellationAtDelivery(_ kind: String, _ explicitOpen: Bool) async throws {
        let requests = Requests()
        requests.cancelAfterSuccessfulStart = true
        let reporter = try makeReporter(kind, requests: requests)
        let ledger = ProviderReportLedger()
        await Task {
            if explicitOpen { await ledger.open("session", make: { reporter }, position: 40) }
            else { await ledger.report("session", make: { reporter }, state: "playing", time: 40) }
        }.value
        await ledger.report("session", make: { reporter }, state: "paused", time: 42)
        let progress = "/Sessions/Playing/Progress"
        #expect(requests.paths == (explicitOpen
            ? ["/Sessions/Playing", progress]
            : ["/Sessions/Playing", progress, progress]))
    }

    @Test(arguments: ["jellyfin", "emby"], [false, true])
    func failedStartIsRetriedBeforeProgress(_ kind: String, _ explicitOpen: Bool) async throws {
        let requests = Requests()
        let reporter = try makeReporter(kind, requests: requests)
        let ledger = ProviderReportLedger()
        if explicitOpen { await ledger.open("session", make: { reporter }, position: 40) }
        else { await ledger.report("session", make: { reporter }, state: "playing", time: 40) }
        #expect(requests.paths == ["/Sessions/Playing"])
        await ledger.report("session", make: { reporter }, state: "paused", time: 42)
        #expect(requests.paths == ["/Sessions/Playing", "/Sessions/Playing", "/Sessions/Playing/Progress"])
    }
}

@MainActor
struct ProviderCleanupTests {
    private final class Requests {
        var events: [String] = []
        var stopFailures = Int.max
        var stopBodies: [Data] = []

        func stop() async throws {
            events.append("stopped")
            guard events.filter({ $0 == "stopped" }).count <= stopFailures else { return }
            do {
                try await Task.sleep(for: .seconds(60))
            } catch {
                events.append("reportCancelled")
                throw error
            }
        }

        func cleanup() throws {
            try Task.checkCancellation()
            events.append("cleanup")
        }

        func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
            if request.httpMethod == "DELETE" {
                try cleanup()
            } else if request.url?.lastPathComponent == "Stopped" {
                stopBodies.append(try #require(request.httpBody))
                try await stop()
            }
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 204,
                                            httpVersion: nil, headerFields: nil)!)
        }
    }

    private final class Network: PlexNetworkManager, @unchecked Sendable {
        let requests: Requests
        init(requests: Requests) { self.requests = requests; super.init() }

        override func reportProgress(serverURL: String, authToken: String, ratingKey: String, timeMs: Int,
                                     state: String, duration: Int?, sessionIdentifier: String?, reportingTimeout: Duration?) async throws -> String? {
            if state == "stopped" { try await requests.stop() }
            return nil
        }

        override func stopTranscodeSession(serverURL: String, authToken: String, sessionId: String) async {
            try? requests.cleanup()
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["jellyfin", "emby", "plex"])
    func timedOutStopStillCleansUpBeforeRetirement(_ provider: String) async throws {
        let requests = Requests()
        let url = try #require(URL(string: "https://media.invalid"))
        let reporter: any Rivulet.ProgressReporter
        switch provider {
        case "jellyfin":
            reporter = JellyfinProgressReporter(
                client: JellyfinClient(baseURL: url, token: "test", transport: { try await requests.send($0) }),
                itemID: "item", mediaSourceID: "source", playSessionID: "session", isTranscode: true, reportTimeout: .milliseconds(20))
        case "emby":
            reporter = EmbyProgressReporter(
                client: EmbyClient(baseURL: url, token: "test", transport: { try await requests.send($0) }),
                itemID: "item", mediaSourceID: "source", playSessionID: "session", transcodeDeviceID: "device", reportTimeout: .milliseconds(20))
        default:
            reporter = PlexTimelineReporter(
                serverURL: url.absoluteString, authToken: "test", ratingKey: "item",
                networkManager: Network(requests: requests), playSessionID: "session",
                session: PlexPlaySession(ratingKey: "item", mediaIndex: 0, durationMs: 100_000,
                                         transcode: (url: url, headers: [:])))
        }
        let ledger = ProviderReportLedger()
        await ledger.open("session", make: { reporter }, position: 0)
        await #expect(throws: URLError.self) {
            try await PlaybackReportTimeout.run(for: .milliseconds(20)) { @MainActor in
                await ledger.report("session", make: { reporter }, state: "stopped", time: 95)
            }
        }
        let expected = ["stopped", "reportCancelled", "cleanup"]
        #expect(requests.events == expected)
        await ledger.stop("session", make: { reporter }, fallback: 0)
        #expect(requests.events == expected)
    }

    @Test(arguments: ["jellyfin", "emby"])
    func stopCarriesPositionBeforeFreeingTheTranscoder(_ kind: String) async throws {
        let requests = Requests()
        requests.stopFailures = 0
        let url = try #require(URL(string: "https://media.invalid"))
        let reporter: any Rivulet.ProgressReporter
        if kind == "jellyfin" {
            reporter = JellyfinProgressReporter(
                client: JellyfinClient(baseURL: url, token: "test", transport: { try await requests.send($0) }),
                itemID: "item", mediaSourceID: "source", playSessionID: "session", isTranscode: true, reportTimeout: .milliseconds(20))
        } else {
            reporter = EmbyProgressReporter(
                client: EmbyClient(baseURL: url, token: "test", transport: { try await requests.send($0) }),
                itemID: "item", mediaSourceID: "source", playSessionID: "session", transcodeDeviceID: "device", reportTimeout: .milliseconds(20))
        }
        try? await PlaybackReportTimeout.run(for: .milliseconds(20)) {
            await reporter.stopped(at: 95)
        }
        #expect(requests.events == ["stopped", "cleanup"])
        #expect(requests.stopBodies.count == 1)
        let stopBody = try #require(requests.stopBodies.first)
        let body = try #require(JSONSerialization.jsonObject(with: stopBody) as? NSDictionary)
        #expect(body["PositionTicks"] as? Int == 950_000_000)
        #expect(body["PlaySessionId"] as? String == "session")
    }

    @Test(.timeLimit(.minutes(1)))
    func cleanupHasItsOwnDeadline() async {
        await confirmation("cleanup request cancelled at its deadline") { cancelled in
            await PlaybackReportTimeout.cleanup(for: .milliseconds(20)) {
                do {
                    try await Task.sleep(for: .seconds(60))
                    Issue.record("Cleanup outlived its deadline")
                } catch {
                    cancelled()
                }
            }
        }
    }
}

@MainActor
struct PlaybackPreparationTests {
    @MainActor
    private final class Reporter: Rivulet.ProgressReporter {
        var stops = 0
        func start(position: TimeInterval) async throws {}
        func progress(position: TimeInterval) async {}
        func paused(at position: TimeInterval) async {}
        func stopped(at position: TimeInterval) async { stops += 1 }
    }

    @Test(arguments: [false, true], [false, true])
    func invalidatedPreparationDiscardsOnlyNewSessions(_ cancelled: Bool, _ reused: Bool) async throws {
        let reporter = Reporter()
        let provider = StubMediaProvider(id: "provider:test", kind: .jellyfin)
        provider.reporter = reporter
        let item = JellyfinFixtures.mediaItem("item", providerID: provider.id)
        let source = MediaSource(id: "source", container: "mp4", duration: 100, bitrate: nil,
                                 fileSize: nil, fileName: nil, videoResolution: nil, videoTracks: [],
                                 audioTracks: [], subtitleTracks: [], streamKind: .directPlay,
                                 streamURL: URL(string: "https://media.invalid/video.mp4"))
        provider.detailResult = MediaItemDetail(item: item, tagline: nil, genres: [], studios: [], cast: [],
                                               directors: [], writers: [], chapters: [], mediaSources: [source],
                                               trailerURL: nil, contentRating: nil, nextEpisode: nil, collections: [])
        provider.streamResult = StreamInfo(source: source, playSessionID: "new-session", trackInfoAvailable: true)
        let backend = ProviderBackend(provider: provider)
        let request = try await backend.firstPlayback(of: item, fromBeginning: true, quality: .original)
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish(); release.continuation.finish() }
        var active = true
        let preparing = Task {
            try await backend.preparePlayback(replacing: reused ? request : nil, while: { active }) {
                entered.continuation.yield(())
                for await _ in release.stream { break }
                return request
            }
        }
        for await _ in entered.stream { break }
        if cancelled { preparing.cancel() } else { active = false }
        release.continuation.yield(())
        let accepted = try await preparing.value
        #expect(accepted == nil)
        #expect(reporter.stops == (reused ? 0 : 1))
    }
}
