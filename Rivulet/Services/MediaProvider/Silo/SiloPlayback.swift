// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation
import AVFoundation
import VideoToolbox
import UIKit
import AetherEngine
import os

extension SiloProvider {
    /// Starts one native reservation with independent resolved playback axes.
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, policy: SiloResolvedPlaybackPolicy,
                       subtitleIndex: Int? = nil) async throws -> StreamInfo {
        let application = try SiloPlaybackPolicyApplication(policy: policy)
        return try await startPlayback(itemRef, sourceID: sourceID, startTime: 0,
            maxBitrate: application.maxBitrate, audioIndex: nil, subtitleIndex: subtitleIndex,
            transcodeOnly: false, quality: application.quality, policy: application)
    }

    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, maxBitrate: Int?) async throws -> StreamInfo {
        try await startPlayback(itemRef, sourceID: sourceID, startTime: 0, maxBitrate: maxBitrate,
                                audioIndex: nil, subtitleIndex: nil, transcodeOnly: false, quality: .automatic)
    }

    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, quality: MediaQualityPreference) async throws -> StreamInfo {
        try await startPlayback(itemRef, sourceID: sourceID, startTime: 0, maxBitrate: nil,
                                audioIndex: nil, subtitleIndex: nil, transcodeOnly: false, quality: quality)
    }

    /// An explicit local title pick. Nil follows Silo's effective profile,
    /// library and series choice; -1 is an explicit Off for this playback.
    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, quality: MediaQualityPreference,
                       subtitleIndex: Int?) async throws -> StreamInfo {
        try await startPlayback(itemRef, sourceID: sourceID, startTime: 0, maxBitrate: nil,
                                audioIndex: nil, subtitleIndex: subtitleIndex,
                                transcodeOnly: false, quality: quality)
    }

    func resolveStream(for itemRef: MediaItemRef, sourceID: String?, quality: MediaQualityPreference,
                       observation: SiloBufferingObservation) async throws -> StreamInfo {
        try await startPlayback(itemRef, sourceID: sourceID, startTime: 0, maxBitrate: nil,
                                audioIndex: nil, subtitleIndex: nil, transcodeOnly: false,
                                quality: quality, observation: observation)
    }

    func transcodeStream(for itemRef: MediaItemRef, sourceID: String?, startTime: TimeInterval,
                         maxBitrate: Int?, audioStreamIndex: Int?, subtitleStreamIndex: Int?) async throws -> StreamInfo {
        try await startPlayback(itemRef, sourceID: sourceID, startTime: startTime, maxBitrate: maxBitrate,
                                audioIndex: audioStreamIndex, subtitleIndex: subtitleStreamIndex,
                                transcodeOnly: audioStreamIndex == nil && subtitleStreamIndex == nil, quality: .automatic)
    }

    func startPlayback(_ ref: MediaItemRef, sourceID: String?, startTime: Double, maxBitrate: Int?,
                               audioIndex: Int?, subtitleIndex: Int?, transcodeOnly: Bool,
                               quality: MediaQualityPreference,
                               observation: SiloBufferingObservation? = nil,
                               policy: SiloPlaybackPolicyApplication? = nil,
                               ignoreLearnedLimit: Bool = false) async throws -> StreamInfo {
        guard ref.providerID == id, client.profileID == profileID else { throw MediaProviderError.unauthorized }
        guard !ref.itemID.hasPrefix("external:"), !ref.itemID.hasPrefix("siloCollection|") else { throw MediaProviderError.notPlayable }
        guard startTime.isFinite, startTime >= 0, maxBitrate.map({ $0 > 0 }) ?? true else {
            throw MediaProviderError.backendSpecific(underlying: "Invalid Silo playback position or bitrate.")
        }
        let capability: SiloPlaybackCapabilities = try await client.get("playback/capabilities")
        guard capability.allowed else { throw MediaProviderError.unauthorized }
        guard capability.state == "available", capability.protocolVersions.contains(3),
              capability.features.contains("playback_plan_v3"), let installation = capability.installationId else {
            throw MediaProviderError.backendSpecific(underlying: "This Silo server does not offer native playback protocol 3.")
        }
        let watch: SiloItem = try await client.get("watch/\(Self.pathComponent(ref.itemID))")
        if let sourceID, let source = watch.versions?.first(where: { $0.fileId == sourceID }),
           (source.presentationPartTotal ?? 1) > 1 {
            throw MediaProviderError.backendSpecific(underlying: "This Silo source is one part of an ordered multipart title, which this player does not support.")
        }
        let versions = (watch.versions ?? []).filter { ($0.presentationPartTotal ?? 1) <= 1 }
        guard !versions.isEmpty else {
            throw MediaProviderError.backendSpecific(underlying: (watch.versions ?? []).isEmpty
                ? "Silo has no playable source for this title."
                : "This Silo title requires ordered multipart playback, which this player does not support.")
        }
        let chosen: SiloVersion
        if let sourceID {
            guard let source = versions.first(where: { $0.fileId == sourceID }) else { throw MediaProviderError.notFound }
            chosen = source
        } else {
            let keys = versions.map { version in
                let video = version.videoTracks?.first
                let label = version.resolution.replacingOccurrences(of: "p", with: "").replacingOccurrences(of: "i", with: "")
                return VersionRanking.Key(tier: VersionRanking.tier(label: label, height: video?.height),
                                          range: video?.dvProfile != nil ? 4 : version.hdr ? 2 : 0,
                                          bitrate: version.bitsPerSecond ?? 0)
            }
            guard let index = VersionRanking.pick(.best, ids: versions.map(\.fileId), keys: keys,
                                                  capKbps: maxBitrate.map { $0 / 1000 }) else { throw MediaProviderError.notPlayable }
            chosen = versions[index]
        }
        let selectedAudioIndex = audioIndex ?? policy?.audioIndex(in: chosen)
        if let selectedAudioIndex, !(chosen.audioTracks ?? []).indices.contains(selectedAudioIndex) {
            throw MediaProviderError.backendSpecific(underlying: "The chosen Silo audio track is no longer available.")
        }
        let device = await Self.playbackCapabilities(transcodeOnly: transcodeOnly, serverDeliveries: capability.deliveries,
                                                     hlsVariableSubstitution: capability.features.contains("hls_variable_substitution_v1"))
        guard !device.1.deliveries.isEmpty else {
            throw MediaProviderError.backendSpecific(underlying: "The Silo server does not offer a transport supported by this player.")
        }
        var body = SiloPlaybackStart(installationId: installation, fileId: chosen.fileId, profileId: profileID,
                                     playbackAttemptId: UUID().uuidString, clientCapabilities: device.0, clientPlaybackContext: device.1,
                                     allowAlternateVersions: sourceID == nil && selectedAudioIndex == nil && subtitleIndex == nil, startPosition: startTime,
                                     bandwidthCapKbps: maxBitrate.map { $0 / 1000 },
                                     audioTrackId: selectedAudioIndex.map { "file:\(chosen.fileId):audio:\($0)" }, audioTrackIndex: selectedAudioIndex,
                                     subtitleTrackId: nil, subtitleTrackIndex: nil, qualityPreference: quality)
        if capability.features.contains("buffering_quality_v1") { body.clientFeatures.append("buffering_quality_v1") }
        if (policy?.ignoreLearnedLimit == true || ignoreLearnedLimit), capability.features.contains("buffering_quality_v1") {
            body.learnedLimit = "ignore"
        }
        if let observation, capability.features.contains("buffering_quality_v1"),
           quality == .automatic, body.learnedLimit != "ignore" {
            body.bandwidthEstimateKbps = observation.estimateKbps
            body.bandwidthEstimateSource = observation.source.rawValue
            body.observedThroughputKbps = observation.observedThroughputKbps
        }
        if capability.features.contains("playback_plan_summary_v1") { body.clientFeatures.append("playback_plan_summary_v1") }
        if capability.features.contains("header_authenticated_media_v1") { body.clientFeatures.append("header_authenticated_media_v1") }
        let decision: SiloPlaybackDecision = try await client.post("playback/start", body: body)
        guard decision.protocolVersion == 3, decision.outcome == "playable", let plan = decision.playbackPlan,
              let sessionID = decision.sessionId ?? decision.playbackPlan?.sessionId else {
            throw MediaProviderError.backendSpecific(underlying: decision.terminal?.message ?? "Silo did not return a playable native plan (\(decision.outcome)).")
        }
        do {
            var selectedPlan = plan
            var selectedFeatures = decision.serverFeatures ?? []
            let initialVersion: SiloVersion
            if let known = watch.versions?.first(where: { $0.fileId == plan.effectiveMediaFileId }) {
                initialVersion = known
            } else {
                let effectiveWatch: SiloItem = try await client.get("watch/\(Self.pathComponent(ref.itemID))",
                    [URLQueryItem(name: "file_id", value: plan.effectiveMediaFileId)])
                guard let known = effectiveWatch.versions?.first(where: { $0.fileId == plan.effectiveMediaFileId }) else {
                    throw MediaProviderError.backendSpecific(underlying: "Silo's effective source has no subtitle inventory.")
                }
                initialVersion = known
            }
            let subtitleChoice = try SiloInitialSubtitleSelection.resolve(
                watch: watch, version: initialVersion, plan: plan, explicitIndex: subtitleIndex, policy: policy)
            if subtitleChoice.differs(from: plan) {
                let replan = SiloPlaybackReplan(installationId: installation, playbackAttemptId: body.playbackAttemptId,
                    replanRequestId: UUID().uuidString, failedPlanId: plan.planId,
                    planAttemptId: UUID().uuidString, planAttemptKey: plan.planAttemptKey,
                    positionSeconds: startTime,
                    selectedTracks: SiloSelectedTracks(audio: plan.selectedTracks.audio,
                                                        subtitle: subtitleChoice.selectedTrack),
                    clientCapabilities: body.clientCapabilities, clientPlaybackContext: body.clientPlaybackContext,
                    bandwidthCapKbps: body.bandwidthCapKbps, operation: "track_change",
                    qualityPreference: body.qualityIntent)
                var request = replan
                request.clientFeatures = body.clientFeatures
                request.bandwidthEstimateKbps = body.bandwidthEstimateKbps
                request.learnedLimit = body.learnedLimit
                let changed: SiloPlaybackDecision = try await client.post("playback/\(Self.pathComponent(sessionID))/replan", body: request)
                guard changed.outcome == "playable", changed.protocolVersion == 3,
                      let next = changed.playbackPlan,
                      (changed.sessionId ?? next.sessionId) == sessionID,
                      next.effectiveMediaFileId == plan.effectiveMediaFileId,
                      next.selectedTracks.audio?.id == plan.selectedTracks.audio?.id,
                      next.selectedTracks.subtitle?.id == subtitleChoice.selectedTrack?.id,
                      (subtitleChoice.selectedTrack == nil ? next.subtitle.mode == "off" : next.subtitle.mode != "off") else {
                    throw MediaProviderError.backendSpecific(underlying: changed.terminal?.message
                        ?? "Silo did not preserve the requested initial subtitle selection.")
                }
                selectedPlan = next
                selectedFeatures = changed.serverFeatures ?? selectedFeatures
            }
            return try await materialize(selectedPlan, sessionID: sessionID, ref: ref, request: body, watch: watch,
                                         serverFeatures: selectedFeatures)
        } catch {
            // A real session exists even when its transport cannot be consumed.
            // Retire it instead of leaving a phantom stream on the server.
            do {
                try await retire(sessionID: sessionID, installationID: installation)
            } catch {
                Logger(subsystem: "Rivulet", category: "SiloPlayback").error("Failed to retire rejected Silo playback session")
            }
            throw error
        }
    }

    /// The caller supplies the exact reservation being changed. A matching item
    /// elsewhere (prefetch or another player) is never authority to reuse it.
    func replaceStream(for itemRef: MediaItemRef, current: StreamInfo, sourceID: String?,
                       position: TimeInterval, maxBitrate: Int?, audioStreamIndex: Int?,
                       subtitleStreamIndex: Int?, forceTranscode: Bool) async throws -> StreamInfo? {
        guard position.isFinite, position >= 0, maxBitrate.map({ $0 > 0 }) ?? true,
              let sessionID = current.playSessionID else { throw MediaProviderError.notPlayable }
        let context = try playbackSessions.withLock { sessions -> SiloPlaybackSession in
            guard var context = sessions[sessionID], context.ref == itemRef,
                  context.fileID == current.source.id, context.lifetime.isActive else { throw MediaProviderError.notFound }
            guard !context.isReplanning else {
                throw MediaProviderError.backendSpecific(underlying: "A Silo playback replacement is already in flight.")
            }
            context.isReplanning = true
            sessions[sessionID] = context
            return context
        }
        defer { playbackSessions.withLock { $0[sessionID]?.isReplanning = false } }
        if let sourceID, sourceID != context.fileID || context.request.allowAlternateVersions {
            // V3 has no file_id/alternate-version-policy field on replan.
            // Release this reservation before reserving a different/pinned file.
            try await retire(sessionID: sessionID, installationID: context.installationID, position: position)
            do {
                return try await startPlayback(itemRef, sourceID: sourceID, startTime: position,
                                               maxBitrate: maxBitrate ?? context.request.bandwidthCapKbps.flatMap { cap in
                                                   let value = cap.multipliedReportingOverflow(by: 1_000)
                                                   return value.overflow ? nil : value.partialValue
                                               }, audioIndex: audioStreamIndex,
                                               subtitleIndex: subtitleStreamIndex, transcodeOnly: forceTranscode,
                                               quality: context.request.qualityIntent,
                                               ignoreLearnedLimit: context.request.learnedLimit == "ignore")
            } catch {
                throw MediaProviderError.backendSpecific(underlying:
                    "Silo could not open the selected source after ending the previous session: \(error.localizedDescription)")
            }
        }
        var audio = context.plan.selectedTracks.audio
        if let index = audioStreamIndex {
            guard let track = current.source.audioTracks.first(where: { $0.index == index }) else {
                throw MediaProviderError.backendSpecific(underlying: "The selected Silo audio track is not in this stream's inventory.")
            }
            audio = SiloTrackIdentity(id: track.id, index: track.index)
        }
        var subtitle = context.plan.selectedTracks.subtitle
        if let index = subtitleStreamIndex {
            if index < 0 { subtitle = nil }
            else {
                guard let track = context.plan.subtitle.inventory.first(where: { $0.combinedIndex == index }) else {
                    throw MediaProviderError.backendSpecific(underlying: "The selected Silo subtitle is not in this plan's inventory.")
                }
                subtitle = SiloTrackIdentity(id: track.trackId, index: track.combinedIndex)
            }
        }
        let capability: SiloPlaybackCapabilities = try await client.get("playback/capabilities")
        guard capability.installationId == context.installationID, capability.allowed, capability.state == "available" else {
            throw MediaProviderError.backendSpecific(underlying: "Silo's playback installation or authorization changed during this session.")
        }
        var request = context.request
        if let maxBitrate { request.bandwidthCapKbps = maxBitrate / 1_000 }
        request.clientPlaybackContext = await Self.playbackCapabilities(
            transcodeOnly: forceTranscode, serverDeliveries: capability.deliveries,
            hlsVariableSubstitution: context.request.clientPlaybackContext.deliveries["hls"]?
                .features.contains("hls_variable_substitution_v1") == true
        ).1
        let changingTracks = audioStreamIndex != nil || subtitleStreamIndex != nil
        var body = SiloPlaybackReplan(installationId: context.installationID,
                                      playbackAttemptId: request.playbackAttemptId, replanRequestId: UUID().uuidString,
                                      failedPlanId: context.plan.planId, planAttemptId: UUID().uuidString,
                                      planAttemptKey: context.plan.planAttemptKey, positionSeconds: position,
                                      selectedTracks: SiloSelectedTracks(audio: audio, subtitle: subtitle),
                                      clientCapabilities: request.clientCapabilities,
                                      clientPlaybackContext: request.clientPlaybackContext,
                                      bandwidthCapKbps: request.bandwidthCapKbps,
                                      operation: changingTracks ? "track_change" : "quality_change",
                                      qualityPreference: request.qualityIntent)
        body.clientFeatures = context.request.clientFeatures
        body.bandwidthEstimateKbps = context.request.bandwidthEstimateKbps
        body.learnedLimit = context.request.learnedLimit
        let decision: SiloPlaybackDecision = try await client.post("playback/\(Self.pathComponent(sessionID))/replan", body: body)
        guard decision.protocolVersion == 3, decision.outcome == "playable", let plan = decision.playbackPlan,
              let nextSession = decision.sessionId ?? decision.playbackPlan?.sessionId else {
            throw MediaProviderError.backendSpecific(underlying: decision.terminal?.message ?? "Silo could not replace the playback plan (\(decision.outcome)).")
        }
        do {
            let watch: SiloItem = try await client.get("watch/\(Self.pathComponent(itemRef.itemID))",
                                                     [URLQueryItem(name: "file_id", value: plan.effectiveMediaFileId)])
            return try await materialize(plan, sessionID: nextSession, ref: itemRef, request: request, watch: watch,
                                         expectedLifetime: context.lifetime, serverFeatures: decision.serverFeatures ?? context.serverFeatures)
        } catch {
            do { try await retire(sessionID: nextSession, installationID: context.installationID) }
            catch { Logger(subsystem: "Rivulet", category: "SiloPlayback").error("Failed to retire rejected Silo replacement") }
            throw error
        }
    }

    /// Replan only against the exact quality labels offered by the active plan.
    func replaceStream(for itemRef: MediaItemRef, current: StreamInfo, sourceID: String?,
                       position: TimeInterval, quality: MediaQualityPreference) async throws -> StreamInfo {
        guard position.isFinite, position >= 0, let sessionID = current.playSessionID,
              client.profileID == profileID else { throw MediaProviderError.notPlayable }
        let context = try playbackSessions.withLock { sessions -> SiloPlaybackSession in
            guard var context = sessions[sessionID], context.ref == itemRef,
                  context.fileID == current.source.id, context.lifetime.isActive,
                  sourceID == nil || sourceID == context.fileID else { throw MediaProviderError.notFound }
            guard !context.isReplanning else {
                throw MediaProviderError.backendSpecific(underlying: "A Silo playback replacement is already in flight.")
            }
            if case .offered(let id) = quality {
                guard id != "auto", context.plan.availableQualities?.contains(where: { $0.label == id }) == true else {
                    throw MediaProviderError.backendSpecific(underlying: "The selected Silo quality is no longer offered.")
                }
            }
            context.isReplanning = true
            sessions[sessionID] = context
            return context
        }
        defer { playbackSessions.withLock { $0[sessionID]?.isReplanning = false } }
        var body = SiloPlaybackReplan(installationId: context.installationID,
                                      playbackAttemptId: context.request.playbackAttemptId,
                                      replanRequestId: UUID().uuidString, failedPlanId: context.plan.planId,
                                      planAttemptId: UUID().uuidString, planAttemptKey: context.plan.planAttemptKey,
                                      positionSeconds: position, selectedTracks: context.plan.selectedTracks,
                                      clientCapabilities: context.request.clientCapabilities,
                                      clientPlaybackContext: context.request.clientPlaybackContext,
                                      bandwidthCapKbps: context.request.bandwidthCapKbps,
                                      operation: "quality_change", qualityPreference: quality)
        body.clientFeatures = context.request.clientFeatures
        body.bandwidthEstimateKbps = context.request.bandwidthEstimateKbps
        body.learnedLimit = context.request.learnedLimit
        let decision: SiloPlaybackDecision = try await client.post("playback/\(Self.pathComponent(sessionID))/replan", body: body)
        guard decision.protocolVersion == 3, decision.outcome == "playable", let plan = decision.playbackPlan,
              (decision.sessionId ?? plan.sessionId) == sessionID else {
            throw MediaProviderError.backendSpecific(underlying: decision.terminal?.message ?? "Silo could not change quality.")
        }
        guard context.lifetime.isActive, client.profileID == profileID,
              playbackSessions.withLock({ $0[sessionID]?.lifetime === context.lifetime }) else {
            throw MediaProviderError.notFound
        }
        let watch: SiloItem = try await client.get("watch/\(Self.pathComponent(itemRef.itemID))",
                                                 [URLQueryItem(name: "file_id", value: plan.effectiveMediaFileId)])
        var request = context.request
        request.qualityPreference = quality.serverValue
        return try await materialize(plan, sessionID: sessionID, ref: itemRef, request: request,
                                     watch: watch, expectedLifetime: context.lifetime,
                                     serverFeatures: decision.serverFeatures ?? context.serverFeatures)
    }

    /// A stored-row ID is not a playback ordinal. Refresh the exact reservation,
    /// resolve its server-pinned inventory entry, then materialize only the pick.
    func streamSelectingStoredSubtitle(_ storedID: String, current: StreamInfo,
                                       position: TimeInterval) async throws -> StreamInfo {
        guard !storedID.isEmpty, position.isFinite, position >= 0,
              client.profileID == profileID, let sessionID = current.playSessionID else {
            throw MediaProviderError.notPlayable
        }
        let context = try playbackSessions.withLock { sessions -> SiloPlaybackSession in
            guard var context = sessions[sessionID], context.ref.providerID == id,
                  context.fileID == current.source.id, context.lifetime.isActive else { throw MediaProviderError.notFound }
            guard !context.isReplanning else {
                throw MediaProviderError.backendSpecific(underlying: "A Silo playback replacement is already in flight.")
            }
            context.isReplanning = true
            sessions[sessionID] = context
            return context
        }
        defer { playbackSessions.withLock { $0[sessionID]?.isReplanning = false } }
        func replan(from previous: SiloPlaybackPlan, tracks: SiloSelectedTracks) async throws -> SiloPlaybackPlan {
            guard context.lifetime.isActive else { throw MediaProviderError.notFound }
            var body = SiloPlaybackReplan(installationId: context.installationID,
                                          playbackAttemptId: context.request.playbackAttemptId,
                                          replanRequestId: UUID().uuidString, failedPlanId: previous.planId,
                                          planAttemptId: UUID().uuidString, planAttemptKey: previous.planAttemptKey,
                                          positionSeconds: position, selectedTracks: tracks,
                                          clientCapabilities: context.request.clientCapabilities,
                                          clientPlaybackContext: context.request.clientPlaybackContext,
                                          bandwidthCapKbps: context.request.bandwidthCapKbps, operation: "track_change",
                                          qualityPreference: context.request.qualityIntent)
            body.clientFeatures = context.request.clientFeatures
            body.bandwidthEstimateKbps = context.request.bandwidthEstimateKbps
            body.learnedLimit = context.request.learnedLimit
            let decision: SiloPlaybackDecision = try await client.post("playback/\(Self.pathComponent(sessionID))/replan", body: body)
            guard decision.protocolVersion == 3, decision.outcome == "playable", let plan = decision.playbackPlan else {
                throw MediaProviderError.backendSpecific(underlying: decision.terminal?.message ?? "Silo could not activate the stored subtitle.")
            }
            guard (decision.sessionId ?? plan.sessionId) == sessionID, plan.effectiveMediaFileId == context.fileID,
                  plan.selectedTracks.audio?.id == context.plan.selectedTracks.audio?.id,
                  plan.selectedTracks.audio?.index == context.plan.selectedTracks.audio?.index else {
                throw MediaProviderError.backendSpecific(underlying: "Silo changed the source, audio, or reservation while activating a stored subtitle.")
            }
            guard context.lifetime.isActive else { throw MediaProviderError.notFound }
            return plan
        }
        let refreshed = try await replan(from: context.plan, tracks: context.plan.selectedTracks)
        // Keep the accepted server plan as the next replan authority even if the
        // imported row is absent. This does not register or reload its transport.
        try playbackSessions.withLock { sessions in
            guard context.lifetime.isActive, sessions[sessionID]?.lifetime === context.lifetime else {
                throw MediaProviderError.notFound
            }
            sessions[sessionID] = SiloPlaybackSession(installationID: context.installationID, sessionID: sessionID,
                                                       fileID: context.fileID, timelineOffset: refreshed.timeline.timelineOffsetSeconds,
                                                       ref: context.ref, request: context.request, plan: refreshed,
                                                       lifetime: context.lifetime, relay: context.relay,
                                                       serverFeatures: context.serverFeatures, isReplanning: true)
        }
        let track = try storedSubtitleTrack(storedID, in: refreshed)
        let selected = SiloSelectedTracks(audio: context.plan.selectedTracks.audio,
                                          subtitle: SiloTrackIdentity(id: track.trackId, index: track.combinedIndex))
        let plan = try await replan(from: refreshed, tracks: selected)
        do {
            let installed = try storedSubtitleTrack(storedID, in: plan)
            guard plan.selectedTracks.subtitle?.id == installed.trackId else {
                throw MediaProviderError.backendSpecific(underlying: "Silo did not select the requested stored subtitle.")
            }
            let watch: SiloItem = try await client.get("watch/\(Self.pathComponent(context.ref.itemID))",
                                                     [URLQueryItem(name: "file_id", value: context.fileID)])
            return try await materialize(plan, sessionID: sessionID, ref: context.ref, request: context.request,
                                         watch: watch, expectedLifetime: context.lifetime,
                                         serverFeatures: context.serverFeatures)
        } catch {
            do { try await retire(sessionID: sessionID, installationID: context.installationID) }
            catch { Logger(subsystem: "Rivulet", category: "SiloPlayback").error("Failed to retire rejected Silo subtitle selection") }
            throw error
        }
    }

    private func storedSubtitleTrack(_ storedID: String, in plan: SiloPlaybackPlan) throws -> SiloPlanSubtitleTrack {
        var match: SiloPlanSubtitleTrack?
        for track in plan.subtitle.inventory where track.source == "downloaded" {
            guard track.storedSubtitleID == storedID else { continue }
            guard match == nil else {
                throw MediaProviderError.backendSpecific(underlying: "Silo published an ambiguous stored subtitle identity.")
            }
            match = track
        }
        guard let match else {
            throw MediaProviderError.backendSpecific(underlying: "The stored subtitle is absent from Silo's authoritative playback inventory.")
        }
        return match
    }

    func seekStream(for itemRef: MediaItemRef, sourceID: String?, playSessionID: String?, position: TimeInterval) async throws -> StreamInfo? {
        guard position.isFinite, position >= 0, let sessionID = playSessionID else { throw MediaProviderError.notPlayable }
        let context = try playbackSessions.withLock { sessions -> SiloPlaybackSession in
            guard var context = sessions[sessionID], context.ref == itemRef, context.lifetime.isActive else {
                throw MediaProviderError.notFound
            }
            guard !context.isReplanning else {
                throw MediaProviderError.backendSpecific(underlying: "A Silo playback replan is already in flight.")
            }
            context.isReplanning = true
            sessions[sessionID] = context
            return context
        }
        defer { playbackSessions.withLock { $0[sessionID]?.isReplanning = false } }
        if context.plan.timeline.canSeekAnywhere { return nil }
        if let sourceID, sourceID != context.fileID { throw MediaProviderError.notFound }
        var body = SiloPlaybackReplan(installationId: context.installationID,
                                      playbackAttemptId: context.request.playbackAttemptId,
                                      replanRequestId: UUID().uuidString, failedPlanId: context.plan.planId,
                                      planAttemptId: UUID().uuidString, planAttemptKey: context.plan.planAttemptKey,
                                      positionSeconds: position, selectedTracks: context.plan.selectedTracks,
                                      clientCapabilities: context.request.clientCapabilities,
                                      clientPlaybackContext: context.request.clientPlaybackContext,
                                      bandwidthCapKbps: context.request.bandwidthCapKbps, operation: "seek_reanchor",
                                      qualityPreference: context.request.qualityIntent)
        body.clientFeatures = context.request.clientFeatures
        body.bandwidthEstimateKbps = context.request.bandwidthEstimateKbps
        body.learnedLimit = context.request.learnedLimit
        let decision: SiloPlaybackDecision = try await client.post("playback/\(Self.pathComponent(sessionID))/replan", body: body)
        guard decision.protocolVersion == 3, decision.outcome == "playable", let plan = decision.playbackPlan,
              let nextSession = decision.sessionId ?? decision.playbackPlan?.sessionId else {
            throw MediaProviderError.backendSpecific(underlying: decision.terminal?.message ?? "Silo could not reanchor playback (\(decision.outcome)).")
        }
        do {
            let watch: SiloItem = try await client.get("watch/\(Self.pathComponent(itemRef.itemID))",
                                                     [URLQueryItem(name: "file_id", value: plan.effectiveMediaFileId)])
            return try await materialize(plan, sessionID: nextSession, ref: itemRef, request: context.request, watch: watch,
                                         expectedLifetime: context.lifetime,
                                         serverFeatures: decision.serverFeatures ?? context.serverFeatures)
        } catch {
            do { try await retire(sessionID: nextSession, installationID: context.installationID) }
            catch { Logger(subsystem: "Rivulet", category: "SiloPlayback").error("Failed to retire rejected Silo replan") }
            throw error
        }
    }

    func discardStream(_ stream: StreamInfo) async throws -> Bool {
        guard let sessionID = stream.playSessionID,
              let context = playbackSessions.withLock({ $0[sessionID] }) else { return true }
        try await retire(sessionID: sessionID, installationID: context.installationID)
        return true
    }

    private func retire(sessionID: String, installationID: String, position: Double? = nil) async throws {
        let ownership = playbackSessions.withLock { $0[sessionID] }
        ownership?.lifetime.deactivate()
        if let reporter = ownership?.lifetime.reporter {
            try await reporter.stopForRetirement(position: position)
            return
        }
        defer {
            ownership?.relay.stop()
            playbackSessions.withLock { _ = $0.removeValue(forKey: sessionID) }
        }
        let client = client
        let body = SiloPlaybackDiscard(installationId: installationID, stopId: UUID().uuidString.lowercased())
        // Disposal must still reach the server when the preparing/play task
        // was cancelled. This is one stop, not a replay of an uncertain write.
        let result: SiloPlaybackMutation = try await Task {
            try await client.delete("playback/\(Self.pathComponent(sessionID))", body: body)
        }.value
        guard ["stopped", "replayed"].contains(result.outcome) else {
            throw MediaProviderError.backendSpecific(underlying: "Silo did not retire the unplayed plan: \(result.outcome)")
        }
    }

    func materialize(_ plan: SiloPlaybackPlan, sessionID: String, ref: MediaItemRef,
                             request: SiloPlaybackStart, watch initialWatch: SiloItem,
                             expectedLifetime: SiloPlaybackLifetime? = nil,
                             serverFeatures: [String] = []) async throws -> StreamInfo {
        guard plan.protocolVersion == 3, plan.stream.headerRefresh == "none" else {
            throw MediaProviderError.backendSpecific(underlying: "The Silo plan requires a transport header refresh this player cannot perform.")
        }
        guard request.allowAlternateVersions || plan.effectiveMediaFileId == request.fileId else {
            throw MediaProviderError.backendSpecific(underlying: "Silo's playback plan changed the explicitly selected source.")
        }
        if let expires = SiloMediaMapper.date(plan.expiresAt), expires <= Date() {
            throw MediaProviderError.backendSpecific(underlying: "The Silo playback plan has expired. Start playback again.")
        }
        guard let url = client.mediaURL(plan.stream.url), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw MediaProviderError.backendSpecific(underlying: "Silo returned an invalid playback transport URL.")
        }
        let streamKind: MediaSource.StreamKind
        switch (plan.delivery, plan.stream.protocol) {
        case ("original_http", "http_progressive"), ("server_remux_progressive", "http_progressive"): streamKind = .directPlay
        case ("server_transcode_hls", "hls"), ("server_remux_hls", "hls"): streamKind = .hlsTranscode
        default: throw MediaProviderError.backendSpecific(underlying: "Silo returned an unsupported playback delivery: \(plan.delivery)/\(plan.stream.protocol).")
        }
        let deliveryClass = plan.delivery == "original_http" ? "original_http"
            : plan.delivery == "server_remux_progressive" ? "server_remux_progressive" : "hls"
        guard request.clientPlaybackContext.deliveries[deliveryClass] != nil else {
            throw MediaProviderError.backendSpecific(underlying: "Silo returned a transport the client did not negotiate.")
        }
        var watch = initialWatch
        if !(watch.versions ?? []).contains(where: { $0.fileId == plan.effectiveMediaFileId }) {
            watch = try await client.get("watch/\(Self.pathComponent(ref.itemID))",
                                         [URLQueryItem(name: "file_id", value: plan.effectiveMediaFileId)])
        }
        guard let effective = watch.versions?.first(where: { $0.fileId == plan.effectiveMediaFileId }) else {
            throw MediaProviderError.backendSpecific(underlying: "Silo's effective source is missing from its version inventory.")
        }
        let original = SiloMediaMapper.source(effective, baseURL: client.baseURL, streamURL: url, streamKind: streamKind,
                                              selectedAudio: plan.selectedTracks.audio?.index)
        let existing = playbackSessions.withLock { $0[sessionID] }
        guard expectedLifetime?.isActive != false, existing?.lifetime.isActive != false,
              expectedLifetime == nil || existing?.lifetime === expectedLifetime else { throw MediaProviderError.notFound }
        let relay: SiloMediaRelay
        if let existing { relay = existing.relay }
        else { relay = try await SiloMediaRelay.start(client: client) }
        var installed = false
        defer { if !installed && existing == nil { relay.stop() } }
        let localURL = try relay.localURL(for: url, headers: plan.stream.headers, reportsSessionFaults: true)
        let subtitles = try planSubtitles(plan, relay: relay)
        let lifetime = existing?.lifetime ?? SiloPlaybackLifetime()
        relay.onSessionProblem = { [weak lifetime] problem in lifetime?.receive(problem) }
        let source = MediaSource(id: effective.fileId, container: plan.stream.container ?? original.container,
                                 duration: plan.source.durationSeconds ?? original.duration, bitrate: original.bitrate,
                                 fileSize: streamKind == .directPlay ? original.fileSize : nil, fileName: original.fileName,
                                 versionName: original.versionName, videoResolution: original.videoResolution,
                                 videoTracks: original.videoTracks, audioTracks: original.audioTracks,
                                 subtitleTracks: subtitles, streamKind: streamKind, streamURL: localURL, chapters: original.chapters)
        try playbackSessions.withLock {
            guard expectedLifetime?.isActive != false, lifetime.isActive else { throw MediaProviderError.notFound }
            $0[sessionID] = SiloPlaybackSession(installationID: request.installationId, sessionID: sessionID,
                                               fileID: effective.fileId, timelineOffset: plan.timeline.timelineOffsetSeconds,
                                               ref: ref, request: request, plan: plan, lifetime: lifetime, relay: relay,
                                               serverFeatures: serverFeatures.isEmpty ? (existing?.serverFeatures ?? []) : serverFeatures,
                                               isReplanning: existing?.isReplanning ?? false)
        }
        installed = true
        var info = StreamInfo(source: source, playSessionID: sessionID, trackInfoAvailable: streamKind == .directPlay)
        info.httpHeaders = [:]
        info.upstreamURL = url
        info.playerStartTime = plan.timeline.playerStartSeconds
        info.timelineOffset = plan.timeline.timelineOffsetSeconds
        info.canSeekAnywhere = plan.timeline.canSeekAnywhere
        info.prefersAetherPlayback = true
        info.canSelectTracksLocally = false
        let status = plan.negotiatedStatus
        info.negotiatedStatus = status
        info.videoTransport = ProviderVideoTransport(
            url: url, headers: plan.stream.headers, delivery: status.delivery,
            container: plan.stream.container, recipe: status.effectiveRecipe,
            qualityID: plan.activeQuality, audioID: plan.selectedTracks.audio?.id)
        info.subtitleDelivery = switch plan.subtitle.mode {
        case "off": .off
        case "burn_in": .video
        default:
            plan.subtitle.embedded != nil ? .embedded
                : plan.subtitle.artifact != nil ? .sidecar : .hlsRendition
        }
        if let selected = plan.selectedTracks.subtitle {
            guard let track = plan.subtitle.inventory.first(where: { $0.trackId == selected.id }) else {
                throw MediaProviderError.backendSpecific(underlying: "Silo's selected subtitle is absent from its plan inventory.")
            }
            info.authoritativeSubtitleSelection = .track(id: selected.id, index: track.combinedIndex)
        } else {
            info.authoritativeSubtitleSelection = .off
        }
        return info
    }

    func planSubtitles(_ plan: SiloPlaybackPlan, relay: SiloMediaRelay) throws -> [SubtitleTrack] {
        let decision = plan.subtitle
        let selectedID = plan.selectedTracks.subtitle?.id
        let selected = decision.inventory.first { $0.trackId == selectedID }
        let routeCount = (decision.artifact == nil ? 0 : 1) + (decision.embedded == nil ? 0 : 1)
            + (decision.hlsRendition == nil ? 0 : 1)
        switch decision.mode {
        case "off":
            guard selectedID == nil, decision.trackId == nil, routeCount == 0 else {
                throw MediaProviderError.backendSpecific(underlying: "Silo returned a subtitle route while subtitles are off.")
            }
        case "burn_in":
            guard selected != nil, decision.trackId == selectedID, routeCount == 0 else {
                throw MediaProviderError.backendSpecific(underlying: "Silo returned an invalid burned-in subtitle selection.")
            }
        case "render", "convert":
            guard selected != nil, decision.trackId == selectedID, routeCount == 1 else {
                throw MediaProviderError.backendSpecific(underlying: "Silo did not identify exactly one delivery for the selected subtitle.")
            }
        default:
            throw MediaProviderError.backendSpecific(underlying: "Silo returned an unsupported subtitle mode: \(decision.mode).")
        }
        if let embedded = decision.embedded {
            guard plan.delivery == "original_http", decision.mode == "render",
                  selected?.source == "embedded", embedded.streamIndex >= 0 else {
                throw MediaProviderError.backendSpecific(underlying: "Silo returned an invalid native embedded subtitle identity.")
            }
        }
        if decision.hlsRendition != nil {
            guard ["server_transcode_hls", "server_remux_hls"].contains(plan.delivery) else {
                throw MediaProviderError.backendSpecific(underlying: "Silo returned an HLS subtitle rendition for a non-HLS stream.")
            }
        }
        let artifactURL: URL?
        if let artifact = decision.artifact {
            guard artifact.timingOriginSeconds == 0,
                  ["srt", "vtt", "ass", "ssa"].contains(artifact.format.lowercased()),
                  let url = client.mediaURL(artifact.url) else {
                throw MediaProviderError.backendSpecific(underlying: "Silo returned an unsupported subtitle artifact format or timeline.")
            }
            artifactURL = try relay.localURL(for: url)
        } else {
            artifactURL = nil
        }
        return decision.inventory.map { track in
            let isSelected = decision.mode != "off" && track.trackId == selectedID
            let native = isSelected ? decision.embedded : nil
            // Inventory is menu authority, not delivery authority. Registering
            // every URL makes Aether prefetch whole-file extractions even when
            // subtitles are off. Only the plan's selected artifact is mounted.
            var mapped = SubtitleTrack(id: track.trackId, index: track.combinedIndex,
                                       codec: isSelected ? decision.artifact?.format ?? track.codec ?? "unknown" : track.codec ?? "unknown",
                                       language: track.language, title: track.label, extendedTitle: track.label,
                                       isDefault: track.default, isForced: track.forced, isHearingImpaired: track.hearingImpaired,
                                       isEmbedded: native != nil, externalURL: isSelected ? artifactURL : nil, isSelected: isSelected)
            mapped.nativeStreamIndex = native?.streamIndex
            mapped.siloSyncTarget = track.syncTarget(fileID: plan.effectiveMediaFileId)
            // The session relay obtains current, origin-scoped credentials for
            // each fetch; neither account headers nor node grants reach players.
            mapped.externalHTTPHeaders = [:]
            return mapped
        }
    }

    @MainActor
    private static func playbackCapabilities(transcodeOnly: Bool, serverDeliveries: [String],
                                             hlsVariableSubstitution: Bool) -> (SiloCodecCapabilities, SiloPlaybackContext) {
        let video = ["h264", "hevc", "av1", "vp9", "vp8", "mpeg2video", "mpeg4", "vc1"]
        let audio = ["aac", "ac3", "eac3", "truehd", "dts", "flac", "opus", "vorbis", "mp3", "pcm_s16le", "pcm_s24le"]
        let containers = ["mkv", "matroska", "mp4", "mov", "m4v", "mpegts", "ts", "m2ts", "webm", "avi"]
        var hardware: [String] = []
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_H264) { hardware.append("h264") }
        if VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) { hardware.append("hevc") }
        let modes = AVPlayer.availableHDRModes
        let dv = AetherEngine.displayCapabilities.supportsDolbyVision
        let fel = UserDefaults.standard.object(forKey: AetherPlayer.dolbyVisionFELKey) as? Bool ?? true
        let hdr = SiloHDRCapabilities(hdr10: modes.contains(.hdr10), hdr10Plus: false, hlg: modes.contains(.hlg),
                                       dolbyVisionProfiles: dv ? (fel ? [5, 7, 8] : [5, 8]) : [])
        let caps = SiloCodecCapabilities(codecsVideo: video, codecsVideoHardware: hardware, codecsAudio: audio,
                                         containers: containers, hdr: modes.rawValue != 0, hdrDetails: hdr)
        let nativeSubtitleCodecs = ["subrip", "webvtt", "mov_text", "ass", "ssa",
                                    "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"]
        let subtitles = SiloSubtitleCapabilities(embeddedText: false, sidecarText: true, assStyling: true,
                                                 embeddedBitmap: false, fontAttachments: false,
                                                 nativeEmbedded: containers.map {
                                                     SiloNativeEmbeddedSubtitleCapabilities(container: $0, codecs: nativeSubtitleCodecs)
                                                 })
        var deliveries: [String: SiloDeliveryCapabilities] = [:]
        if !transcodeOnly, serverDeliveries.contains("original_http") {
            // Aether inspects the original DV records/layers and owns output
            // mapping (P7 MEL -> native P8.1; FEL follows the user's setting).
            // Silo cannot infer that from the panel's supported profile list:
            // without the scoped claim its P7 planner strips DV on the server.
            // Original bytes also retain every audio stream for the plan's
            // selected ordinal to be mapped onto the probed engine inventory.
            deliveries["original_http"] = SiloDeliveryCapabilities(containers: containers, videoCodecs: video,
                                                                    audioDecodeCodecs: audio, subtitles: subtitles,
                                                                    validatedClaims: ["client_managed_dynamic_range_v1",
                                                                                      "client_selected_audio_track_v1"], hdrDetails: hdr)
        }
        if !transcodeOnly, serverDeliveries.contains("server_remux_progressive") {
            deliveries["server_remux_progressive"] = SiloDeliveryCapabilities(
                containers: ["mp4", "mov", "m4v", "mpegts", "ts"], videoCodecs: video,
                audioDecodeCodecs: audio, subtitles: subtitles, hdrDetails: hdr)
        }
        if serverDeliveries.contains("server_transcode_hls") || serverDeliveries.contains("server_remux_hls") {
            // The native delivery container is HLS, not its segment packaging.
            deliveries["hls"] = SiloDeliveryCapabilities(containers: ["hls"], videoCodecs: ["h264", "hevc"],
                                                                         audioDecodeCodecs: ["aac", "ac3", "eac3", "flac"],
                                                                         subtitles: SiloSubtitleCapabilities(embeddedText: false, sidecarText: true,
                                                                                                            assStyling: false, embeddedBitmap: false, fontAttachments: false),
                                                                         features: hlsVariableSubstitution ? ["hls_variable_substitution_v1"] : [],
                                                                         hdrDetails: hdr)
        }
        let context = SiloPlaybackContext(appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
                                          appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
                                          device: SiloDeviceContext(model: UIDevice.current.model, osVersion: UIDevice.current.systemVersion),
                                          output: SiloOutputContext(hdrDetails: hdr), deliveries: deliveries)
        return (caps, context)
    }

    @MainActor
    func progressReporter(for itemRef: MediaItemRef, sourceID: String?, playSessionID: String?) -> any ProgressReporter {
        let context: SiloReportContext? = playSessionID.flatMap { sessionID in
            playbackSessions.withLock { sessions in
                guard let session = sessions[sessionID], session.ref == itemRef else { return nil }
                return SiloReportContext(installationID: session.installationID, sessionID: session.sessionID,
                                         lifetime: session.lifetime, relay: session.relay)
            }
        }
        if let existing = context?.lifetime.reporter { return existing }
        let reporter = SiloProgressReporter(client: client, provider: self, ref: itemRef, context: context)
        return context?.lifetime.attach(reporter) ?? reporter
    }

    func updateProgress(_ itemRef: MediaItemRef, position: TimeInterval) async throws {
        guard position.isFinite, position >= 0 else { throw MediaProviderError.notPlayable }
        let detail: SiloItem = try await client.get("catalog/items/\(Self.pathComponent(itemRef.itemID))")
        let duration = detail.durationSeconds ?? detail.runtime.map { Double($0) * 60 } ?? 0
        guard let positionMs = Int64(exactly: (position * 1000).rounded()),
              let durationMs = Int64(exactly: (duration * 1000).rounded()) else { throw MediaProviderError.notPlayable }
        let result: SiloProgressSyncResult = try await client.post("sync/progress", body: SiloProgressSyncBody(items: [
            SiloProgressSyncItem(mediaItemId: itemRef.itemID, positionMs: positionMs, durationMs: durationMs)
        ]))
        guard result.items.count == 1, result.items[0].status == "success" else {
            throw MediaProviderError.backendSpecific(underlying: result.items.first?.failure?.detail ?? "Silo refused the progress update.")
        }
    }

    func setSelectedAudioTrack(_ trackID: String, source sourceID: String, of itemRef: MediaItemRef) async throws {
        let detail: SiloItem = try await client.get("watch/\(Self.pathComponent(itemRef.itemID))")
        guard let seriesID = detail.seriesId else {
            throw MediaProviderError.backendSpecific(underlying: "Silo only persists audio-track preferences for series.")
        }
        guard let source = detail.versions?.first(where: { $0.fileId == sourceID }),
              let index = Self.trackIndex(trackID, fileID: sourceID, kind: "audio"),
              let tracks = source.audioTracks, tracks.indices.contains(index) else { throw MediaProviderError.notFound }
        let track = tracks[index]
        let signature = SiloAudioSignature(language: track.language, codec: track.codec, channels: track.channels, layout: track.layout,
                                           title: track.title, embeddedTitle: track.embeddedTitle, default: track.default)
        try await client.put("audio-prefs/\(Self.pathComponent(seriesID))",
                             body: SiloAudioPreference(audioTrackIndex: index, audioLanguage: track.language, trackSignature: signature))
    }

    func setSelectedSubtitleTrack(_ trackID: String?, source sourceID: String, of itemRef: MediaItemRef) async throws {
        let detail: SiloItem = try await client.get("watch/\(Self.pathComponent(itemRef.itemID))")
        guard let seriesID = detail.seriesId else {
            throw MediaProviderError.backendSpecific(underlying: "Silo only persists subtitle-track preferences for series.")
        }
        guard detail.versions?.contains(where: { $0.fileId == sourceID }) == true else { throw MediaProviderError.notFound }
        let selected: SiloPlanSubtitleTrack?
        if let trackID {
            selected = playbackSessions.withLock { sessions in
                sessions.values.first(where: { $0.ref == itemRef && $0.fileID == sourceID &&
                    $0.plan.subtitle.inventory.contains(where: { $0.trackId == trackID }) })?
                    .plan.subtitle.inventory.first(where: { $0.trackId == trackID })
            }
            guard selected != nil else { throw MediaProviderError.notFound }
        } else {
            selected = nil
        }
        let index = selected?.combinedIndex ?? -1
        let signature = selected.map { SiloSubtitleSignature(language: $0.language, codec: $0.codec, forced: $0.forced,
                                                              hearingImpaired: $0.hearingImpaired, source: $0.source, label: $0.label) }
        try await client.put("subtitle-prefs/\(Self.pathComponent(seriesID))",
                             body: SiloSubtitlePreference(subtitleTrackIndex: index, subtitleLanguage: selected?.language,
                                                          subtitleMode: selected == nil ? "off" : "always",
                                                          externalSubtitlePath: nil, trackSignature: signature))
    }

    private static func trackIndex(_ value: String, fileID: String, kind: String) -> Int? {
        let prefix = "file:\(fileID):\(kind):"
        guard value.hasPrefix(prefix) else { return nil }
        return Int(value.dropFirst(prefix.count))
    }
}

