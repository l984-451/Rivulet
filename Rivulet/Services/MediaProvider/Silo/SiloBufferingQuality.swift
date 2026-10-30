// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Session-local policy. The host supplies monotonic elapsed milliseconds and only network
/// waits; seeks, pauses, renderer waits and reloads must not be reported as stalls.
nonisolated struct SiloBufferingQuality {
    enum Decision: Equatable, Sendable {
        case none
        case ask(Lowering)
        case lower(Lowering)
    }

    struct Lowering: Equatable, Sendable {
        /// An exact server-offered ID for a manual pick; Auto stays Auto and sends an estimate.
        let quality: MediaQualityPreference
        let bandwidthEstimateKbps: Int?
        let observedThroughputKbps: Int?
    }

    struct Restore: Equatable, Sendable {
        let quality: MediaQualityPreference
        /// The transport clears the server-learned limit when this is true.
        let clearLearnedLimit: Bool
    }

    private(set) var requestedQuality: MediaQualityPreference
    private(set) var policy: BufferingQualityPolicy
    private(set) var pendingOffer: Lowering?
    private(set) var keptEstimateKbps: Int?
    private(set) var hasLowered = false
    private var stallStartMs: Int?
    private var recentStalls: [Int] = []
    private var handledWindow = false
    private var declined = false
    private var pendingReduction = false
    private var pendingRequest: Lowering?
    private var previousActiveQualityID: String?
    private var previousLimitKbps: Int?
    private var observedActiveQualityID: String?
    private var observedLimitKbps: Int?
    private var graceEndsAtMs: Int?
    private var hasPlayed = false

    init(policy: BufferingQualityPolicy, requestedQuality: MediaQualityPreference = .automatic) {
        self.policy = policy
        self.requestedQuality = requestedQuality
    }

    mutating func adopt(status: MediaNegotiatedStatus) {
        if pendingReduction, pendingRequest != nil {
            let unavailable = status.degradationWarnings.contains { $0.code == "quality_reduction_unavailable" }
            let changedQuality = status.activeQualityID != previousActiveQualityID
            let changedLimit = status.bandwidthLimit?.kbps != previousLimitKbps
            let effective = !unavailable && (changedQuality || changedLimit)
            hasLowered = hasLowered || effective
            if !effective { keptEstimateKbps = nil }
            pendingReduction = false
            pendingRequest = nil
        }
        // A new plan starts a new observation window. Its loading is warm-up.
        hasPlayed = false
        graceEndsAtMs = nil
        recentStalls.removeAll()
        stallStartMs = nil
        handledWindow = false
    }

    /// Call on the first rendered frame of an adopted plan. The native grace begins here.
    mutating func playing(atMs now: Int) {
        hasPlayed = true
        if graceEndsAtMs == nil { graceEndsAtMs = now + 10_000 }
    }

    /// Seek and plan reload waits are warm-up, not network rebuffer evidence.
    mutating func warmUpBegan() {
        hasPlayed = false
        stallStartMs = nil
        recentStalls.removeAll()
        graceEndsAtMs = nil
        handledWindow = false
    }

    mutating func setPolicy(_ value: BufferingQualityPolicy) {
        policy = value
        pendingOffer = nil
        recentStalls.removeAll()
        stallStartMs = nil
        handledWindow = false
    }

    /// A viewer selection wins over any pending automatic action or consent request.
    mutating func manualQualityChanged(to quality: MediaQualityPreference) {
        requestedQuality = quality
        pendingOffer = nil
        pendingReduction = false
        pendingRequest = nil
        keptEstimateKbps = nil
        hasLowered = false
        declined = false
        handledWindow = false
        recentStalls.removeAll()
        stallStartMs = nil
    }

    mutating func stallBegan(atMs now: Int) {
        guard hasPlayed, stallStartMs == nil else { return }
        stallStartMs = max(now, graceEndsAtMs ?? now)
    }

    /// Schedule the continuing-stall check after both first-frame grace and six seconds of evidence.
    var continuousStallDeadlineMs: Int? {
        stallStartMs.map { $0 + 6_000 }
    }

    /// Call during a continuing stall so a single long wait can trigger at six seconds.
    mutating func stallContinues(atMs now: Int, status: MediaNegotiatedStatus,
                                 deliveredKbps: Int?, observedThroughputKbps: Int? = nil) -> Decision {
        guard let deadline = continuousStallDeadlineMs, now >= deadline else { return .none }
        return evaluate(status: status, deliveredKbps: deliveredKbps, observedThroughputKbps: observedThroughputKbps)
    }

    mutating func stallEnded(atMs now: Int, status: MediaNegotiatedStatus,
                             deliveredKbps: Int?, observedThroughputKbps: Int? = nil) -> Decision {
        guard let start = stallStartMs else { return .none }
        stallStartMs = nil
        guard now >= start + 1_000 else { return .none }
        recentStalls.append(now)
        recentStalls.removeAll { $0 <= now - 120_000 }
        guard now >= start + 6_000 || recentStalls.count >= 2 else { return .none }
        return evaluate(status: status, deliveredKbps: deliveredKbps, observedThroughputKbps: observedThroughputKbps)
    }

    private mutating func evaluate(status: MediaNegotiatedStatus, deliveredKbps: Int?,
                                   observedThroughputKbps: Int?) -> Decision {
        guard !handledWindow, !declined, pendingOffer == nil, !pendingReduction else { return .none }
        observedActiveQualityID = status.activeQualityID
        observedLimitKbps = status.bandwidthLimit?.kbps
        handledWindow = true
        guard policy != .never, let lowering = lowerRequest(status: status, deliveredKbps: deliveredKbps,
                                                             observedThroughputKbps: observedThroughputKbps) else { return .none }
        if policy == .ask || requestedQuality != .automatic {
            pendingOffer = lowering
            return .ask(lowering)
        }
        markLowering(lowering)
        return .lower(lowering)
    }

    /// Accepted prompts return the same exact request once; late answers are inert.
    mutating func answer(accept: Bool) -> Decision {
        guard let offer = pendingOffer else { return .none }
        pendingOffer = nil
        if accept { markLowering(offer); return .lower(offer) }
        declined = true
        return .none
    }

    mutating func cancelOffer() {
        pendingOffer = nil
        declined = true
    }

    /// A failed or cancelled transport request may be retried only after fresh stall evidence.
    mutating func reductionFailed() {
        pendingReduction = false
        pendingRequest = nil
        keptEstimateKbps = nil
        handledWindow = false
        recentStalls.removeAll()
    }

    func restore(status: MediaNegotiatedStatus) -> Restore? {
        guard hasLowered || keptEstimateKbps != nil || status.bandwidthLimit != nil else { return nil }
        return Restore(quality: requestedQuality, clearLearnedLimit: status.bandwidthLimit != nil)
    }

    mutating func didRequestRestore() {
        pendingOffer = nil
        pendingReduction = false
        pendingRequest = nil
        keptEstimateKbps = nil
        hasLowered = false
        declined = true
        recentStalls.removeAll()
        stallStartMs = nil
    }

    private mutating func markLowering(_ request: Lowering) {
        pendingReduction = true
        pendingRequest = request
        previousActiveQualityID = observedActiveQualityID
        previousLimitKbps = observedLimitKbps
        keptEstimateKbps = request.bandwidthEstimateKbps
    }

    private func lowerRequest(status: MediaNegotiatedStatus, deliveredKbps: Int?,
                              observedThroughputKbps: Int?) -> Lowering? {
        let qualities = status.availableQualities
        guard !status.degradationWarnings.contains(where: { $0.code == "quality_reduction_unavailable" }) else { return nil }
        switch requestedQuality {
        case .offered(let id):
            guard let current = qualities.first(where: { $0.id == (status.activeQualityID ?? id) }),
                  let bitrate = current.bitrateKbps,
                  let lower = qualities.filter({ $0.id != current.id && ($0.bitrateKbps ?? Int.max) < bitrate })
                    .max(by: { ($0.bitrateKbps ?? 0) < ($1.bitrateKbps ?? 0) }) else { return nil }
            return Lowering(quality: .offered(id: lower.id), bandwidthEstimateKbps: nil,
                            observedThroughputKbps: observedThroughputKbps)
        case .automatic:
            guard let deliveredKbps, deliveredKbps > 0 else { return nil }
            let estimate = max(100, deliveredKbps * 7 / 10)
            let activeBitrate = status.activeQualityID.flatMap { id in qualities.first { $0.id == id }?.bitrateKbps } ?? deliveredKbps
            let hasLower = qualities.contains { ($0.bitrateKbps ?? Int.max) < activeBitrate }
            guard hasLower else { return nil }
            let cap = status.bandwidthLimit?.kbps
            guard cap == nil || estimate < cap! else { return nil }
            return Lowering(quality: .automatic, bandwidthEstimateKbps: estimate,
                            observedThroughputKbps: observedThroughputKbps)
        }
    }
}
