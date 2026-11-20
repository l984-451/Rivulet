// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2026 Bain Gurley

import Foundation

/// A Plex recording in progress on the tuned channel, playable from its first
/// segment (#444). A tune on a channel Plex is recording joins the recorder's
/// own session, whose direct-play playlist at `offset=0` lists every segment
/// since the recording began (measured on PMS 1.43). The transcode leg
/// (`start.m3u8`) cannot start there, so only a direct-play grant qualifies.
nonisolated struct LiveRecordingStart: Sendable, Equatable {
    let recording: LiveTVScheduledRecording
    /// The tuned session's playlist from the recording's first segment.
    let url: URL
    /// When that first segment aired. A session joined there trails live by
    /// the time since, which the player adds to its own "behind live".
    let firstSegmentAired: Date

    /// `url` asked from offset 0, or nil when it is not a Plex session playlist.
    @MainActor static func playlistFromStart(_ url: URL) -> URL? {
        guard url.path.hasPrefix("/livetv/sessions/"), url.pathExtension == "m3u8",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var items = (components.queryItems ?? []).filter { $0.name != "offset" }
        items.insert(URLQueryItem(name: "offset", value: "0"), at: 0)
        components.queryItems = items
        return PlexLiveTVChannel.finalizedLiveURL(components)
    }

    /// When the first segment of the session behind `url` aired. A direct-play
    /// grant's `offset` is how far its edge is from that segment (it matched the
    /// playlists' program dates to 0.1 s), so the first segment aired that long ago.
    static func firstSegmentAired(tunedURL url: URL, at date: Date) -> Date {
        let offset = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "offset" }?.value.flatMap(Double.init) ?? 0
        return date.addingTimeInterval(-max(0, offset))
    }

    /// The recording Plex is making on `channelId` at `date`.
    static func recordingInProgress(on channelId: String, in recordings: [LiveTVScheduledRecording],
                                    at date: Date) -> LiveTVScheduledRecording? {
        recordings.first {
            $0.status == .recording && $0.channelId == channelId && $0.startTime <= date && date < $0.endTime
        }
    }
}

extension LiveTVDataStore {
    /// `resolveStreamURL`, plus where the recording in progress on the channel
    /// starts when the tuned session can play from it. Recordings refresh
    /// alongside the tune: one may have begun since the guide loaded.
    func resolveStreamURLAndRecordingStart(
        for channel: UnifiedChannel
    ) async throws -> (url: URL?, recordingStart: LiveRecordingStart?) {
        let refresh = channel.sourceType == .plex ? Task { await refreshScheduledRecordings() } : nil
        guard let url = try await resolveStreamURL(for: channel) else { return (nil, nil) }
        guard let refresh, let fromStart = LiveRecordingStart.playlistFromStart(url) else { return (url, nil) }
        await refresh.value
        let now = Date()
        guard let recording = LiveRecordingStart.recordingInProgress(on: channel.id, in: scheduledRecordings,
                                                                     at: now) else { return (url, nil) }
        return (url, LiveRecordingStart(recording: recording, url: fromStart,
                                        firstSegmentAired: LiveRecordingStart.firstSegmentAired(tunedURL: url, at: now)))
    }
}

/// One Start from Beginning or Watch Live question. Answered once: by the
/// viewer, or Watch Live when the join waiting on it is cancelled.
@MainActor
final class LiveStartQuestion: Identifiable {
    let recording: LiveTVScheduledRecording
    private var continuation: CheckedContinuation<Bool, Never>?
    private var answer: Bool?

    init(recording: LiveTVScheduledRecording) {
        self.recording = recording
    }

    func answer(startsFromBeginning: Bool) {
        guard answer == nil else { return }
        answer = startsFromBeginning
        continuation?.resume(returning: startsFromBeginning)
        continuation = nil
    }

    /// Shows the question with `present` and waits for the answer.
    func ask(present: () -> Void) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let answer {
                    continuation.resume(returning: answer)
                    return
                }
                self.continuation = continuation
                present()
            }
        } onCancel: {
            Task { @MainActor in self.answer(startsFromBeginning: false) }
        }
    }
}
