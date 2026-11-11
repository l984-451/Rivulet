// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import Foundation
import Testing

#if os(iOS)
@testable import Rivulet_iOS
private typealias Playback = IOSPlexPlayback
#elseif os(macOS)
@testable import Rivulet_Mac
private typealias Playback = MacPlexPlayback
#endif

@Suite(.serialized, .timeLimit(.minutes(1)))
@MainActor
struct NativePlaybackLoadingTests {
    enum Suspension: CaseIterable { case tracks, session, engine }
    enum Interruption: CaseIterable { case exit, replacement, reusedSession }

    @MainActor
    private final class Gate {
        let entered = AsyncStream<Void>.makeStream()
        let released = AsyncStream<Void>.makeStream()
        var used = false

        func waitOnce() async {
            guard !used else { return }
            used = true
            entered.continuation.yield(())
            for await _ in released.stream { break }
        }

        func waitUntilEntered() async {
            for await _ in entered.stream { break }
        }

        func release() { released.continuation.finish() }
    }

    @Test(arguments: Suspension.allCases, Interruption.allCases)
    func interruptedLoadCannotAdvanceOrRetireTheReplacement(_ suspension: Suspension, _ interruption: Interruption) async throws {
        let original = try request(key: "first", session: "old-session")
        let replacement = try request(key: "second", session: "new-session")
        let backend = Backend(replacement: replacement)
        let gate = Gate()
        var events: [String] = []
        backend.select = { request in
            events.append("tracks:\(request.id)")
            if suspension == .tracks { await gate.waitOnce() }
        }
        backend.open = { request in
            events.append("session:\(request.id)")
            if suspension == .session { await gate.waitOnce() }
        }
        let nextEngine = AsyncStream<Void>.makeStream()
        defer { nextEngine.continuation.finish(); gate.release() }
        let playback = Playback(request: original, plex: backend,
                                queue: PlayQueue(entries: [original.item, replacement.item], startingAt: 0)) { _, request, _ in
            events.append("engine:\(request.id)")
            if suspension == .engine { await gate.waitOnce() }
            if request.id == replacement.id { nextEngine.continuation.yield(()) }
        }
        var idleEvents = 0
        let observation = playback.player.$state.dropFirst().sink { if $0 == .idle { idleEvents += 1 } }
        defer { observation.cancel(); playback.end() }
        let initialLoad = Task { await playback.begin() }
        await gate.waitUntilEntered()
        switch interruption {
        case .exit:
            playback.end()
        case .replacement:
            playback.playEntry(at: 1)
            for await _ in nextEngine.stream { break }
        case .reusedSession:
            await playback.begin()
        }
        let eventsBeforeRelease = events
        let stopsBeforeRelease = backend.stoppedSessions.count
        let idleBeforeRelease = idleEvents
        gate.release()
        await initialLoad.value

        #expect(events == eventsBeforeRelease, "The obsolete load must not advance to another operation")
        if interruption == .reusedSession {
            #expect(backend.stoppedSessions.count == stopsBeforeRelease)
        } else {
            #expect(backend.stoppedSessions.contains("old-session"))
            #expect(!backend.stoppedSessions.contains("new-session"))
        }
        if interruption != .exit {
            #expect(idleEvents == idleBeforeRelease, "An obsolete load must not stop the replacement player")
        } else if suspension == .engine {
            #expect(idleEvents > idleBeforeRelease, "An engine load returning after exit must be stopped")
        }
    }

    private func request(key: String, session: String) throws -> PlexPlaybackRequest {
        let json = """
        {"ratingKey":"\(key)","type":"episode","title":"Test","duration":100000,
         "Media":[{"id":1,"Part":[{"id":1,"Stream":[{"id":11,"streamType":2,"codec":"aac","languageCode":"eng"}]}]}]}
        """
        let item = try JSONDecoder().decode(PlexMetadata.self, from: Data(json.utf8))
        return PlexPlaybackRequest(item: item, url: URL(string: "https://media.invalid/video.m3u8")!, headers: [:],
                                   markers: [], serverURL: "https://media.invalid", token: "test", quality: .original,
                                   plan: .transcode(QualityStep(kbps: 4000, videoResolution: "1280x720")),
                                   sourceKbps: nil, mediaIndex: 0, transcodeSessionID: session)
    }

    @MainActor
    private final class Backend: PlayerBackend {
        let replacement: PlexPlaybackRequest
        var select: (PlexPlaybackRequest) async -> Void = { _ in }
        var open: (PlexPlaybackRequest) async -> Void = { _ in }
        var stoppedSessions: [String] = []
        init(replacement: PlexPlaybackRequest) { self.replacement = replacement }
        func upNextPlayback(for item: PlexMetadata, quality: StreamingQuality?, previous: PlexPlaybackRequest?) async throws -> PlexPlaybackRequest { replacement }
        func featurePlayback(for item: PlexMetadata, version: VersionChoice, previous: PlexPlaybackRequest?) async throws -> PlexPlaybackRequest { replacement }
        func reloadedPlayback(of request: PlexPlaybackRequest, quality: StreamingQuality, plan: StreamPlan?, at time: TimeInterval, streams: TrackPicks?) async throws -> PlexPlaybackRequest { replacement }
        func requestWithNewSubtitle(_ request: PlexPlaybackRequest, known: Set<Int>, at time: TimeInterval) async throws -> (request: PlexPlaybackRequest, trackID: Int)? { nil }
        func reportProgress(for request: PlexPlaybackRequest, time: TimeInterval, state: String) async -> String? { nil }
        func markWatched(_ request: PlexPlaybackRequest) async {}
        func nextEpisode(after episode: PlexMetadata, in request: PlexPlaybackRequest) async -> PlexMetadata? { nil }
        func stopTranscode(_ request: PlexPlaybackRequest) async { if let id = request.transcodeSessionID { stoppedSessions.append(id) } }
        func openPlaySession(_ request: PlexPlaybackRequest) async { await open(request) }
        func selectStream(_ picks: TrackPicks, in request: PlexPlaybackRequest) async { await select(request) }
        func artworkURL(for item: PlexMetadata, kind: PlexSession.ArtworkKind, width: Int, height: Int) -> URL? { nil }
        func imageURL(path: String?, width: Int, height: Int, serverID: String?) -> URL? { nil }
        func watchStateDidChange() async {}
    }
}
