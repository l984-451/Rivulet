// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import Testing
@testable import Rivulet

@MainActor
struct ProviderPlayerReportingTests {
    @MainActor
    private final class Reporter: Rivulet.ProgressReporter {
        var slowOperation: String?
        var events: [String] = []
        var onEvent: ((String) -> Void)?

        private func record(_ operation: String) async throws {
            events.append(operation)
            onEvent?(operation)
            guard operation == slowOperation else { return }
            do {
                try await Task.sleep(for: .milliseconds(200))
                events.append("missedDeadline")
            } catch {
                events.append("cancelled:\(operation)")
                slowOperation = nil
                throw error
            }
        }

        func start(position: TimeInterval) async throws { try await record("start") }
        func progress(position: TimeInterval) async { try? await record("progress") }
        func paused(at position: TimeInterval) async { try? await record("paused") }
        func stopped(at position: TimeInterval) async { try? await record("stopped") }
    }

    private func player(_ reporter: Reporter) -> (UniversalPlayerViewModel, StubMediaProvider) {
        let provider = StubMediaProvider(id: "jellyfin:test", kind: .jellyfin)
        provider.reporter = reporter
        return (player(provider), provider)
    }

    private func player(_ provider: any MediaProvider) -> UniversalPlayerViewModel {
        let item = JellyfinFixtures.mediaItem("item", providerID: provider.id)
        let source = MediaSource(id: "source", container: "mp4", duration: 100, bitrate: nil,
                                 fileSize: nil, fileName: nil, videoResolution: nil, videoTracks: [],
                                 audioTracks: [], subtitleTracks: [], streamKind: .directPlay, streamURL: nil)
        let detail = MediaItemDetail(item: item, tagline: nil, genres: [], studios: [], cast: [],
                                    directors: [], writers: [], chapters: [], mediaSources: [source],
                                    trailerURL: nil, contentRating: nil, nextEpisode: nil, collections: [])
        let playback = ProviderPlayback(provider: provider, item: item, detail: detail,
                                        stream: StreamInfo(source: source, playSessionID: "session", trackInfoAvailable: true),
                                        extras: PlaybackExtras())
        let vm = UniversalPlayerViewModel(providerPlayback: playback, startOffset: nil)
        vm.providerReportTimeout = .milliseconds(20)
        return vm
    }

    @Test(arguments: ["start", "progress", "paused", "stopped"])
    func slowReportsReleaseFinalReporting(_ operation: String) async {
        let reporter = Reporter()
        reporter.slowOperation = operation
        let (vm, provider) = player(reporter)
        defer { vm.stopPlayback() }
        vm.reportPlaybackState(.playing)
        vm.reportPlaybackProgress(time: 40, force: true)
        vm.reportPlaybackState(.paused)
        await vm.reportFinalProgress(time: 95, duration: 100)
        #expect(reporter.events.contains("cancelled:\(operation)"))
        #expect(!reporter.events.contains("missedDeadline"))
        #expect(reporter.events.filter { $0 == "stopped" }.count == 1)
        #expect(provider.markedPlayed.count == 1)
        if operation == "start" {
            #expect(Array(reporter.events.prefix(4)) == ["start", "cancelled:start", "start", "progress"])
        }
    }

    @Test(arguments: [false, true])
    func pausedAndStalledSessionsKeepReportingUntilStopped(_ paused: Bool) async throws {
        let reporter = Reporter()
        let (vm, _) = player(reporter)
        defer { vm.stopPlayback() }
        vm.heartbeatInterval = .milliseconds(20)
        let (events, continuation) = AsyncStream<String>.makeStream()
        reporter.onEvent = { continuation.yield($0) }
        defer { continuation.finish() }
        vm.reportPlaybackState(.playing)
        vm.reportPlaybackState(paused ? .paused : .buffering)
        let expected = paused ? "paused" : "progress"
        let received = try await PlaybackReportTimeout.run(for: .seconds(1)) {
            var received = 0
            for await event in events where event == expected {
                received += 1
                if received == 2 { break }
            }
            return received
        }
        #expect(received == 2)
        await vm.reportFinalProgress(time: 20, duration: 100)
        let stoppedEvents = reporter.events
        vm.reportPlaybackState(.playing)
        vm.reportPlaybackState(.buffering)
        vm.reportPlaybackProgress(time: 40, force: true)
        await vm.reportFinalProgress(time: 40, duration: 100)
        #expect(reporter.events == stoppedEvents)
        #expect(reporter.events.last == "stopped")
    }

