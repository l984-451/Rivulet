// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import os

nonisolated enum SiloPlaybackRenewalSignal: Error, Sendable { case sessionExpired }

nonisolated enum SiloPlaybackRestoreIntent {
    static func quality(original: MediaQualityPreference?, current: MediaQualityPreference) -> MediaQualityPreference {
        original ?? current
    }
}

/// One replacement attempt per active reservation. A cancelled waiter cannot
/// turn a stale or administrator-ended session into a new playback attempt.
actor SiloPlaybackSessionRenewal {
    static let shared = SiloPlaybackSessionRenewal()
    private var pending: [ObjectIdentifier: Task<StreamInfo, Error>] = [:]

    nonisolated static func permitsFreshAttempt(after error: Error) -> Bool {
        if let signal = error as? SiloPlaybackRenewalSignal, case .sessionExpired = signal { return true }
        guard let problem = error as? SiloAPIError else { return false }
        if case .renewalRequired = SiloPlaybackSessionFault.classify(problem) { return true }
        return false
    }

    func run(lifetime: SiloPlaybackLifetime, operation: @escaping @Sendable () async throws -> StreamInfo) async throws -> StreamInfo {
        let key = ObjectIdentifier(lifetime)
        if let existing = pending[key] { return try await existing.value }
        let task = Task { try await operation() }
        pending[key] = task
        defer { pending.removeValue(forKey: key) }
        return try await task.value
    }
}

nonisolated struct SiloPlaybackConnection: Decodable, Sendable {
    struct LearnedLimit: Decodable, Sendable {
        let kbps: Int
        let observedAt: String
        let expiresAt: String
    }
    let connection: String
    let learnedLimit: LearnedLimit?
    let autoBudgetKbps: Int?
}

nonisolated struct SiloBufferingObservation: Sendable {
    enum Source: String, Sendable { case probe, observedRebuffer = "observed_rebuffer" }
    let estimateKbps: Int
    let source: Source
    let observedThroughputKbps: Int?

    init(estimateKbps: Int, source: Source, observedThroughputKbps: Int? = nil) throws {
        guard (100...1_000_000).contains(estimateKbps),
              observedThroughputKbps.map({ (100...1_000_000).contains($0) }) ?? true,
              source == .observedRebuffer || observedThroughputKbps == nil else {
            throw MediaProviderError.backendSpecific(underlying: "Invalid Silo bandwidth observation.")
        }
        self.estimateKbps = estimateKbps
        self.source = source
        self.observedThroughputKbps = observedThroughputKbps
    }
}

nonisolated struct SiloPlaybackPlanSummary: Encodable, Sendable {
    let installationId: String
    let eventId: String
    let protocolVersion = 3
    let playbackAttemptId: String
    let sessionId: String
    let planId: String
    let planAttemptKey: String
    let event = "plan_summary"
    let diagnostics: [String: String]
}

extension SiloProvider {
    private func renewalAuthorityIsCurrent() async -> Bool {
        await MainActor.run {
            guard let account = SiloSession.account else { return authorityRevision == 0 }
            return account.providerID == id && SiloSession.authorityRevision == authorityRevision
        }
    }

    func renewPlaybackSession(for itemRef: MediaItemRef, current: StreamInfo,
                              position: TimeInterval, after terminal: SiloPlaybackTerminal) async throws -> StreamInfo {
        guard terminal.reason == "session_expired", terminal.retryable else {
            throw MediaProviderError.backendSpecific(underlying: terminal.message)
        }
        return try await renewPlaybackSession(for: itemRef, current: current, position: position,
                                              after: SiloPlaybackRenewalSignal.sessionExpired)
    }

    /// The server's account/device/connection reading; the UI must not infer a
    /// learned limit from a bitrate label or another profile's connection.
    func playbackConnection() async throws -> SiloPlaybackConnection {
        let capabilities: SiloPlaybackCapabilities = try await client.get("playback/capabilities")
        guard capabilities.allowed, capabilities.features.contains("buffering_quality_v1") else {
            throw MediaProviderError.notPlayable
        }
        return try await client.get("playback/connection")
    }

    func supportsBufferingQuality(for current: StreamInfo) -> Bool {
        guard let sessionID = current.playSessionID,
              let context = playbackSessions.withLock({ $0[sessionID] }),
              context.ref.providerID == id, context.fileID == current.source.id,
              context.lifetime.isActive else { return false }
        return context.request.clientFeatures.contains("buffering_quality_v1")
            && context.serverFeatures.contains("buffering_quality_v1")
    }