/// Shared by every plan of one native session. The weak reporter lets an
/// explicit replacement drain/cancel its owner without retaining a player.
nonisolated final class SiloPlaybackLifetime: Sendable {
    private struct State: Sendable {
        var active = true
        weak var reporter: SiloProgressReporter?
        var suspended = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    let events = SiloPlaybackSessionEvents()

    var isSuspended: Bool { state.withLock { $0.suspended } }
    var isEnded: Bool {
        if case .some(.ended) = events.pending { return true }
        return false
    }
    func receive(_ problem: SiloAPIError) {
        guard let event = SiloPlaybackSessionFault.classify(problem) else { return }
        let accepted = state.withLock { value -> Bool in
            guard value.active, (!value.suspended || problem.status == 410) else { return false }
            value.suspended = true
            return true
        }
        guard accepted else { return }
        events.publish(event)
        Task { [weak self] in await self?.reporter?.suspendForServerFault() }
    }

    var isActive: Bool { state.withLock { $0.active } }
    var reporter: SiloProgressReporter? { state.withLock { $0.reporter } }

    func attach(_ reporter: SiloProgressReporter) -> SiloProgressReporter {
        state.withLock {
            if let existing = $0.reporter { return existing }
            $0.reporter = reporter
            return reporter
        }
    }

    func deactivate() { state.withLock { $0.active = false }; events.finish() }
}

nonisolated struct SiloReportContext: Sendable {
    let installationID: String
    let sessionID: String
    let lifetime: SiloPlaybackLifetime
    let relay: SiloMediaRelay
}

actor SiloProgressReporter: ProgressReporter {
    private let client: SiloClient
    private let provider: SiloProvider
    private let ref: MediaItemRef
    private let context: SiloReportContext?
    private let stopID = UUID().uuidString.lowercased()
    private var sequence = 0
    private var stopped = false
    private var hasStarted = false
    var hasPlayed: Bool { hasStarted && !stopped }
    private var latestPosition: Double = 0
    private var lastPaused = false
    private var previous: Task<Result<Void, any Error>, Never>?
    private var heartbeat: Task<Void, Never>?
    private let logger = Logger(subsystem: "Rivulet", category: "SiloPlayback")

    init(client: SiloClient, provider: SiloProvider, ref: MediaItemRef, context: SiloReportContext?) {
        self.client = client
        self.provider = provider
        self.ref = ref
        self.context = context
    }

    deinit { heartbeat?.cancel() }

    func start(position: TimeInterval) async { await record(position: position, paused: false) }
    func progress(position: TimeInterval) async { await record(position: position, paused: false) }
    func paused(at position: TimeInterval) async { await record(position: position, paused: true) }

    func stopped(at position: TimeInterval) async {
        guard stopped || context?.lifetime.isActive != false else { return }
        if hasStarted, position.isFinite { latestPosition = max(0, position) }
        do { try await stopForRetirement() }
        catch { logger.error("Silo playback stop failed") }
    }

    /// Used by explicit source changes/disposal. A played session gets its last
    /// real sample; a reservation that never played is stopped without one.
    func stopForRetirement(position: Double? = nil) async throws {
        if !stopped, hasStarted, let position, position.isFinite { latestPosition = max(0, position) }
        if stopped {
            if let previous { try await previous.value.get() }
            return
        }
        stopped = true
        heartbeat?.cancel()
        heartbeat = nil
        context?.lifetime.deactivate()
        let result = await enqueue(stop: true, includeSample: hasStarted)
        try result.get()
    }

    private func record(position: Double, paused: Bool) async {
        guard !stopped, position.isFinite, context?.lifetime.isActive != false else { return }
        if context?.lifetime.isSuspended == true { latestPosition = max(0, position); return }
        hasStarted = true
        latestPosition = max(0, position)
        lastPaused = paused
        ensureHeartbeat()
        _ = await enqueue(stop: false, includeSample: true)
    }

    private func ensureHeartbeat() {
        guard heartbeat == nil, context != nil else { return }
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) }
                catch { return }
                guard let self else { return }
                await self.heartbeatTick()
            }
        }
    }

    private func heartbeatTick() async {
        guard !stopped, context?.lifetime.isActive == true, context?.lifetime.isSuspended == false else {
            heartbeat?.cancel()
            heartbeat = nil
            return
        }
        // Repeat the latest observed source position, including while paused or
        // buffering. Wall-clock liveness must not invent position advancement.
        _ = await enqueue(stop: false, includeSample: true)
    }

    func suspendForServerFault() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    private func enqueue(stop: Bool, includeSample: Bool) async -> Result<Void, any Error> {
        if includeSample { sequence += 1 }
        let sequence = sequence
        let position = latestPosition
        let paused = lastPaused
        let prior = previous
        let client = client
        let provider = provider
        let ref = ref
        let context = context
        let stopID = stopID
        let logger = logger
        // The stop drains every already-dispatched request. Queued samples check
        // the session gate again, so none can be sent after explicit retirement.
        let task = Task<Result<Void, any Error>, Never> {
            _ = await prior?.value
            if !stop, (context?.lifetime.isActive == false || context?.lifetime.isSuspended == true) { return .success(()) }
            defer {
                if stop, let context {
                    context.relay.stop()
                    provider.playbackSessions.withLock { _ = $0.removeValue(forKey: context.sessionID) }
                }
            }
            do {
                if let context {
                    let path = "playback/\(SiloProvider.pathComponent(context.sessionID))"
                    if stop {
                        let result: SiloPlaybackMutation
                        if includeSample {
                            result = try await client.delete(path, body: SiloPlaybackStop(installationId: context.installationID,
                                                                                          stopId: stopID, sequence: sequence,
                                                                                          position: position, isPaused: paused))
                        } else {
                            result = try await client.delete(path, body: SiloPlaybackDiscard(installationId: context.installationID, stopId: stopID))
                        }
                        guard ["stopped", "replayed"].contains(result.outcome) else {
                            throw MediaProviderError.backendSpecific(underlying: "Silo did not accept the playback stop: \(result.outcome)")
                        }
                    } else {
                        let result: SiloPlaybackMutation = try await client.post("\(path)/progress",
                                                                                body: SiloPlaybackProgress(installationId: context.installationID,
                                                                                                           sequence: sequence, position: position, isPaused: paused))
                        guard ["applied", "replayed"].contains(result.outcome) else {
                            throw MediaProviderError.backendSpecific(underlying: "Silo did not accept playback progress: \(result.outcome)")
                        }
                    }
                } else if includeSample {
                    logger.warning("No native Silo session was supplied; reporting profile progress without a playback session")
                    try await provider.updateProgress(ref, position: position)
                }
                return .success(())
            } catch {
                if !stop, let context, let problem = error as? SiloAPIError {
                    context.lifetime.receive(problem)
                }
                // Public ProgressReporter cannot throw; internal retirement does,
                // and uncertain writes are never automatically replayed.
                logger.error("Silo playback \(stop ? "stop" : "progress", privacy: .public) failed at sequence \(sequence)")
                return .failure(error)
            }
        }
        previous = task
        return await task.value
    }
}