    @Test(arguments: ["jellyfin", "emby"], [false, true])
    func watchedUpdatesHaveADeadline(_ kind: String, _ exiting: Bool) async throws {
        let url = try #require(URL(string: "https://media.invalid"))
        await confirmation("watched update cancelled", expectedCount: 1) { cancelled in
            let transport: @Sendable (URLRequest) async throws -> (Data, URLResponse) = { request in
                let url = try #require(request.url)
                if url.path.contains("PlayedItems") {
                    do { try await Task.sleep(for: .milliseconds(200)) }
                    catch { cancelled(); throw error }
                    Issue.record("Watched update outlived its deadline")
                }
                let response = try #require(HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil))
                return (Data(), response)
            }
            let provider: any MediaProvider
            if kind == "jellyfin" {
                provider = JellyfinProvider(serverID: "test", displayName: "Test", userID: "user",
                                             client: JellyfinClient(baseURL: url, token: "test", transport: transport))
            } else {
                provider = EmbyProvider(serverID: "test", displayName: "Test", userID: "user", policy: EmbySession.Policy(),
                                        client: EmbyClient(baseURL: url, token: "test", transport: transport))
            }
            let vm = player(provider)
            defer { vm.stopPlayback() }
            if exiting { await vm.reportFinalProgress(time: 95, duration: 100) }
            else { await vm.markCurrentAsWatched() }
        }
    }

    @Test func pausedLoadingKeepsPausedReportsAndEndRejectsLateCallbacks() async {
        let reporter = Reporter()
        let (vm, _) = player(reporter)
        defer { vm.stopPlayback() }
        vm.reportPlaybackState(.playing)
        vm.reportPlaybackState(.paused)
        vm.reportPlaybackState(.loading)
        vm.reportPlaybackState(.ended)
        vm.reportPlaybackState(.playing)
        vm.reportPlaybackState(.buffering)
        await vm.reportFinalProgress(time: 20, duration: 100)
        #expect(reporter.events == ["start", "paused", "paused", "stopped"])
    }

    @Test func pausedStreamReplacementOpensAndKeepsTheNewSessionPaused() async throws {
        let reporter = Reporter()
        let (vm, provider) = player(reporter)
        defer { vm.stopPlayback() }
        vm.heartbeatInterval = .milliseconds(20)
        vm.updatePlaybackState(.playing)
        vm.updatePlaybackState(.paused)
        guard case .provider(let playback) = vm.source else { Issue.record("Missing provider"); return }
        provider.transcodeResult = StreamInfo(source: playback.stream.source, playSessionID: "replacement", trackInfoAvailable: true)
        _ = try await vm.switchToProviderTranscode(resumeTime: 40)
        let (events, continuation) = AsyncStream<String>.makeStream()
        reporter.onEvent = { continuation.yield($0) }
        defer { continuation.finish() }
        vm.updatePlaybackState(.loading)
        let received = try await PlaybackReportTimeout.run(for: .seconds(1)) {
            var received: [String] = []
            for await event in events {
                received.append(event)
                if received.count == 3 { break }
            }
            return received
        }
        #expect(received == ["start", "paused", "paused"])
        await vm.reportFinalProgress(time: 40, duration: 100)
        #expect(reporter.events.filter { $0 == "stopped" }.count == 2)
    }

}
