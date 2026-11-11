// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Rivulet

@MainActor
struct PlaybackStartupReportingTests {
    @MainActor
    private final class Reports {
        var states: [String] = []

        func respond(_ url: URL) -> Data {
            if url.path == "/:/timeline",
               let state = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "state" })?.value {
                states.append(state)
            }
            return Data()
        }
    }

    @Test func endedBeforeStartupDoesNotCloseTheIncomingTimeline() async throws {
        let reports = Reports()
        let reporter = PlexProgressReporter(countedPlay: { _, _, _ in false }, openSession: { _, _, _, _ in }) { url, _ in
            await reports.respond(url)
        }
        var metadata = PlexMetadata()
        metadata.ratingKey = "100"
        metadata.type = "movie"
        metadata.duration = 100000
        let vm = UniversalPlayerViewModel(metadata: metadata, serverURL: "https://plex.invalid", authToken: "test",
                                          plexProgressReporter: reporter)
        let session = try #require(vm.buildRivuletHLSURL(offset: 0)?.headers["X-Plex-Session-Identifier"])
        await reporter.beginPlaybackSession(ratingKey: "100", sessionIdentifier: session,
                                             server: PlexServerAddress(address: "https://plex.invalid", token: "test"))
        vm.plexPlaybackRefresh = {}
        defer { vm.stopPlayback() }
        vm.updatePlaybackState(.loading)
        vm.updatePlaybackState(.ended)
        vm.updatePlaybackState(.playing)
        vm.updatePlaybackState(.paused)
        await vm.reportFinalProgress(time: 20, duration: 100)
        #expect(reports.states == ["playing", "paused", "stopped"])
    }
}

@MainActor
struct PlaybackReloadPositionTests {
    @MainActor
    private final class Reports {
        var timelines: [(state: String, time: String)] = []
        let events = AsyncStream<String>.makeStream()

        func respond(_ url: URL) -> Data {
            guard url.path == "/:/timeline" else { return Data() }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            let state = query.first { $0.name == "state" }?.value ?? ""
            let time = query.first { $0.name == "time" }?.value ?? ""
            timelines.append((state, time))
            events.continuation.yield(state)
            return Data()
        }
    }

    private func makePlayer(_ reports: Reports) -> (UniversalPlayerViewModel, PlexProgressReporter) {
        let reporter = PlexProgressReporter(countedPlay: { _, _, _ in false }, openSession: { _, _, _, _ in }) { url, _ in
            await reports.respond(url)
        }
        var metadata = PlexMetadata()
        metadata.ratingKey = "100"
        metadata.duration = 100000
        metadata.type = "movie"
        let vm = UniversalPlayerViewModel(metadata: metadata, serverURL: "https://plex.invalid", authToken: "test",
                                          plexProgressReporter: reporter)
        vm.plexPlaybackRefresh = {}
        return (vm, reporter)
    }

