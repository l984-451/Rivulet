// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

nonisolated struct SiloSubtitleProviderStatus: Decodable, Sendable {
    let enabled: Bool
    let providers: [String]
    let allowed: Bool?
    let state: String?

    var canSearch: Bool { enabled && allowed != false && (state == nil || state == "available") }
}

nonisolated struct SiloSubtitleAIStatus: Decodable, Sendable {
    let enabled: Bool
    let transcribeEnabled: Bool
    let allowed: Bool?
    let state: String?

    private var available: Bool { allowed != false && (state == nil || state == "available") }
    var canTranslate: Bool { available && enabled }
    var canTranscribe: Bool { available && transcribeEnabled }
}

nonisolated struct SiloSubtitleSearchResponse: Decodable, Sendable {
    let results: [SiloSubtitleSearchResult]
    let warnings: [String]
}

nonisolated struct SiloSubtitleSearchResult: Decodable, Sendable {
    let id: String
    let provider: String
    let language: String
    let releaseName: String
    let format: String
    let score: Double
    let downloads: Int
    let hearingImpaired: Bool
}

nonisolated struct SiloStoredSubtitle: Decodable, Sendable {
    let id: String
    let mediaFileId: String
    let provider: String
    let language: String
    let format: String
    let releaseName: String
    let hearingImpaired: Bool
}

nonisolated enum SiloSubtitleAIKind: String, Encodable, Sendable {
    case translate
    case transcribe
    case transcribeTranslate = "transcribe_translate"
}

nonisolated struct SiloSubtitleGenerationOption: Sendable {
    let title: String
    let detail: String
    let kind: SiloSubtitleAIKind
    let sourceIndex: Int
    let targetLanguage: String
    let fileID: String
}

nonisolated struct SiloSubtitleAIJob: Decodable, Sendable, Identifiable {
    let id: String
    let mediaFileId: String
    let kind: String
    let status: String
    let progress: Double
    let progressMessage: String?
    let resultSubtitleId: String?
    let errorMessage: String?
    let sourceLanguage: String?
    let targetLanguage: String?

    var isActive: Bool { status == "pending" || status == "running" }
    var statusText: String {
        switch status {
        case "pending": return "Queued on Silo"
        case "running":
            let percent = Int((min(1, max(0, progress.isFinite ? progress : 0)) * 100).rounded())
            return ["\(percent)%", progressMessage].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        case "completed": return "Completed on Silo"
        case "cancelled": return "Cancelled on Silo"
        case "failed": return errorMessage ?? "Silo could not generate subtitles."
        default: return "Unknown Silo job state"
        }
    }
}

nonisolated struct SiloSubtitleQuota: Decodable, Sendable {
    let limited: Bool
    let remaining: Int
}

private nonisolated struct SiloStoredSubtitleResponse: Decodable, Sendable {
    let subtitle: SiloStoredSubtitle
}
private nonisolated struct SiloSubtitleJobResponse: Decodable, Sendable {
    let job: SiloSubtitleAIJob
}
private nonisolated struct SiloSubtitleJobsResponse: Decodable, Sendable {
    let jobs: [SiloSubtitleAIJob]
}
private nonisolated struct SiloSubtitleSearchBody: Encodable, Sendable {
    let mediaFileId: String
    let languages: [String]
}
private nonisolated struct SiloSubtitleDownloadBody: Encodable, Sendable {
    let mediaFileId: String
    let provider: String
    let subtitleId: String
    let language: String
    let releaseName: String
    let score: Double
    let hearingImpaired: Bool
}
private nonisolated struct SiloSubtitleCreateBody: Encodable, Sendable {
    let mediaFileId: String
    let kind: SiloSubtitleAIKind
    let sourceIndex: Int
    let targetLanguage: String
    let sourceLanguage = ""
    let startPosition: Double = 0
}

extension SiloProvider {
    func subtitleProviderStatus() async throws -> SiloSubtitleProviderStatus {
        try await client.get("subtitles/providers/status")
    }

    func subtitleAIStatus() async throws -> SiloSubtitleAIStatus {
        try await client.get("subtitles/ai/status")
    }

    func searchSubtitles(fileID: String, language: String) async throws -> SiloSubtitleSearchResponse {
        try await client.post("subtitles/search", body: SiloSubtitleSearchBody(mediaFileId: fileID, languages: [language]))
    }

    func downloadSubtitle(_ result: SiloSubtitleSearchResult, fileID: String) async throws -> SiloStoredSubtitle {
        // Mutations are deliberately sent once: SiloClient only replays GET after auth refresh.
        let response: SiloStoredSubtitleResponse = try await client.post("subtitles/download", body: SiloSubtitleDownloadBody(
            mediaFileId: fileID, provider: result.provider, subtitleId: result.id, language: result.language,
            releaseName: result.releaseName, score: result.score, hearingImpaired: result.hearingImpaired))
        return response.subtitle
    }

    func subtitleJobs(fileID: String) async throws -> [SiloSubtitleAIJob] {
        let response: SiloSubtitleJobsResponse = try await client.get("subtitles/ai/jobs", [URLQueryItem(name: "media_file_id", value: fileID)])
        return response.jobs
    }

    func subtitleJob(id: String) async throws -> SiloSubtitleAIJob {
        let response: SiloSubtitleJobResponse = try await client.get("subtitles/ai/jobs/\(Self.pathComponent(id))")
        return response.job
    }

    func subtitleQuota() async throws -> SiloSubtitleQuota {
        try await client.get("subtitles/ai/quota")
    }

    func generateSubtitles(fileID: String, option: SiloSubtitleGenerationOption) async throws -> SiloSubtitleAIJob {
        // No live-delivery session is attached: this client follows the durable job and installs its completed file.
        let response: SiloSubtitleJobResponse = try await client.post("subtitles/ai/translate", body: SiloSubtitleCreateBody(
            mediaFileId: fileID, kind: option.kind, sourceIndex: option.sourceIndex, targetLanguage: option.targetLanguage))
        return response.job
    }

    func cancelSubtitleJob(id: String) async throws {
        try await client.post("subtitles/ai/jobs/\(Self.pathComponent(id))/cancel")
    }
}
