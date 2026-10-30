// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated struct SiloMetadataAICapability: Decodable, Sendable {
    let allowed: Bool
    let state: String
    let revision: String
    let onView: String

    var canTranslate: Bool {
        allowed && state == "available" && !revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (onView == "auto" || onView == "button")
    }
}

nonisolated struct SiloDescriptionTranslationJob: Decodable, Sendable {
    let id: String
    let contentId: String
    let targetLanguage: String
    let status: String
    let errorMessage: String?

    func validate(contentID: String, language: String) throws {
        guard !id.isEmpty, contentId == contentID, targetLanguage == language else {
            throw SiloDescriptionTranslationError.unexpectedJob
        }
        switch status {
        case "pending", "running", "completed": break
        case "failed", "canceled", "cancelled":
            throw SiloDescriptionTranslationError.failedJob
        default: throw SiloDescriptionTranslationError.unexpectedJob
        }
    }
}

nonisolated enum SiloDescriptionTranslationError: Error, LocalizedError {
    case unexpectedJob
    case failedJob
    case timedOut
    case unavailable

    var errorDescription: String? {
        switch self {
        case .unexpectedJob: "Silo returned an unexpected description translation job."
        case .failedJob: "Description translation failed. You can try again."
        case .timedOut: "Description translation is taking longer than expected. You can try again."
        case .unavailable: "Description translation is currently unavailable."
        }
    }
}

private nonisolated struct SiloDescriptionTranslationBody: Encodable, Sendable {
    let targetLanguage: String
}

extension SiloProvider {
    func descriptionTranslationCapability() async throws -> SiloMetadataAICapability {
        try await client.get("capabilities/metadata-ai")
    }

    func translateDescription(contentID: String, language: String) async throws -> SiloDescriptionTranslationJob {
        // This coalescing action returns the job itself, not a job envelope.
        // SiloClient sends mutations once, even when the outcome is uncertain.
        let job: SiloDescriptionTranslationJob = try await client.post(
            "catalog/items/\(Self.pathComponent(contentID))/translate-description",
            body: SiloDescriptionTranslationBody(targetLanguage: language))
        try job.validate(contentID: contentID, language: language)
        return job
    }
}