    @Test(arguments: [false, true])
    func selectedShortSeekReportsReachPlex(_ forced: Bool) async throws {
        let reports = Reports()
        let reporter = PlexProgressReporter(countedPlay: { _, _, _ in false }, openSession: { _, _, _, _ in }) { url, _ in
            await reports.respond(url)
        }
        var metadata = PlexMetadata()
        metadata.ratingKey = "100"
        metadata.type = "movie"
        metadata.duration = 200000
        let vm = UniversalPlayerViewModel(metadata: metadata, serverURL: "https://plex.invalid", authToken: "test", plexProgressReporter: reporter)
        vm.plexPlaybackRefresh = {}
        defer { vm.stopPlayback(); reports.events.continuation.finish() }
        let session = try #require(vm.buildRivuletHLSURL(offset: 0)?.headers["X-Plex-Session-Identifier"])
        await reporter.beginPlaybackSession(ratingKey: "100", sessionIdentifier: session,
                                             server: PlexServerAddress(address: "https://plex.invalid", token: "test"))
        let start: TimeInterval = forced ? 100 : 99
        let target: TimeInterval = forced ? 103 : 101
        vm.updateAetherTime(start)
        vm.updatePlaybackState(.playing)
        vm.reportPlaybackProgress(time: target, force: forced)
        await vm.reportFinalProgress(time: target, duration: 200)
        #expect(reports.timelines.filter { $0.state == "playing" }.map(\.time) ==
                (forced ? ["100000", "103000"] : ["99000", "101000"]))
    }

    @Test(arguments: [0.0, 42.0])
    func pausedReloadKeepsTheResumePointWhileTheNewClockIsZero(_ position: TimeInterval) async throws {
        let reports = Reports()
        defer { reports.events.continuation.finish() }
        let (vm, reporter) = makePlayer(reports)
        defer { vm.stopPlayback() }
        let session = try #require(vm.buildRivuletHLSURL(offset: position)?.headers["X-Plex-Session-Identifier"])
        await reporter.beginPlaybackSession(ratingKey: "100", sessionIdentifier: session,
                                             server: PlexServerAddress(address: "https://plex.invalid", token: "test"))
        let url = URL(fileURLWithPath: "/nonexistent/paused-reload.mp4")
        try vm.loadAVPlayer(url: url, headers: nil, allowEnrichment: false, initialTime: position)
        vm.updatePlaybackState(.playing)
        vm.updatePlaybackState(.paused)
        await vm.enqueueStreamWork { vm in
            do {
                try vm.loadAVPlayer(url: url, headers: nil, allowEnrichment: false, initialTime: position)
            } catch {
                Issue.record(error)
            }
            vm.updatePlaybackState(.paused)
            #expect(vm.player?.currentTime().seconds == 0)
        }.value
        #expect(vm.currentTime == position)
        await vm.reportFinalProgress()
        let expectedTime = position == 0 ? "0" : "42000"
        #expect(reports.timelines.contains { $0.state == "paused" })
        #expect(reports.timelines.allSatisfy { $0.time == expectedTime })
        #expect(reports.timelines.last?.state == "stopped")
    }

    @Test(arguments: [false, true])
    func avPlayerLoadPreservesPositionUnlessExplicitlyReplaced(_ startsFromZero: Bool) async throws {
        let reports = Reports()
        defer { reports.events.continuation.finish() }
        let (vm, _) = makePlayer(reports)
        defer { vm.stopPlayback() }
        vm.updateAetherTime(42)
        vm.updatePlaybackState(.playing)
        let url = URL(fileURLWithPath: "/nonexistent/load-position.mp4")
        if startsFromZero {
            try vm.loadAVPlayer(url: url, headers: nil, allowEnrichment: false, initialTime: 0)
        } else {
            try vm.loadAVPlayer(url: url, headers: nil, allowEnrichment: false)
        }
        #expect(vm.currentTime == (startsFromZero ? 0 : 42))
        await vm.reportFinalProgress()
        #expect(reports.timelines.last?.state == "stopped")
        #expect(reports.timelines.last?.time == (startsFromZero ? "0" : "42000"))
    }

    @Test(arguments: [false, true], [false, true])
    func foregroundReloadRetainsPositionUntilPlaybackResumes(_ paused: Bool, _ resume: Bool) async throws {
        let reports = Reports()
        defer { reports.events.continuation.finish() }
        let (vm, _) = makePlayer(reports)
        vm.heartbeatInterval = .milliseconds(20)
        defer { vm.stopPlayback() }
        vm.updateAetherTime(42)
        vm.updatePlaybackState(.playing)
        if paused { vm.updatePlaybackState(.paused) }
        vm.updatePlaybackState(.loading)
        vm.updateAetherTime(0)
        vm.reportPlaybackProgress(time: vm.currentTime, force: true)
        try await PlaybackReportTimeout.run(for: .seconds(1)) {
            var buffering = 0
            for await state in reports.events.stream where state == "buffering" {
                buffering += 1
                if buffering == 3 { break }
            }
        }
        #expect(vm.currentTime == 42)
        #expect(reports.timelines.filter { $0.state == "buffering" }.allSatisfy { $0.time == "42000" })
        if resume {
            vm.updatePlaybackState(.playing)
            vm.updateAetherTime(48)
            vm.reportPlaybackState(.playing)
            vm.updateAetherTime(0)
        }
        await vm.reportFinalProgress()
        #expect(reports.timelines.last?.state == "stopped")
        #expect(reports.timelines.last?.time == (resume ? "0" : "42000"))
        if resume { #expect(reports.timelines.contains { $0.state == "playing" && $0.time == "48000" }) }
    }
}