    /// Applies a measured Auto reduction or clears the learned limit and
    /// replans the original quality. The returned stream must replace the
    /// player source and its progress reporter must be rebound by the caller.
    func replanBufferingQuality(for itemRef: MediaItemRef, current: StreamInfo, position: TimeInterval,
                                observation: SiloBufferingObservation?, restore: Bool = false,
                                restoreQuality: MediaQualityPreference? = nil) async throws -> StreamInfo {
        guard position.isFinite, position >= 0, let sessionID = current.playSessionID,
              client.profileID == profileID else { throw MediaProviderError.notPlayable }
        let context = try playbackSessions.withLock { sessions -> SiloPlaybackSession in
            guard var value = sessions[sessionID], value.ref == itemRef, value.fileID == current.source.id,
                  value.lifetime.isActive, !value.isReplanning,
                  value.request.clientFeatures.contains("buffering_quality_v1"),
                  value.serverFeatures.contains("buffering_quality_v1") else { throw MediaProviderError.notPlayable }
            guard restore || value.request.qualityIntent == .automatic else {
                throw MediaProviderError.backendSpecific(underlying: "A fixed Silo quality cannot be reduced automatically.")
            }
            guard restore || value.request.learnedLimit != "ignore" else {
                throw MediaProviderError.backendSpecific(underlying: "Silo buffering reductions are disabled for this playback.")
            }
            value.isReplanning = true
            sessions[sessionID] = value
            return value
        }
        defer { playbackSessions.withLock { sessions in
            if sessions[sessionID]?.lifetime === context.lifetime { sessions[sessionID]?.isReplanning = false }
        } }
        var request = context.request
        if restore { request.qualityPreference = SiloPlaybackRestoreIntent.quality(
            original: restoreQuality, current: context.request.qualityIntent).serverValue }
        var body = SiloPlaybackReplan(installationId: context.installationID,
            playbackAttemptId: request.playbackAttemptId, replanRequestId: UUID().uuidString,
            failedPlanId: context.plan.planId, planAttemptId: UUID().uuidString,
            planAttemptKey: context.plan.planAttemptKey, positionSeconds: position,
            selectedTracks: context.plan.selectedTracks, clientCapabilities: request.clientCapabilities,
            clientPlaybackContext: request.clientPlaybackContext, bandwidthCapKbps: request.bandwidthCapKbps,
            operation: "quality_change", qualityPreference: request.qualityIntent)
        body.clientFeatures = request.clientFeatures
        if restore { body.learnedLimit = "clear" }
        else { body.learnedLimit = request.learnedLimit }
        if let observation, !restore {
            body.bandwidthEstimateKbps = observation.estimateKbps
            body.bandwidthEstimateSource = observation.source.rawValue
            body.observedThroughputKbps = observation.observedThroughputKbps
        }
        let decision: SiloPlaybackDecision = try await client.post("playback/\(Self.pathComponent(sessionID))/replan", body: body)
        guard decision.outcome == "playable", decision.protocolVersion == 3,
              let plan = decision.playbackPlan, (decision.sessionId ?? plan.sessionId) == sessionID else {
            throw MediaProviderError.backendSpecific(underlying: decision.terminal?.message ?? "Silo could not adjust playback quality.")
        }
        guard context.lifetime.isActive,
              playbackSessions.withLock({ $0[sessionID]?.plan.planId == context.plan.planId && $0[sessionID]?.lifetime === context.lifetime }) else {
            throw MediaProviderError.notFound
        }
        let watch: SiloItem = try await client.get("watch/\(Self.pathComponent(itemRef.itemID))",
            [URLQueryItem(name: "file_id", value: plan.effectiveMediaFileId)])
        request.bandwidthEstimateKbps = restore ? nil : observation?.estimateKbps
        if restore { request.learnedLimit = context.request.learnedLimit == "ignore" ? "ignore" : nil }
        return try await materialize(plan, sessionID: sessionID, ref: itemRef, request: request,
            watch: watch, expectedLifetime: context.lifetime, serverFeatures: decision.serverFeatures ?? context.serverFeatures)
    }

    func restoreQuality(for itemRef: MediaItemRef, current: StreamInfo, position: TimeInterval,
                        quality: MediaQualityPreference = .automatic) async throws -> StreamInfo {
        try await replanBufferingQuality(for: itemRef, current: current, position: position,
                                         observation: nil, restore: true, restoreQuality: quality)
    }

