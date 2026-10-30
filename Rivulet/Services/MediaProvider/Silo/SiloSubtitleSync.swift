// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// A server-published identity, never reconstructed from a label, ordinal or sidecar URL.
nonisolated struct SiloSubtitleSyncTarget: Hashable, Sendable {
    let fileID: String
    let key: String
}

nonisolated struct SiloSubtitleTiming: Codable, Equatable, Sendable {
    let offsetMs: Int
    let scale: Double

    static let identity = SiloSubtitleTiming(offsetMs: 0, scale: 1)
    var isIdentity: Bool { self == .identity }
}

nonisolated struct SiloSubtitleSyncStatus: Decodable, Sendable {
    let revision: String
    let state: String
    let allowed: Bool
    let autoSync: Bool
    /// Absence means the server predates keyed targets; do not fall back to stored-only routes.
    let external: Bool?

    var isAvailable: Bool { allowed && state == "available" && external != nil }

    func canSync(_ subtitle: SiloSubtitleSyncState) -> Bool {
        guard isAvailable else { return false }
        return subtitle.source == "downloaded" || (subtitle.source == "external" && external == true)
    }
}

/// Metadata only: Silo has already applied this correction to delivered subtitle bytes.
nonisolated struct SiloSubtitleSyncJob: Decodable, Equatable, Sendable {
    let id: String
    let subtitleId: String?
    let status: String
    let trigger: String
    let phase: String?
    let progress: Double?
    let failure: String?
    let confidence: Double?
    let result: SiloSubtitleTiming?
    let createdAt: String
    let finishedAt: String?

    var isActive: Bool { status == "pending" || status == "running" }
}

nonisolated struct SiloSubtitleSyncState: Decodable, Equatable, Sendable {
    let key: String
    let mediaFileId: String
    let source: String
    let storedSubtitleId: String?
    let language: String
    let format: String
    let label: String
    let timing: SiloSubtitleTiming
    let sync: SiloSubtitleSyncJob?

    var target: SiloSubtitleSyncTarget { SiloSubtitleSyncTarget(fileID: mediaFileId, key: key) }
}

nonisolated struct SiloSubtitleSyncRead: Sendable {
    let subtitle: SiloSubtitleSyncState
    /// Only this exact read's validator authorizes a timing write.
    let entityTag: String?
}

private nonisolated struct SiloSubtitleSyncEnvelope: Decodable, Sendable {
    let subtitle: SiloSubtitleSyncState
}

extension SiloProvider {
    func subtitleSyncStatus() async throws -> SiloSubtitleSyncStatus {
        try await client.get("subtitles/sync/status")
    }

    func subtitleSyncState(target: SiloSubtitleSyncTarget) async throws -> SiloSubtitleSyncRead {
        try checkSubtitleSyncAuthority()
        let response: SiloClient.Resource<SiloSubtitleSyncEnvelope> = try await client.getResource(subtitleSyncPath(target))
        guard response.value.subtitle.target == target else { throw SiloSignInError.invalidResponse }
        return SiloSubtitleSyncRead(subtitle: response.value.subtitle, entityTag: response.entityTag)
    }

    /// Sent once. Coalescing an active job does not authorize replay after an uncertain response.
    func startSubtitleSync(target: SiloSubtitleSyncTarget) async throws -> SiloSubtitleSyncState {
        try checkSubtitleSyncAuthority()
        let response: SiloSubtitleSyncEnvelope = try await client.post(subtitleSyncPath(target))
        guard response.subtitle.target == target, response.subtitle.sync != nil else { throw SiloSignInError.invalidResponse }
        return response.subtitle
    }

    /// Read immediately before reset. Missing/stale validators fail; no wildcard or automatic retry.
    func resetSubtitleTiming(target: SiloSubtitleSyncTarget) async throws -> SiloSubtitleSyncRead {
        let current = try await subtitleSyncState(target: target)
        guard let entityTag = current.entityTag, !entityTag.isEmpty, entityTag != "*",
              !entityTag.hasPrefix("W/") else { throw SiloSignInError.invalidResponse }
        try checkSubtitleSyncAuthority()
        let response: SiloClient.Resource<SiloSubtitleSyncEnvelope> = try await client.putResource(
            subtitleSyncPath(target) + "/timing", body: SiloSubtitleTiming.identity, ifMatch: entityTag)
        guard response.value.subtitle.target == target else { throw SiloSignInError.invalidResponse }
        return SiloSubtitleSyncRead(subtitle: response.value.subtitle, entityTag: response.entityTag)
    }

    private func checkSubtitleSyncAuthority() throws {
        try Task.checkCancellation()
        guard client.profileID == profileID else { throw MediaProviderError.unauthorized }
    }

    private func subtitleSyncPath(_ target: SiloSubtitleSyncTarget) -> String {
        "subtitles/\(Self.pathComponent(target.fileID))/sync/\(Self.pathComponent(target.key))"
    }
}