@MainActor
@Suite(.serialized)
struct PlaybackHandoffPositionTests {
    @MainActor
    private final class Reports {
        var timelines: [(key: String, state: String, time: String)] = []

        func respond(_ url: URL) -> Data {
            if url.path == "/:/timeline" {
                let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
                func value(_ name: String) -> String { query.first { $0.name == name }?.value ?? "" }
                timelines.append((value("ratingKey"), value("state"), value("time")))
            }
            return Data()
        }
    }

    @Test(arguments: [false, true], [false, true])
    func episodeHandoffDoesNotReportTheOutgoingClockForTheNextEpisode(_ usesAVPlayer: Bool, _ startsDuringLoad: Bool) async throws {
        let defaults = UserDefaults.standard
        let keys = [StreamingQuality.homeKey, StreamingQuality.awayKey]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
        }
        for key in keys { defaults.set(StreamingQuality.original.rawValue, forKey: key) }
        func episode(_ key: String) throws -> PlexMetadata {
            try JSONDecoder().decode(PlexMetadata.self, from: Data("""
            {"ratingKey":"\(key)","type":"episode","parentRatingKey":"season","index":7,"duration":2548096}
            """.utf8))
        }
        let outgoing = try episode("95230"), incoming = try episode("95682")
        let reports = Reports()
        let reporter = PlexProgressReporter(countedPlay: { _, _, _ in false }, openSession: { _, _, _, _ in }) { url, _ in
            await reports.respond(url)
        }
        let vm = UniversalPlayerViewModel(metadata: outgoing, serverURL: "https://plex.invalid", authToken: "test",
                                          plexProgressReporter: reporter)
        defer { vm.stopPlayback() }
        vm.plexPlaybackRefresh = {}
        vm.plexCinemaExtras = { _, _, _, _ in [] }
        vm.plexTranscodeStop = { _, _, _ in }
        vm.plexMetadataFetch = { _, _, _ in incoming }
        vm.plexMetadataLookup = { _, _, _ in incoming }
        if usesAVPlayer {
            try vm.loadAVPlayer(url: URL(fileURLWithPath: "/nonexistent/handoff.mp4"), headers: nil, allowEnrichment: false)
        }
        let outgoingAVItem = vm.player?.currentItem
        vm.playbackRouteStart = { vm, _, _ in
            if usesAVPlayer {
                vm.updateAVPlayerTime(2536.401, for: try #require(outgoingAVItem))
            } else {
                vm.updateAetherTime(2536.401)
            }
            vm.updatePlaybackState(startsDuringLoad ? .playing : .loading)
        }
        vm.updatePlaybackState(.playing)
        vm.updateAetherTime(2536.3)
        await vm.playEpisode(incoming)
        #expect(vm.currentTime == 0)
        if !startsDuringLoad {
            vm.updatePlaybackState(.buffering)
            vm.updatePlaybackState(.playing)
        }
        vm.updateAetherTime(12.1)
        await vm.reportFinalProgress()
        let nextReports = reports.timelines.filter { $0.key == "95682" }
        #expect(nextReports.first?.state == "playing")
        #expect(nextReports.first?.time == "0")
        #expect(nextReports.last?.state == "stopped")
        #expect(nextReports.last?.time == "12100")
        #expect(reports.timelines.contains { $0.key == "95230" && $0.state == "stopped" && $0.time == "2536300" })
    }
}

@MainActor
struct PlexRetryRefreshTests {
    @MainActor
    private final class Requests {
        var events: [String] = []
        var stopFailures = 2

        func respond(_ url: URL) throws -> Data {
            if url.path == "/:/scrobble" {
                events.append("watched")
            } else {
                events.append("stopped")
                if stopFailures > 0 {
                    stopFailures -= 1
                    throw URLError(.timedOut)
                }
            }
            return Data()
        }
    }

