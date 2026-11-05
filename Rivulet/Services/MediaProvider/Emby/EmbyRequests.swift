// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  EmbyRequests.swift
//  Rivulet
//
//  Lets the Jellyfin client and provider talk to an Emby server unchanged.
//  Jellyfin forked from Emby and the two still share the REST surface
//  JellyfinProvider uses, except for:
//  - the auth header: Emby reads `X-Emby-Authorization` (plus `X-Emby-Token`),
//    Jellyfin `Authorization`;
//  - the per-user routes Jellyfin 10.9 shortened (`UserViews`, `UserItems/…`,
//    `UserPlayedItems/…`, `Users/Me`, user-less `Items`). Emby keys them on
//    `Users/{userId}/…` and fills in user data only when a GET names the user.
//
//  Both are fixed here, on the finished URLRequest, through JellyfinClient's
//  `transport` parameter, so no Jellyfin file knows Emby exists. An Emby
//  difference found on a device goes into `route`, never into the provider.
//

import Foundation

nonisolated enum EmbyRequests {

    /// A JellyfinClient transport that rewrites each request for Emby, then sends it.
    static func transport(
        baseURL: URL, userID: String?, token: String?,
        sending: @escaping JellyfinClient.Transport = { try await URLSession.shared.data(for: $0) }
    ) -> JellyfinClient.Transport {
        { request in try await sending(rewrite(request, baseURL: baseURL, userID: userID, token: token)) }
    }

    static func rewrite(_ request: URLRequest, baseURL: URL, userID: String?, token: String?) -> URLRequest {
        var out = request
        if let auth = request.value(forHTTPHeaderField: "Authorization") {
            out.setValue(nil, forHTTPHeaderField: "Authorization")
            out.setValue(auth, forHTTPHeaderField: "X-Emby-Authorization")
        }
        if let token { out.setValue(token, forHTTPHeaderField: "X-Emby-Token") }

        guard let userID, let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return out }
        let method = request.httpMethod ?? "GET"
        // The path below the base, which may carry a reverse-proxy prefix ("/emby").
        let basePath = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        let prefix = basePath.hasSuffix("/") ? String(basePath.dropLast()) : basePath
        var relative = components.percentEncodedPath
        if !prefix.isEmpty, relative.hasPrefix(prefix) { relative.removeFirst(prefix.count) }
        relative = String(relative.drop(while: { $0 == "/" }))

        components.percentEncodedPath = prefix + "/" + route(method, relative, userID: userID)
        if method == "GET", !(components.queryItems ?? []).contains(where: {
            $0.name.caseInsensitiveCompare("userId") == .orderedSame
        }) {
            let existing = components.percentEncodedQuery.map { $0 + "&" } ?? ""
            components.percentEncodedQuery = existing + "UserId=" + userID
        }
        out.url = components.url ?? url
        return out
    }

    /// Jellyfin path -> Emby path, both relative to the server base.
    static func route(_ method: String, _ path: String, userID: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard let head = parts.first else { return path }
        let rest = parts.dropFirst().joined(separator: "/")
        let user = "Users/\(userID)"
        switch head {
        case "UserViews" where parts.count == 1:
            return "\(user)/Views"
        case "UserItems" where parts.count > 1:
            return "\(user)/Items/\(rest)"
        case "UserPlayedItems" where parts.count > 1:
            return "\(user)/PlayedItems/\(rest)"
        case "UserFavoriteItems" where parts.count > 1:
            return "\(user)/FavoriteItems/\(rest)"
        case "Users" where parts.count == 2 && parts[1] == "Me":
            return user
        case "Items" where method == "GET":
            // Queries, one item, Items/Latest and an item's local extras are
            // user routes on Emby. Items/{id}/Similar, /PlaybackInfo and the
            // image routes are not, and keep their path.
            if parts.count == 1 { return "\(user)/Items" }
            if parts.count == 2 { return "\(user)/Items/\(rest)" }
            if parts.count == 3, ["LocalTrailers", "SpecialFeatures"].contains(parts[2]) {
                return "\(user)/Items/\(rest)"
            }
            return path
        default:
            return path
        }
    }
}
