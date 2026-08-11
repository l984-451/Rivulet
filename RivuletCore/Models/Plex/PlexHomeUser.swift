// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  PlexHomeUser.swift
//  Rivulet
//
//  Model for Plex Home users (managed profiles)
//

import Foundation

// MARK: - Plex Home User

/// Represents a user in a Plex Home (admin or managed user)
/// Returned from GET https://plex.tv/api/v2/home/users
nonisolated struct PlexHomeUser: Codable, Identifiable, Sendable, Hashable {
    /// Numeric user ID - used for X-Plex-User-Id header
    let id: Int

    /// Unique identifier (UUID format)
    let uuid: String

    /// Display name
    let title: String

    /// Plex account username (email) - nil for managed users
    let username: String?

    /// Friendly display name (alternative to title)
    let friendlyName: String?

    /// Avatar URL
    let thumb: String?

    /// Email address - nil for managed users
    let email: String?

    /// Whether this is the account owner/admin
    let admin: Bool

    /// Whether this is a managed/restricted user (child account)
    let restricted: Bool

    /// Whether this profile has a PIN set
    let protected: Bool

    /// Whether this is a guest account
    let guest: Bool

    /// Restriction profile applied (e.g., "little_kid", "older_kid", "teen")
    let restrictionProfile: String?

    // MARK: - Computed Properties

    /// Best display name to show in UI
    var displayName: String {
        friendlyName ?? title
    }

    /// Whether PIN entry is required to switch to this profile
    var requiresPin: Bool {
        protected
    }

    /// Whether this is a child/managed account
    var isManagedUser: Bool {
        restricted || !admin
    }

    // MARK: - Coding Keys

    enum CodingKeys: String, CodingKey {
        case id, uuid, title, username, friendlyName, thumb, email
        case admin, restricted, protected, guest, restrictionProfile
    }

    // MARK: - Custom Decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Handle id as either Int or String
        if let idInt = try? container.decode(Int.self, forKey: .id) {
            id = idInt
        } else if let idString = try? container.decode(String.self, forKey: .id),
                  let idInt = Int(idString) {
            id = idInt
        } else {
            throw DecodingError.dataCorruptedError(
                forKey: .id,
                in: container,
                debugDescription: "Expected Int or String for id"
            )
        }

        uuid = try container.decode(String.self, forKey: .uuid)
        title = try container.decode(String.self, forKey: .title)
        username = try container.decodeIfPresent(String.self, forKey: .username)
        friendlyName = try container.decodeIfPresent(String.self, forKey: .friendlyName)
        thumb = try container.decodeIfPresent(String.self, forKey: .thumb)
        email = try container.decodeIfPresent(String.self, forKey: .email)
        restrictionProfile = try container.decodeIfPresent(String.self, forKey: .restrictionProfile)

        // Handle booleans that may come as Int (0/1) or Bool
        admin = try Self.decodeBoolOrInt(container: container, key: .admin) ?? false
        restricted = try Self.decodeBoolOrInt(container: container, key: .restricted) ?? false
        protected = try Self.decodeBoolOrInt(container: container, key: .protected) ?? false
        guest = try Self.decodeBoolOrInt(container: container, key: .guest) ?? false
    }

    /// Helper to decode Bool that may be represented as Int (0/1) in JSON
    private static func decodeBoolOrInt(
        container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) throws -> Bool? {
        if let boolValue = try? container.decode(Bool.self, forKey: key) {
            return boolValue
        }
        if let intValue = try? container.decode(Int.self, forKey: key) {
            return intValue != 0
        }
        return nil
    }

    // MARK: - Manual Initializer (for testing/preview)

    init(
        id: Int,
        uuid: String,
        title: String,
        username: String? = nil,
        friendlyName: String? = nil,
        thumb: String? = nil,
        email: String? = nil,
        admin: Bool = false,
        restricted: Bool = false,
        protected: Bool = false,
        guest: Bool = false,
        restrictionProfile: String? = nil
    ) {
        self.id = id
        self.uuid = uuid
        self.title = title
        self.username = username
        self.friendlyName = friendlyName
        self.thumb = thumb
        self.email = email
        self.admin = admin
        self.restricted = restricted
        self.protected = protected
        self.guest = guest
        self.restrictionProfile = restrictionProfile
    }
}

// MARK: - API Response Wrappers

/// Response wrapper for GET /api/v2/home/users (users array at root)
nonisolated struct PlexHomeUsersResponse: Codable, Sendable {
    let users: [PlexHomeUser]
}

/// Response wrapper for home object with users inside
nonisolated struct PlexHomeWrapper: Codable, Sendable {
    let id: Int?
    let name: String?
    let guestUserID: Int?
    let guestEnabled: Bool?
    let subscription: Bool?
    let users: [PlexHomeUser]

    enum CodingKeys: String, CodingKey {
        case id, name, guestUserID, guestEnabled, subscription, users
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(Int.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        guestUserID = try container.decodeIfPresent(Int.self, forKey: .guestUserID)
        guestEnabled = try container.decodeIfPresent(Bool.self, forKey: .guestEnabled)
        subscription = try container.decodeIfPresent(Bool.self, forKey: .subscription)
        users = try container.decodeIfPresent([PlexHomeUser].self, forKey: .users) ?? []
    }
}
