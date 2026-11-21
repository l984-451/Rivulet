// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

import Foundation

/// The Jellyfin and Emby users the profile pickers offer, the way Plex Home users are offered.
/// A server with one signed-in user offers none: there is nothing to switch to.
@MainActor
enum ServerUserProfiles {
    struct Profile: Identifiable, Equatable, Sendable {
        let kind: MediaProviderKind
        let userID: String
        let name: String
        let serverName: String
        let isActive: Bool
        /// The server's picture of the user; a 404 when the user has none.
        let imageURL: URL?

        var id: String { "\(kind.rawValue):\(userID)" }
    }

    /// Users of every server with more than one, active users first, then by name.
    static var profiles: [Profile] {
        let jellyfin = JellyfinSession.users.count > 1 ? JellyfinSession.users.map { user in
            Profile(kind: .jellyfin, userID: user.userID, name: user.userName, serverName: user.serverName,
                    isActive: user.userID == JellyfinSession.account?.userID,
                    imageURL: imageURL(user.serverURL, path: "UserImage", query: [URLQueryItem(name: "userId", value: user.userID)]))
        } : []
        let emby = EmbySession.users.count > 1 ? EmbySession.users.map { user in
            Profile(kind: .emby, userID: user.userID, name: user.userName, serverName: user.serverName,
                    isActive: user.userID == EmbySession.account?.userID,
                    imageURL: imageURL(user.serverURL, path: "Users/\(user.userID)/Images/Primary", query: []))
        } : []
        return (jellyfin + emby).sorted {
            if $0.isActive != $1.isActive { return $0.isActive }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static var canSwitch: Bool { JellyfinSession.users.count > 1 || EmbySession.users.count > 1 }

    /// Makes `profile` its server's active user. True when it already was.
    @discardableResult
    static func switchTo(_ profile: Profile) async -> Bool {
        guard !profile.isActive else { return true }
        switch profile.kind {
        case .jellyfin: return await JellyfinSession.switchUser(to: profile.userID)
        case .emby: return await EmbySession.switchUser(to: profile.userID)
        default: return false
        }
    }

    /// Images need no token on either server (a bad one turns Emby's 200 into a 401).
    private static func imageURL(_ base: URL, path: String, query: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { return nil }
        components.queryItems = query + [URLQueryItem(name: "maxHeight", value: "320")]
        return components.url
    }
}