    /// Reports only metrics actually measured for the plan being replaced.
    func reportPlanSummary(for current: StreamInfo, diagnostics: [String: String]) async throws {
        guard let sessionID = current.playSessionID,
              let context = playbackSessions.withLock({ $0[sessionID] }),
              context.lifetime.isActive, context.serverFeatures.contains("playback_plan_summary_v1"),
              context.request.clientFeatures.contains("playback_plan_summary_v1") else { return }
        let allowed: Set<String> = ["played_ms", "stall_count", "stall_total_ms", "stall_longest_ms",
            "delivered_kbps", "buffering_mode", "buffering_action", "throughput_kbps", "bandwidth_estimate_kbps"]
        let measured = diagnostics.filter { allowed.contains($0.key) && $0.value.count <= 256 }
        guard !measured.isEmpty else { return }
        let body = SiloPlaybackPlanSummary(installationId: context.installationID, eventId: UUID().uuidString,
            playbackAttemptId: context.request.playbackAttemptId, sessionId: sessionID,
            planId: context.plan.planId, planAttemptKey: context.plan.planAttemptKey, diagnostics: measured)
        try await client.post("playback/route-events", body: body)
    }

    /// Called only after an active stream reports session missing/expired or
    /// installation change. 410 is terminal and never starts another attempt.
    func renewPlaybackSession(for itemRef: MediaItemRef, current: StreamInfo,
                              position: TimeInterval, after error: Error) async throws -> StreamInfo {
        guard let sessionID = current.playSessionID, position.isFinite, position >= 0,
              let context = playbackSessions.withLock({ $0[sessionID] }), context.ref == itemRef,
              context.fileID == current.source.id, context.lifetime.isActive, !context.lifetime.isEnded else { throw MediaProviderError.notFound }
        guard SiloPlaybackSessionRenewal.permitsFreshAttempt(after: error) else { throw error }
        guard let reporter = context.lifetime.reporter, await reporter.hasPlayed else {
            throw MediaProviderError.notFound
        }
        return try await SiloPlaybackSessionRenewal.shared.run(lifetime: context.lifetime) { [self] in
            guard await renewalAuthorityIsCurrent(), context.lifetime.isActive, !context.lifetime.isEnded,
                  playbackSessions.withLock({ $0[sessionID]?.lifetime === context.lifetime }) else { throw MediaProviderError.notFound }
            try playbackSessions.withLock { sessions in
                guard var active = sessions[sessionID], active.lifetime === context.lifetime,
                      active.plan.planId == context.plan.planId,
                      !active.isReplanning else { throw MediaProviderError.notFound }
                active.isReplanning = true
                sessions[sessionID] = active
            }
            let replacement: StreamInfo
            do {
                replacement = try await startPlayback(itemRef, sourceID: context.fileID, startTime: position,
                    maxBitrate: context.request.bandwidthCapKbps.flatMap { cap in
                        let value = cap.multipliedReportingOverflow(by: 1_000)
                        return value.overflow ? nil : value.partialValue
                    },
                    audioIndex: context.plan.selectedTracks.audio?.index,
                    subtitleIndex: context.plan.selectedTracks.subtitle?.index ?? -1,
                    transcodeOnly: false, quality: context.request.qualityIntent,
                    ignoreLearnedLimit: context.request.learnedLimit == "ignore")
            } catch {
                context.lifetime.deactivate()
                context.relay.stop()
                playbackSessions.withLock { sessions in
                    if sessions[sessionID]?.lifetime === context.lifetime { _ = sessions.removeValue(forKey: sessionID) }
                }
                throw error
            }
            guard await renewalAuthorityIsCurrent(), context.lifetime.isActive, !context.lifetime.isEnded,
                  playbackSessions.withLock({ $0[sessionID]?.lifetime === context.lifetime }) else {
                if let replacementID = replacement.playSessionID,
                   let new = playbackSessions.withLock({ $0.removeValue(forKey: replacementID) }) {
                    new.lifetime.deactivate(); new.relay.stop()
                    let _: SiloPlaybackMutation? = try? await client.delete("playback/\(Self.pathComponent(replacementID))",
                        body: SiloPlaybackDiscard(installationId: new.installationID, stopId: UUID().uuidString))
                }
                throw MediaProviderError.notFound
            }
            context.lifetime.deactivate()
            context.relay.stop()
            playbackSessions.withLock { _ = $0.removeValue(forKey: sessionID) }
            return replacement
        }
    }
}
