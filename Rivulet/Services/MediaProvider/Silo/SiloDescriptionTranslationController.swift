// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Combine
import Foundation

/// Owns only local observation. Stopping never cancels a durable server job.
@MainActor
final class SiloDescriptionTranslationController: ObservableObject {
    @Published private(set) var detail: MediaItemDetail?
    @Published private(set) var isTranslating = false
    @Published private(set) var canTranslate = false
    @Published private(set) var errorMessage: String?

    struct Dependencies {
        var capability: @MainActor (SiloProvider) async throws -> SiloMetadataAICapability = {
            try await $0.descriptionTranslationCapability()
        }
        var translate: @MainActor (SiloProvider, String, String) async throws -> SiloDescriptionTranslationJob = {
            try await $0.translateDescription(contentID: $1, language: $2)
        }
        var fetch: @MainActor (SiloProvider, MediaItemRef) async throws -> MediaItemDetail = {
            try await $0.fullDetail(for: $1)
        }
        var sleep: @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    }

    private struct Owner: Equatable {
        let provider: ObjectIdentifier
        let authorityRevision: UInt64
        let ref: MediaItemRef
    }

    private let dependencies: Dependencies
    private let pollInterval: Duration
    private let maximumPolls: Int
    private let operationTimeout: Duration
    private var provider: SiloProvider?
    private var owner: Owner?
    private var language: String?
    private var capability: SiloMetadataAICapability?
    private var discoveredCapability = false
    private var allowAutomatic = false
    // Retain attempts across stop/reappear: an uncertain mutation must never be
    // automatically replayed. A deliberate Retry remains possible after failure.
    private var attemptedLanguages: Set<String> = []
    private var failedLanguages: Set<String> = []
    private var task: Task<Void, Never>?
    private var operationID = UUID()

    init(dependencies: Dependencies = Dependencies(), pollInterval: Duration = .seconds(2), maximumPolls: Int = 60,
         operationTimeout: Duration = .seconds(120)) {
        self.dependencies = dependencies
        self.pollInterval = pollInterval
        self.maximumPolls = max(1, maximumPolls)
        self.operationTimeout = operationTimeout
    }

    func configure(provider: SiloProvider, detail: MediaItemDetail, allowAutomatic: Bool) {
        guard detail.item.ref.providerID == provider.id else {
            stop()
            return
        }
        let nextOwner = Owner(provider: ObjectIdentifier(provider), authorityRevision: provider.authorityRevision,
                              ref: detail.item.ref)
        let nextLanguage = Self.pendingLanguage(detail)
        let ownerChanged = owner != nextOwner
        if ownerChanged || language != nextLanguage {
            invalidateOperation()
            if ownerChanged {
                attemptedLanguages.removeAll()
                failedLanguages.removeAll()
            }
            capability = nil
            discoveredCapability = false
            errorMessage = nil
        }
        owner = nextOwner
        self.provider = provider
        language = nextLanguage
        self.detail = detail
        self.allowAutomatic = allowAutomatic
        updateAction()
        guard nextLanguage != nil else { return }
        // A benign refresh cannot replace the task or replay its POST.
        guard task == nil else { return }
        if discoveredCapability {
            startAutomaticallyIfNeeded()
            return
        }
        discoveredCapability = true
        let id = UUID()
        operationID = id
        task = Task { [weak self] in
            guard let self else { return }
            let result = try? await dependencies.capability(provider)
            guard isCurrent(id) else { return }
            capability = result
            task = nil
            updateAction()
            startAutomaticallyIfNeeded()
        }
    }

    func translate() {
        guard canTranslate else { return }
        startTranslation()
    }

    func stop() {
        if isTranslating, let language { failedLanguages.insert(language) }
        invalidateOperation()
        provider = nil
        capability = nil
        discoveredCapability = false
        // Keep the last immutable, bound detail for hosts retaining their text.
        // A subsequent configure replaces it before beginning any new work.
        errorMessage = nil
        canTranslate = false
    }