    @Test(arguments: [false, true])
    func completionChecksServerCountBeforeCreditsAndFinalScrobbles(_ counted: Bool) async {
        let requests = Requests()
        requests.stopFailures = 0
        let reporter = PlexProgressReporter(countedPlay: { _, key, before in
            #expect(key == "100")
            #expect(before == 3)
            return counted
        }, openSession: { _, _, _, _ in }) { url, _ in
            try await requests.respond(url)
        }
        var metadata = PlexMetadata()
        metadata.ratingKey = "100"
        metadata.viewCount = 3
        metadata.duration = 100000
        let vm = UniversalPlayerViewModel(metadata: metadata, serverURL: "https://plex.invalid", authToken: "test",
                                          plexProgressReporter: reporter)
        vm.plexPlaybackRefresh = {}
        defer { vm.stopPlayback() }
        await vm.markCurrentAsWatched()
        await vm.reportFinalProgress(time: 95, duration: 100)
        #expect(requests.events == (counted ? ["stopped"] : ["watched", "stopped", "watched"]))
    }

    @Test(arguments: [false, true], [false, true])
    func successfulDeferredStopRefreshesAfterWatchedRestoration(_ restoreWatched: Bool, _ counted: Bool) async throws {
        let requests = Requests()
        let reporter = PlexProgressReporter(countedPlay: { _, key, before in
            #expect(key == "100")
            #expect(before == 3)
            return counted
        }, stopRetryDelay: .milliseconds(20), openSession: { _, _, _, _ in }) { url, _ in
            try await requests.respond(url)
        }
        let server = PlexServerAddress(address: "https://plex.invalid", token: "test")
        await reporter.beginPlaybackSession(ratingKey: "100", sessionIdentifier: "session", server: server)
        let result = await reporter.reportProgress(ratingKey: "100", time: 95, duration: 100,
                                                   state: "stopped", forceReport: true, server: server)
        guard case .failed(let pending) = result else {
            Issue.record("Expected the initial stopped report to fail")
            return
        }
        let report = try #require(pending)
        let (refreshes, continuation) = AsyncStream<[String]>.makeStream()
        let observer = NotificationCenter.default.addObserver(forName: .plexDataNeedsRefresh, object: reporter, queue: .main) { _ in
            MainActor.assumeIsolated { continuation.yield(requests.events) }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            continuation.finish()
        }
        await reporter.retryStoppedReport(report, ratingKey: "100", server: server, restoreWatched: restoreWatched, playsBefore: 3)
        let eventsAtRefresh = try await PlaybackReportTimeout.run(for: .seconds(1)) {
            for await events in refreshes { return events }
            return []
        }
        #expect(eventsAtRefresh == ["stopped", "stopped", "stopped"] + (restoreWatched && !counted ? ["watched"] : []))
    }
}

@MainActor
struct PlaybackHLSCancellationTests {
    @Test(arguments: [false, true])
    func chapterLoadingCannotInstallAPlayerAfterExitOrCancellation(_ exits: Bool) async throws {
        let entered = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        defer { entered.continuation.finish(); release.continuation.finish() }
        let metadata = try JSONDecoder().decode(PlexMetadata.self, from: Data("""
        {"ratingKey":"100","type":"movie","duration":100000,
         "Chapter":[{"index":1,"startTimeOffset":0,"endTimeOffset":100000,"thumb":"/chapter/1"}]}
        """.utf8))
        let reporter = PlexProgressReporter(countedPlay: { _, _, _ in false }, openSession: { _, _, _, _ in }, request: { _, _ in Data() })
        let vm = UniversalPlayerViewModel(metadata: metadata, serverURL: "https://plex.invalid", authToken: "test", plexProgressReporter: reporter)
        vm.chapterThumbnailFetch = { _ in
            entered.continuation.yield(())
            for await _ in release.stream { break }
            return nil
        }
        defer { vm.stopPlayback() }
        vm.updateAetherTime(42)
        let loading = Task {
            try await vm.finishHLSSwitch(to: (URL(fileURLWithPath: "/nonexistent/obsolete.m3u8"), [:], nil), resumeTime: 0)
        }
        for await _ in entered.stream { break }
        if exits { vm.stopPlayback() } else { loading.cancel() }
        release.continuation.yield(())
        do {
            try await loading.value
            Issue.record("An obsolete HLS load must be cancelled")
        } catch is CancellationError {} catch { Issue.record(error) }
        #expect(vm.player == nil)
        #expect(vm.currentTime == 42)
    }
}
