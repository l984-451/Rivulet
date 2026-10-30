// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

private struct SiloHomeDismissalBody: Encodable, Sendable {
    let progressUpdatedAt: String?
    let seriesId: String?
}

extension SiloProvider {
    static func dismissalRail(_ sectionType: String) -> MediaDismissalRail? {
        switch sectionType {
        case "continue_watching": .continueWatching
        case "next_up": .nextUp
        default: nil
        }
    }

    func dismissalMetadata(for card: SiloItem, rail: MediaDismissalRail) -> MediaItemDismissalMetadata? {
        guard !card.contentId.isEmpty else { return nil }
        switch rail {
        case .continueWatching:
            guard let timestamp = card.progressUpdatedAt, !timestamp.isEmpty else { return nil }
            return .init(rail: rail, contentID: card.contentId, progressUpdatedAt: timestamp,
                         seriesID: card.seriesId, providerIdentity: id, authorityRevision: authorityRevision)
        case .nextUp:
            guard let seriesID = card.seriesId, !seriesID.isEmpty else { return nil }
            return .init(rail: rail, contentID: card.contentId, progressUpdatedAt: nil,
                         seriesID: seriesID, providerIdentity: id, authorityRevision: authorityRevision)
        }
    }

    func dismiss(_ dismissal: MediaDismissal) async throws {
        guard dismissal.item.providerID == id, dismissal.providerIdentity == id,
              dismissal.authorityRevision == authorityRevision, client.profileID == profileID,
              !dismissal.item.itemID.isEmpty else { throw MediaProviderError.unauthorized }
        let current = await MainActor.run { SiloSession.storedProvider() }
        guard current?.id == id, current?.authorityRevision == authorityRevision else {
            throw MediaProviderError.unauthorized
        }
        let surface: String
        let body: SiloHomeDismissalBody
        switch dismissal.rail {
        case .continueWatching:
            guard dismissal.progressUpdatedAt?.isEmpty == false else { throw MediaProviderError.unauthorized }
            surface = "continue_watching"
            body = .init(progressUpdatedAt: dismissal.progressUpdatedAt, seriesId: nil)
        case .nextUp:
            guard dismissal.seriesID?.isEmpty == false else { throw MediaProviderError.unauthorized }
            surface = "next_up"
            body = .init(progressUpdatedAt: nil, seriesId: dismissal.seriesID)
        }
        // The server validates the supplied version or series against the live
        // row atomically. A separate item read cannot provide that guarantee.
        let before = await MainActor.run { SiloSession.storedProvider() }
        guard before?.id == id, before?.authorityRevision == authorityRevision else {
            throw MediaProviderError.unauthorized
        }
        let path = "home/dismissals/\(surface)/\(Self.pathComponent(dismissal.item.itemID))"
        do {
            try await client.put(path, body: body, expectedStatus: 204)
        } catch {
            // A lost reply can follow an accepted write. Read the complete
            // affected rail once; never repeat the mutation.
            if (try? await dismissalAbsentFromHome(dismissal)) == true { return }
            throw error
        }
        let after = await MainActor.run { SiloSession.storedProvider() }
        guard after?.id == id, after?.authorityRevision == authorityRevision else {
            throw MediaProviderError.unauthorized
        }
    }

    private func dismissalAbsentFromHome(_ dismissal: MediaDismissal) async throws -> Bool {
        let current = await MainActor.run { SiloSession.storedProvider() }
        guard current?.id == id, current?.authorityRevision == authorityRevision else {
            throw MediaProviderError.unauthorized
        }
        let layout: SiloSectionLayout = try await client.get("home/layout")
        let type = dismissal.rail == .continueWatching ? "continue_watching" : "next_up"
        guard let section = layout.sections.first(where: { $0.sectionType == type }) else { return false }
        let route = SiloHubRoute(scope: "home", sectionId: section.id)
        let hubID = try route.identifier()
        var page: Page? = Page(offset: 0, limit: 200)
        var seen = Set<String>()
        while let currentPage = page {
            let result = try await hubItems(hubID, page: currentPage)
            if result.items.contains(where: { $0.ref.itemID == dismissal.item.itemID }) { return false }
            page = result.nextPage
            if let cursor = page?.cursor, !seen.insert(cursor).inserted { return false }
        }
        let after = await MainActor.run { SiloSession.storedProvider() }
        guard after?.id == id, after?.authorityRevision == authorityRevision else {
            throw MediaProviderError.unauthorized
        }
        return true
    }
}