    private static func pendingLanguage(_ detail: MediaItemDetail) -> String? {
        guard let language = detail.pendingDescriptionTranslationLanguage,
              !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // Preserve the exact server-selected tag in the mutation.
        return language
    }

    private func invalidateOperation() {
        operationID = UUID()
        task?.cancel()
        task = nil
        isTranslating = false
        canTranslate = false
    }

    private func isCurrent(_ id: UUID) -> Bool {
        operationID == id && !Task.isCancelled
    }

    private func updateAction() {
        guard !isTranslating, provider != nil, let language,
              Self.pendingLanguageIfPresent(detail) == language,
              capability?.canTranslate == true else {
            canTranslate = false
            return
        }
        canTranslate = capability?.onView == "button" || failedLanguages.contains(language)
    }

    private static func pendingLanguageIfPresent(_ detail: MediaItemDetail?) -> String? {
        detail.flatMap(pendingLanguage)
    }

    private func startAutomaticallyIfNeeded() {
        guard allowAutomatic, capability?.canTranslate == true, capability?.onView == "auto",
              let language, !attemptedLanguages.contains(language), task == nil else { return }
        startTranslation()
    }

    private func startTranslation() {
        guard task == nil, let provider, let ref = detail?.item.ref, let language,
              capability?.canTranslate == true else { return }
        attemptedLanguages.insert(language)
        failedLanguages.remove(language)
        errorMessage = nil
        isTranslating = true
        canTranslate = false
        let id = UUID()
        operationID = id
        task = Task { [weak self] in
            await self?.run(provider: provider, ref: ref, language: language, id: id)
        }
    }

    private func run(provider: SiloProvider, ref: MediaItemRef, language: String, id: UUID) async {
        // The count bounds server reads; the watchdog also bounds local status
        // when a request itself is slow or ignores cooperative cancellation.
        let timeout = Task { [weak self, operationTimeout] in
            do { try await Task.sleep(for: operationTimeout) }
            catch { return }
            self?.finish(id: id, error: SiloDescriptionTranslationError.timedOut)
        }
        defer { timeout.cancel() }
        do {
            let job = try await dependencies.translate(provider, ref.itemID, language)
            guard isCurrent(id) else { return }
            try job.validate(contentID: ref.itemID, language: language)
        } catch {
            guard isCurrent(id) else { return }
            // A refusal or uncertain result may mean another viewer finished.
            // One read can recover real text; it must never trigger another POST.
            if await read(provider: provider, ref: ref, language: language, id: id) == true {
                finish(id: id)
            } else if isCurrent(id) {
                finish(id: id, error: error)
            }
            return
        }
        for _ in 0..<maximumPolls {
            do { try await dependencies.sleep(pollInterval) }
            catch {
                if isCurrent(id) { finish(id: id, error: error) }
                return
            }
            guard isCurrent(id) else { return }
            if await read(provider: provider, ref: ref, language: language, id: id) == true {
                finish(id: id)
                return
            }
            guard isCurrent(id) else { return }
        }
        finish(id: id, error: SiloDescriptionTranslationError.timedOut)
    }

    /// nil means the read failed; false means this language is still missing.
    private func read(provider: SiloProvider, ref: MediaItemRef, language: String, id: UUID) async -> Bool? {
        guard isCurrent(id) else { return nil }
        guard let fresh = try? await dependencies.fetch(provider, ref), isCurrent(id) else { return nil }
        guard fresh.item.ref == ref else { return nil }
        guard Self.pendingLanguage(fresh) != language else { return false }
        detail = fresh
        return true
    }

    private func finish(id: UUID, error: Error? = nil) {
        guard isCurrent(id) else { return }
        operationID = UUID()
        task?.cancel()
        task = nil
        isTranslating = false
        if let error {
            if let language { failedLanguages.insert(language) }
            errorMessage = error.localizedDescription
        } else {
            errorMessage = nil
        }
        updateAction()
    }
}
