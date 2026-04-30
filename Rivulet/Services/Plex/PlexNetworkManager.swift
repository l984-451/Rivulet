//
//  PlexNetworkManager.swift
//  Rivulet
//
//  Adapted from plex_watchOS NetworkManager.swift
//  Original created by Bain Gurley on 4/19/24.
//
//  This manager handles all Plex API communication with:
//  - SSL/TLS handling for self-signed certificates
//  - Priority queue system for network requests
//  - Server discovery and authentication
//  - Library browsing and content fetching
//

import Foundation
import Sentry

// MARK: - Network Priority

enum NetworkPriority {
    case high      // Current playback / critical operations
    case medium    // GUI-affecting API calls
    case low       // Prefetching / background operations
}

// MARK: - Plex Network Manager

class PlexNetworkManager: NSObject, @unchecked Sendable {
    static let shared = PlexNetworkManager()

    // Default timeout for requests
    private let defaultTimeout: TimeInterval = 30.0

    // URL session with custom delegate for self-signed certs
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = defaultTimeout
        configuration.timeoutIntervalForResource = defaultTimeout * 2
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
    }

    // MARK: - Core Request Methods

    /// Execute a request and return decoded data
    func request<T: Decodable>(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:],
        body: Data? = nil
    ) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = defaultTimeout

        // Default headers
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        // Add custom headers
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            print("🌐 PlexNetwork: ❌ Invalid response type")
            throw PlexAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            print("🌐 PlexNetwork: ❌ HTTP Error \(httpResponse.statusCode)")
            let error = PlexAPIError.httpError(statusCode: httpResponse.statusCode, data: data)

            // Capture HTTP errors to Sentry (skip 401/403 auth errors and 5xx server errors)
            if httpResponse.statusCode != 401 && httpResponse.statusCode != 403 && !(500...599).contains(httpResponse.statusCode) {
                SentrySDK.capture(error: error) { scope in
                    scope.setTag(value: "plex_network", key: "component")
                    scope.setExtra(value: url.absoluteString, key: "url")
                    scope.setExtra(value: method, key: "method")
                    scope.setExtra(value: httpResponse.statusCode, key: "status_code")
                    if let responseStr = String(data: data, encoding: .utf8) {
                        scope.setExtra(value: String(responseStr.prefix(500)), key: "response_body")
                    }
                }
            }

            throw error
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            print("🌐 PlexNetwork: ❌ Decode error: \(error)")
            if let responseStr = String(data: data, encoding: .utf8) {
                print("🌐 PlexNetwork: Full response: \(responseStr)")
            }

            // Capture JSON decode errors to Sentry
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "plex_network", key: "component")
                scope.setTag(value: "json_decode", key: "error_type")
                scope.setExtra(value: url.absoluteString, key: "url")
                scope.setExtra(value: String(describing: T.self), key: "expected_type")
                scope.setExtra(value: data.count, key: "response_size")

                // Try UTF-8 first, fall back to Latin1 (which never fails) to capture something
                if let responseStr = String(data: data, encoding: .utf8) {
                    scope.setExtra(value: String(responseStr.prefix(2000)), key: "response_body")
                } else {
                    // UTF-8 failed - capture what we can
                    scope.setTag(value: "true", key: "invalid_utf8")

                    // Latin1 encoding never fails - use it to get a lossy representation
                    if let latin1Str = String(data: data.prefix(2000), encoding: .isoLatin1) {
                        scope.setExtra(value: latin1Str, key: "response_body_latin1")
                    }

                    // Try to find the error position from the underlying error
                    let nsError = error as NSError
                    if let underlyingError = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
                       let errorIndex = underlyingError.userInfo["NSJSONSerializationErrorIndex"] as? Int {
                        scope.setExtra(value: errorIndex, key: "error_byte_position")

                        // Capture hex dump around the error position
                        let start = max(0, errorIndex - 50)
                        let end = min(data.count, errorIndex + 50)
                        let problemArea = data[start..<end]
                        let hexDump = problemArea.map { String(format: "%02x", $0) }.joined(separator: " ")
                        scope.setExtra(value: hexDump, key: "hex_around_error")

                        // Also capture as Latin1 string for context
                        if let contextStr = String(data: Data(problemArea), encoding: .isoLatin1) {
                            scope.setExtra(value: contextStr, key: "context_around_error")
                        }
                    }
                }
            }

            throw error
        }
    }

    /// Execute a request and return raw data
    func requestData(
        _ url: URL,
        method: String = "GET",
        headers: [String: String] = [:]
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = defaultTimeout

        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexAPIError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw PlexAPIError.httpError(statusCode: httpResponse.statusCode, data: data)
        }

        return data
    }

    // MARK: - Authentication

    /// Request a PIN code for authentication
    func requestPin() async throws -> (pinCode: String, pinId: Int) {
        let url = URL(string: "https://plex.tv/api/v2/pins")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue(PlexAPI.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.addValue(PlexAPI.productName, forHTTPHeaderField: "X-Plex-Product")
        request.addValue(PlexAPI.platform, forHTTPHeaderField: "X-Plex-Platform")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 201 || httpResponse.statusCode == 200 else {
            throw PlexAPIError.authenticationFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pinId = json["id"] as? Int,
              let pinCode = json["code"] as? String else {
            throw PlexAPIError.parsingError
        }

        return (pinCode, pinId)
    }

    /// Check if PIN has been authenticated
    func checkPinAuthentication(pinId: Int) async throws -> String? {
        let url = URL(string: "https://plex.tv/api/v2/pins/\(pinId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue(PlexAPI.clientIdentifier, forHTTPHeaderField: "X-Plex-Client-Identifier")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexAPIError.invalidResponse
        }

        if httpResponse.statusCode == 400 {
            throw PlexAPIError.authenticationFailed
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PlexAPIError.parsingError
        }

        // authToken will be nil if not yet authenticated
        return json["authToken"] as? String
    }

    // MARK: - Server Discovery

    /// Get list of available Plex servers for the authenticated user
    func getServers(authToken: String) async throws -> [PlexDevice] {
        let url = URL(string: "\(PlexAPI.baseUrl)/api/v2/resources")!

        var devices: [PlexDevice] = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        // Filter to only Plex Media Servers
        devices = devices.filter { $0.provides == "server" }

        // Fetch machineIdentifiers for each server (needed for plex.direct URLs)
        let machineIds = await getServerMachineIdentifiers(authToken: authToken)

        // Attach machineIdentifier to matching devices (match by name)
        return devices.map { device in
            var mutableDevice = device
            if let machineId = machineIds[device.name] {
                mutableDevice.machineIdentifier = machineId
            }
            return mutableDevice
        }
    }

    /// Fetch machine identifiers from pms/servers.xml endpoint
    /// This provides the 32-char hash needed for plex.direct URLs
    private func getServerMachineIdentifiers(authToken: String) async -> [String: String] {
        guard let url = URL(string: "\(PlexAPI.baseUrl)/pms/servers.xml") else {
            return [:]
        }

        do {
            let data = try await requestData(url, headers: plexHeaders(authToken: authToken))
            return parseServerMachineIdentifiers(from: data)
        } catch {
            print("🌐 PlexNetwork: Failed to fetch server machineIdentifiers: \(error)")
            return [:]
        }
    }

    /// Parse machineIdentifier from servers.xml response
    /// Returns dictionary mapping clientIdentifier/name to machineIdentifier
    private func parseServerMachineIdentifiers(from data: Data) -> [String: String] {
        var result: [String: String] = [:]

        // Parse XML to extract Server elements with machineIdentifier
        guard let xmlString = String(data: data, encoding: .utf8) else { return result }

        // Simple regex-based parsing for Server elements
        // Format: <Server ... machineIdentifier="xxx" ... />
        let pattern = #"<Server[^>]+machineIdentifier="([^"]+)"[^>]*>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return result }

        let matches = regex.matches(in: xmlString, range: NSRange(xmlString.startIndex..., in: xmlString))
        for match in matches {
            if let machineIdRange = Range(match.range(at: 1), in: xmlString) {
                let machineId = String(xmlString[machineIdRange])

                // Also try to extract name or accessToken to map back to resources
                let serverStart = match.range.location
                let serverEnd = min(serverStart + 500, xmlString.count)
                let serverSubstring = String(xmlString.prefix(serverEnd).suffix(serverEnd - serverStart))

                // Try to match by name
                if let nameMatch = serverSubstring.range(of: #"name="([^"]+)""#, options: .regularExpression) {
                    let nameStart = serverSubstring.index(nameMatch.lowerBound, offsetBy: 6)
                    let nameEnd = serverSubstring.index(nameMatch.upperBound, offsetBy: -1)
                    let name = String(serverSubstring[nameStart..<nameEnd])
                    result[name] = machineId
                }

                // Store by machineId as well for backup matching
                result[machineId] = machineId
            }
        }

        return result
    }

    // MARK: - Library Browsing

    /// Get all library sections (Movies, TV Shows, etc.)
    func getLibraries(serverURL: String, authToken: String, userId: Int? = nil) async throws -> [PlexLibrary] {
        guard let url = URL(string: "\(serverURL)/library/sections") else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexLibraryContainer = try await request(
            url,
            headers: plexHeaders(authToken: authToken, userId: userId)
        )

        return container.MediaContainer.Directory ?? []
    }

    /// Get all items in a library section
    func getLibraryItems(
        serverURL: String,
        authToken: String,
        sectionId: String,
        start: Int = 0,
        size: Int = 100,
        type: Int? = nil
    ) async throws -> [PlexMetadata] {
        guard var components = URLComponents(string: "\(serverURL)/library/sections/\(sectionId)/all") else {
            throw PlexAPIError.invalidURL
        }

        var queryItems = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)")
        ]
        if let type { queryItems.append(URLQueryItem(name: "type", value: "\(type)")) }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    /// Get library items with total count for pagination
    /// - Parameters:
    ///   - serverURL: The Plex server URL
    ///   - authToken: The authentication token
    ///   - sectionId: The library section ID
    ///   - start: Starting index for pagination
    ///   - size: Number of items to fetch
    ///   - sort: Sort parameter (e.g., "-addedAt", "titleSort", "-rating")
    /// - Returns: Tuple of (items, totalSize) where totalSize indicates total items in the library
    func getLibraryItemsWithTotal(
        serverURL: String,
        authToken: String,
        sectionId: String,
        start: Int = 0,
        size: Int = 100,
        sort: String? = nil,
        type: Int? = nil
    ) async throws -> (items: [PlexMetadata], totalSize: Int?) {
        guard var components = URLComponents(string: "\(serverURL)/library/sections/\(sectionId)/all") else {
            throw PlexAPIError.invalidURL
        }

        var queryItems = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)")
        ]

        // Add sort parameter if specified
        if let sort = sort, !sort.isEmpty {
            queryItems.append(URLQueryItem(name: "sort", value: sort))
        }

        // Add type filter (e.g., 8=artist, 9=album, 10=track for music)
        if let type {
            queryItems.append(URLQueryItem(name: "type", value: "\(type)"))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        let items = container.MediaContainer.Metadata ?? []
        let totalSize = container.MediaContainer.totalSize

        return (items, totalSize)
    }

    /// Get item metadata by rating key
    func getMetadata(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws -> PlexMetadata {
        guard let url = URL(string: "\(serverURL)/library/metadata/\(ratingKey)") else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        guard let item = container.MediaContainer.Metadata?.first else {
            throw PlexAPIError.notFound
        }

        return item
    }

    /// Get full metadata including cast, crew, and extras
    func getFullMetadata(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws -> PlexMetadata {
        guard var components = URLComponents(string: "\(serverURL)/library/metadata/\(ratingKey)") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "includeExtras", value: "1"),
            URLQueryItem(name: "includeOnDeck", value: "1"),
            URLQueryItem(name: "includeChapters", value: "1"),
            URLQueryItem(name: "includeRelated", value: "0"),
            URLQueryItem(name: "includeMarkers", value: "1"),
            URLQueryItem(name: "includeCollections", value: "1")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        guard var item = container.MediaContainer.Metadata?.first else {
            throw PlexAPIError.notFound
        }

        // Copy library section info from container to item if not present
        if item.librarySectionID == nil {
            item.librarySectionID = container.MediaContainer.librarySectionID
        }
        if item.librarySectionTitle == nil {
            item.librarySectionTitle = container.MediaContainer.librarySectionTitle
        }

        return item
    }

    /// Get related items (similar content)
    func getRelatedItems(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        limit: Int = 12
    ) async throws -> [PlexMetadata] {
        guard var components = URLComponents(string: "\(serverURL)/library/metadata/\(ratingKey)/related") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "count", value: "\(limit)")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    /// Get extras (trailers, behind the scenes, etc.)
    func getExtras(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws -> [PlexExtra] {
        guard let url = URL(string: "\(serverURL)/library/metadata/\(ratingKey)/extras") else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexExtrasContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    /// Get items in a collection (other movies in the same collection)
    /// - Parameters:
    ///   - sectionId: The library section ID containing the collection
    ///   - collectionId: The collection filter ID (from Collection[].id in metadata)
    ///   - excludeRatingKey: Optional ratingKey to exclude from results (typically current movie)
    func getCollectionItems(
        serverURL: String,
        authToken: String,
        sectionId: String,
        collectionId: String,
        excludeRatingKey: String? = nil
    ) async throws -> [PlexMetadata] {
        guard var components = URLComponents(string: "\(serverURL)/library/sections/\(sectionId)/all") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "collection", value: collectionId)
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        var items = container.MediaContainer.Metadata ?? []

        // Filter out the excluded item (current movie)
        if let exclude = excludeRatingKey {
            items = items.filter { $0.ratingKey != exclude }
        }

        return items
    }

    /// Get children of an item (seasons for shows, episodes for seasons, albums for artists)
    func getChildren(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws -> [PlexMetadata] {
        guard var components = URLComponents(string: "\(serverURL)/library/metadata/\(ratingKey)/children") else {
            throw PlexAPIError.invalidURL
        }

        // Include markers for skip intro/credits functionality
        components.queryItems = [
            URLQueryItem(name: "includeMarkers", value: "1")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    /// Get all leaf items (all tracks for an artist, all episodes for a show)
    /// This traverses the entire hierarchy to get leaf nodes
    func getAllLeaves(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws -> [PlexMetadata] {
        guard var components = URLComponents(string: "\(serverURL)/library/metadata/\(ratingKey)/allLeaves") else {
            throw PlexAPIError.invalidURL
        }

        // Include markers for skip intro/credits functionality
        components.queryItems = [
            URLQueryItem(name: "includeMarkers", value: "1")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    /// Get albums for a specific artist using the library section endpoint with filters
    /// This is more reliable than using /children endpoint for artists
    /// - Parameter type: Plex content type (9 = album, 10 = track)
    func getAlbumsForArtist(
        serverURL: String,
        authToken: String,
        librarySectionId: Int,
        artistId: String
    ) async throws -> [PlexMetadata] {
        // type=9 is albums in Plex API
        guard var components = URLComponents(string: "\(serverURL)/library/sections/\(librarySectionId)/all") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "type", value: "9"),  // 9 = albums
            URLQueryItem(name: "artist.id", value: artistId)
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    /// Get tracks for a specific artist using the library section endpoint with filters
    func getTracksForArtist(
        serverURL: String,
        authToken: String,
        librarySectionId: Int,
        artistId: String
    ) async throws -> [PlexMetadata] {
        // type=10 is tracks in Plex API
        guard var components = URLComponents(string: "\(serverURL)/library/sections/\(librarySectionId)/all") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "type", value: "10"),  // 10 = tracks
            URLQueryItem(name: "artist.id", value: artistId)
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    // MARK: - Continue Watching / On Deck

    /// Get "On Deck" items (continue watching)
    func getOnDeck(serverURL: String, authToken: String) async throws -> [PlexMetadata] {
        guard let url = URL(string: "\(serverURL)/library/onDeck") else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    /// Get recently added items
    func getRecentlyAdded(
        serverURL: String,
        authToken: String,
        sectionId: String? = nil,
        limit: Int = 20
    ) async throws -> [PlexMetadata] {
        var urlString = "\(serverURL)/library/recentlyAdded"
        if let section = sectionId {
            urlString = "\(serverURL)/library/sections/\(section)/recentlyAdded"
        }

        guard var components = URLComponents(string: urlString) else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(limit)")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    // MARK: - Hubs (Home Screen Sections)

    /// Get home screen hubs (global recommendations)
    /// - Parameter count: Number of items per hub (default 24, Plex defaults to ~6)
    func getHubs(serverURL: String, authToken: String, userId: Int? = nil, count: Int = 24) async throws -> [PlexHub] {
        guard var components = URLComponents(string: "\(serverURL)/hubs") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "count", value: "\(count)")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken, userId: userId)
        )

        return container.MediaContainer.Hub ?? []
    }

    /// Get library-specific hubs (recommendations for a specific library section)
    /// Returns Continue Watching, Recently Added, Recently Released, etc. for that library
    /// - Parameter count: Number of items per hub (default 24, Plex defaults to ~6)
    func getLibraryHubs(serverURL: String, authToken: String, sectionId: String, userId: Int? = nil, count: Int = 24) async throws -> [PlexHub] {
        guard var components = URLComponents(string: "\(serverURL)/hubs/sections/\(sectionId)") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "count", value: "\(count)")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken, userId: userId)
        )

        return container.MediaContainer.Hub ?? []
    }

    /// Get more items from a hub using its key (for pagination/infinite scroll)
    /// - Parameters:
    ///   - hubKey: The hub's key path (e.g., "/hubs/sections/1/continueWatching")
    ///   - hubIdentifier: The hub's identifier (e.g., "home.movies.recent") - required when hubKey is "/hubs/items"
    ///   - start: Starting index for pagination
    ///   - count: Number of items to fetch
    /// - Returns: Tuple of (items, totalSize) where totalSize indicates if more items exist
    func getHubItems(
        serverURL: String,
        authToken: String,
        hubKey: String,
        hubIdentifier: String? = nil,
        start: Int = 0,
        count: Int = 24
    ) async throws -> (items: [PlexMetadata], totalSize: Int?) {
        // The hubKey might be a full path like "/hubs/sections/1/continueWatching"
        // or just the section like "hub.movies.recentlyadded"
        let fullPath: String
        if hubKey.hasPrefix("/") {
            fullPath = "\(serverURL)\(hubKey)"
        } else {
            fullPath = "\(serverURL)/\(hubKey)"
        }

        guard var components = URLComponents(string: fullPath) else {
            throw PlexAPIError.invalidURL
        }

        var queryItems = [
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(count)")
        ]

        // The /hubs/items endpoint requires an identifier parameter to specify which hub
        // Without it, Plex returns 404. See: https://plexapi.dev/api-reference/hubs/get-a-hubs-items
        if hubKey == "/hubs/items" || hubKey.hasSuffix("/hubs/items") {
            if let identifier = hubIdentifier, !identifier.isEmpty {
                queryItems.append(URLQueryItem(name: "identifier", value: identifier))
            } else {
                // No identifier available - this request will fail, so skip it
                print("⚠️ PlexNetworkManager: Cannot paginate /hubs/items without hubIdentifier")
                return (items: [], totalSize: nil)
            }
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        let items = container.MediaContainer.Metadata ?? []
        let totalSize = container.MediaContainer.size

        return (items, totalSize)
    }

    // MARK: - Progress Reporting

    /// Report playback progress to Plex
    func reportProgress(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        timeMs: Int,
        state: String = "playing",
        duration: Int? = nil
    ) async throws {
        guard var components = URLComponents(string: "\(serverURL)/:/timeline") else {
            throw PlexAPIError.invalidURL
        }

        var queryItems = [
            URLQueryItem(name: "key", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "time", value: "\(timeMs)"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")
        ]

        if let dur = duration {
            queryItems.append(URLQueryItem(name: "duration", value: "\(dur)"))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PlexAPIError.invalidResponse
        }
    }

    /// Mark item as watched
    func markWatched(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws {
        guard var components = URLComponents(string: "\(serverURL)/:/scrobble") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                throw PlexAPIError.httpError(statusCode: httpResponse.statusCode, data: nil)
            }
            throw PlexAPIError.invalidResponse
        }

    }

    /// Mark item as unwatched
    func markUnwatched(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws {
        guard var components = URLComponents(string: "\(serverURL)/:/unscrobble") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                throw PlexAPIError.httpError(statusCode: httpResponse.statusCode, data: nil)
            }
            throw PlexAPIError.invalidResponse
        }

    }

    /// Set user rating for an item (0-10 scale, where 10 = 5 stars)
    /// Pass nil to remove the rating
    func setRating(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        rating: Int?
    ) async throws {
        guard var components = URLComponents(string: "\(serverURL)/:/rate") else {
            throw PlexAPIError.invalidURL
        }

        var queryItems = [
            URLQueryItem(name: "key", value: ratingKey),
            URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")
        ]

        if let rating = rating {
            queryItems.append(URLQueryItem(name: "rating", value: String(rating)))
        } else {
            queryItems.append(URLQueryItem(name: "rating", value: "-1"))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let (_, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            if let httpResponse = response as? HTTPURLResponse {
                throw PlexAPIError.httpError(statusCode: httpResponse.statusCode, data: nil)
            }
            throw PlexAPIError.invalidResponse
        }

    }

    /// Refresh metadata for an item (re-fetch from metadata agents)
    func refreshMetadata(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws {
        guard let url = URL(string: "\(serverURL)/library/metadata/\(ratingKey)/refresh") else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw PlexAPIError.invalidResponse
        }
    }

    /// Remove item from continue watching by marking as unwatched
    func removeFromContinueWatching(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws {
        // Mark as unwatched clears all progress and removes from "Continue Watching"
        try await markUnwatched(
            serverURL: serverURL,
            authToken: authToken,
            ratingKey: ratingKey
        )
    }

    // MARK: - Playlists

    /// Get audio playlists
    func getPlaylists(serverURL: String, authToken: String, playlistType: String = "audio") async throws -> [PlexMetadata] {
        guard var components = URLComponents(string: "\(serverURL)/playlists") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "playlistType", value: playlistType),
            URLQueryItem(name: "X-Plex-Token", value: authToken)
        ]

        guard let url = components.url else { throw PlexAPIError.invalidURL }

        let data = try await requestData(url, method: "GET", headers: ["X-Plex-Token": authToken])
        let container = try JSONDecoder().decode(PlexMediaContainerWrapper.self, from: data)
        return container.MediaContainer.Metadata ?? []
    }

    /// Get items in a playlist
    func getPlaylistItems(serverURL: String, authToken: String, ratingKey: String) async throws -> [PlexMetadata] {
        guard var components = URLComponents(string: "\(serverURL)/playlists/\(ratingKey)/items") else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: authToken)
        ]

        guard let url = components.url else { throw PlexAPIError.invalidURL }

        let data = try await requestData(url, method: "GET", headers: ["X-Plex-Token": authToken])
        let container = try JSONDecoder().decode(PlexMediaContainerWrapper.self, from: data)
        return container.MediaContainer.Metadata ?? []
    }

    /// Create a new playlist
    func createPlaylist(serverURL: String, authToken: String, title: String, type: String = "audio", ratingKeys: [String]) async throws {
        guard var components = URLComponents(string: "\(serverURL)/playlists") else {
            throw PlexAPIError.invalidURL
        }

        let uri = "server://\(PlexAPI.clientIdentifier)/com.plexapp.plugins.library/library/metadata/\(ratingKeys.joined(separator: ","))"

        components.queryItems = [
            URLQueryItem(name: "type", value: type),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "smart", value: "0"),
            URLQueryItem(name: "uri", value: uri),
            URLQueryItem(name: "X-Plex-Token", value: authToken)
        ]

        guard let url = components.url else { throw PlexAPIError.invalidURL }

        _ = try await requestData(url, method: "POST", headers: ["X-Plex-Token": authToken])
    }

    // MARK: - Streaming URLs
    
    /// Playback strategy - ordered by preference
    enum PlaybackStrategy: String, CaseIterable {
        case directPlay = "Direct Play"          // Play file directly, no processing
        case directStream = "Direct Stream"      // Remux container only, no transcoding
        case hlsTranscode = "HLS Transcode"      // Full transcode to HLS
        
        var next: PlaybackStrategy? {
            switch self {
            case .directPlay: return .directStream
            case .directStream: return .hlsTranscode
            case .hlsTranscode: return nil
            }
        }
    }

    /// Build streaming URL for the given strategy
    /// - Parameter container: The file container format (mp4, mkv, etc.) to determine direct play eligibility
    /// - Parameter isAudio: If true, uses music transcode endpoints instead of video
    func buildStreamURL(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        partKey: String? = nil,
        container: String? = nil,
        strategy: PlaybackStrategy = .directPlay,
        offsetMs: Int = 0,
        isAudio: Bool = false
    ) -> URL? {
        switch strategy {
        case .directPlay:
            // Apple TV can only direct play MP4/MOV/M4V containers
            // MKV, AVI, etc. require remuxing even if codecs are compatible
            // Audio files are generally always direct-playable
            let directPlayableContainers = ["mp4", "m4v", "mov", "mp3", "flac", "m4a", "aac", "ogg", "wav", "aiff"]
            let containerLower = container?.lowercased() ?? ""

            if !directPlayableContainers.contains(containerLower) && !containerLower.isEmpty && !isAudio {
                return nil  // Signal to try next strategy
            }
            return buildDirectPlayURL(serverURL: serverURL, authToken: authToken, partKey: partKey, ratingKey: ratingKey)
        case .directStream:
            return buildDirectStreamURL(serverURL: serverURL, authToken: authToken, ratingKey: ratingKey, offsetMs: offsetMs, isAudio: isAudio)
        case .hlsTranscode:
            return buildHLSTranscodeURL(serverURL: serverURL, authToken: authToken, ratingKey: ratingKey, offsetMs: offsetMs, isAudio: isAudio)
        }
    }
    
    /// Direct play - stream the file as-is (most efficient)
    /// Apple TV supports: H.264, HEVC (4K), AAC, AC3, E-AC3, and most common containers
    private func buildDirectPlayURL(
        serverURL: String,
        authToken: String,
        partKey: String?,
        ratingKey: String
    ) -> URL? {
        // Use the part key if available, otherwise construct from rating key
        let path = partKey ?? "/library/parts/\(ratingKey)/file"

        guard var components = URLComponents(string: "\(serverURL)\(path)") else {
            return nil
        }

        // Preserve existing query items (e.g., IVA trailer quality params like fmt=4&bitrate=5000)
        var existingItems = components.queryItems ?? []
        existingItems.append(contentsOf: [
            URLQueryItem(name: "X-Plex-Token", value: authToken),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
            URLQueryItem(name: "X-Plex-Platform", value: PlexAPI.platform),
            URLQueryItem(name: "X-Plex-Device", value: PlexAPI.deviceName)
        ])
        components.queryItems = existingItems

        return components.url
    }

    /// Build a direct-play URL for Rivulet's raw-file path.
    /// This preserves the original bitstreams and keeps startup work on the client side.
    func buildPlaybackDirectPlayURL(
        serverURL: String,
        authToken: String,
        partKey: String
    ) -> URL? {
        guard var components = URLComponents(string: "\(serverURL)\(partKey)") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: authToken),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
            URLQueryItem(name: "X-Plex-Platform", value: PlexAPI.platform),
            URLQueryItem(name: "X-Plex-Device", value: PlexAPI.deviceName),
            URLQueryItem(name: "X-Plex-Product", value: PlexAPI.productName)
        ]

        return components.url
    }
    
    /// Direct stream - remux container only, copy video stream
    /// Only transcodes audio if incompatible (like DTS → AAC)
    /// Video is passed through unchanged (no re-encoding)
    /// - Parameter isAudio: If true, uses the music transcode endpoint instead of video
    func buildDirectStreamURL(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        offsetMs: Int = 0,
        isAudio: Bool = false
    ) -> URL? {
        // Use appropriate endpoint for video vs audio
        let endpoint = isAudio ? "/music/:/transcode/universal/start.m3u8" : "/video/:/transcode/universal/start.m3u8"
        guard var components = URLComponents(string: "\(serverURL)\(endpoint)") else {
            return nil
        }

        let sessionId = UUID().uuidString

        if isAudio {
            // Audio-specific client profile
            let audioProfile = [
                "add-direct-stream-profile(type=musicProfile&audioCodec=mp3&container=mp3)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=flac&container=flac)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=aac&container=mp4)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=alac&container=mp4)",
                "add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mpegts&audioCodec=aac)",
            ].joined(separator: "+")

            components.queryItems = [
                // Authentication
                URLQueryItem(name: "X-Plex-Token", value: authToken),
                URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
                URLQueryItem(name: "X-Plex-Platform", value: PlexAPI.platform),
                URLQueryItem(name: "X-Plex-Device", value: PlexAPI.deviceName),
                URLQueryItem(name: "X-Plex-Product", value: PlexAPI.productName),

                // Audio client profile
                URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: audioProfile),

                // Media reference
                URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
                URLQueryItem(name: "mediaIndex", value: "0"),
                URLQueryItem(name: "partIndex", value: "0"),
                URLQueryItem(name: "offset", value: "\(offsetMs / 1000)"),

                // Audio streaming settings
                URLQueryItem(name: "protocol", value: "hls"),
                URLQueryItem(name: "directPlay", value: "0"),
                URLQueryItem(name: "directStream", value: "1"),
                URLQueryItem(name: "directStreamAudio", value: "1"),

                // Audio codec preferences
                URLQueryItem(name: "audioCodec", value: "aac,mp3,flac,alac"),
                URLQueryItem(name: "audioBitrate", value: "320"),
                URLQueryItem(name: "audioChannels", value: "2"),

                // Context
                URLQueryItem(name: "context", value: "streaming"),
                URLQueryItem(name: "location", value: "lan"),
                URLQueryItem(name: "session", value: sessionId),
                URLQueryItem(name: "hasMDE", value: "1")
            ]

        } else {
            // Video client profile (original code)
            let clientProfile = [
                "add-direct-stream-profile(type=videoProfile&videoCodec=h264&container=mp4)",
                "add-direct-stream-profile(type=videoProfile&videoCodec=h264&container=mpegts)",
                "add-direct-stream-profile(type=videoProfile&videoCodec=hevc&container=mp4)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=aac&container=mp4)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=ac3&container=mp4)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=eac3&container=mp4)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=aac&container=mpegts)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=ac3&container=mpegts)",
                "add-direct-stream-profile(type=musicProfile&audioCodec=eac3&container=mpegts)",
                "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&videoCodec=h264&audioCodec=aac,ac3,eac3)",
                "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&videoCodec=hevc&audioCodec=aac,ac3,eac3)",
                "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mpegts&videoCodec=h264&audioCodec=aac,ac3,eac3)",
            ].joined(separator: "+")

            components.queryItems = [
                // Authentication
                URLQueryItem(name: "X-Plex-Token", value: authToken),
                URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
                URLQueryItem(name: "X-Plex-Platform", value: PlexAPI.platform),
                URLQueryItem(name: "X-Plex-Device", value: PlexAPI.deviceName),
                URLQueryItem(name: "X-Plex-Product", value: PlexAPI.productName),

                // CRITICAL: Client profile tells Plex what we support for direct streaming
                URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: clientProfile),

                // Media reference
                URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
                URLQueryItem(name: "mediaIndex", value: "0"),
                URLQueryItem(name: "partIndex", value: "0"),
                URLQueryItem(name: "offset", value: "\(offsetMs / 1000)"),

                // CRITICAL: Direct stream settings for video passthrough
                URLQueryItem(name: "protocol", value: "hls"),
                URLQueryItem(name: "container", value: "mp4"),
                URLQueryItem(name: "segmentFormat", value: "mp4"),
                URLQueryItem(name: "directPlay", value: "0"),
                URLQueryItem(name: "directStream", value: "1"),
                URLQueryItem(name: "directStreamAudio", value: "1"),
                URLQueryItem(name: "fastSeek", value: "1"),

                // Video settings
                URLQueryItem(name: "videoCodec", value: "h264,hevc"),
                URLQueryItem(name: "videoQuality", value: "100"),
                URLQueryItem(name: "videoResolution", value: "4096x2160"),
                URLQueryItem(name: "maxVideoBitrate", value: "200000"),

                // Audio
                URLQueryItem(name: "audioCodec", value: "aac,ac3,eac3"),
                URLQueryItem(name: "audioBitrate", value: "640"),
                URLQueryItem(name: "audioChannels", value: "8"),

                // Subtitles
                URLQueryItem(name: "subtitles", value: "auto"),
                URLQueryItem(name: "subtitleSize", value: "100"),

                // Context
                URLQueryItem(name: "context", value: "streaming"),
                URLQueryItem(name: "location", value: "lan"),
                URLQueryItem(name: "session", value: sessionId),
                URLQueryItem(name: "autoAdjustQuality", value: "0"),
                URLQueryItem(name: "hasMDE", value: "1")
            ]

        }

        return components.url
    }

    /// HLS transcode - full transcode to H.264/AAC HLS stream
    /// Use as fallback when direct play/stream fails
    /// - Parameter isAudio: If true, uses the music transcode endpoint instead of video
    func buildHLSTranscodeURL(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        offsetMs: Int = 0,
        isAudio: Bool = false
    ) -> URL? {
        // Use appropriate endpoint for video vs audio
        let endpoint = isAudio ? "/music/:/transcode/universal/start.m3u8" : "/video/:/transcode/universal/start.m3u8"
        guard var components = URLComponents(string: "\(serverURL)\(endpoint)") else {
            return nil
        }

        let sessionId = UUID().uuidString

        components.queryItems = [
            // Authentication
            URLQueryItem(name: "X-Plex-Token", value: authToken),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
            URLQueryItem(name: "X-Plex-Platform", value: PlexAPI.platform),
            URLQueryItem(name: "X-Plex-Device", value: PlexAPI.deviceName),
            URLQueryItem(name: "X-Plex-Product", value: PlexAPI.productName),

            // Media reference
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "offset", value: "\(offsetMs / 1000)"),

            // Force transcode to H264/AAC for maximum compatibility
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "0"),
            URLQueryItem(name: "directStreamAudio", value: "0"),

            // Video settings - H264 high profile
            URLQueryItem(name: "videoCodec", value: "h264"),
            URLQueryItem(name: "videoResolution", value: "1920x1080"),
            URLQueryItem(name: "maxVideoBitrate", value: "20000"),
            URLQueryItem(name: "videoQuality", value: "100"),
            URLQueryItem(name: "h264Level", value: "42"),
            URLQueryItem(name: "h264Profile", value: "high"),

            // Audio settings - AAC 5.1
            URLQueryItem(name: "audioCodec", value: "aac"),
            URLQueryItem(name: "audioBitrate", value: "384"),
            URLQueryItem(name: "audioChannels", value: "6"),
            URLQueryItem(name: "audioBoost", value: "100"),

            // Disable subtitles to simplify transcode
            URLQueryItem(name: "subtitles", value: "none"),
            URLQueryItem(name: "subtitleSize", value: "100"),
            URLQueryItem(name: "addDebugOverlay", value: "0"),

            // Context
            URLQueryItem(name: "context", value: "streaming"),
            URLQueryItem(name: "location", value: "lan"),

            // Session
            URLQueryItem(name: "session", value: sessionId),
            
            // Additional params for stability
            URLQueryItem(name: "autoAdjustQuality", value: "0"),
            URLQueryItem(name: "hasMDE", value: "1")
        ]

        return components.url
    }

    /// Build an HLS playback URL with direct stream (remux only, no transcoding)
    /// This preserves video/audio codecs including Dolby Vision while providing HLS format
    /// Returns both the URL and required HTTP headers (Plex HLS requires auth in headers, not query params)
    /// - Parameter hasHDR: Whether content has HDR (HDR10/HDR10+/HLG/DV) - adds useDoviCodecs=1 for proper TV mode switching
    /// - Parameter useDolbyVision: Whether to include DV enhancement layers (useDoviCodecs=1). Set to false to get HDR10 base layer only.
    /// - Parameter forceVideoTranscode: Force video transcoding (not just remux) to get Apple-compatible codec tags. Required for MKV+DV.
    /// - Parameter allowAudioDirectStream: Allow server to pass-through audio (AAC/AC3/EAC3). False forces AAC transcode for DTS/TrueHD safety.
    func buildHLSDirectPlayURL(
        serverURL: String,
        authToken: String,
        ratingKey: String,
        offsetMs: Int = 0,
        hasHDR: Bool = false,
        useDolbyVision: Bool = true,
        forceVideoTranscode: Bool = false,
        allowAudioDirectStream: Bool = true
    ) -> (url: URL, headers: [String: String])? {
        // Request an HLS remux that keeps the HEVC/Dolby Vision bitstream intact
        // tvOS requires fMP4/CMAF segments for Dolby Vision profiles 5/8
        let endpoint = "/video/:/transcode/universal/start.m3u8"
        guard var components = URLComponents(string: "\(serverURL)\(endpoint)") else {
            return nil
        }

        let sessionId = UUID().uuidString

         // Match official Plex tvOS behavior for DV by using the "Plex Apple TV" profile name.
         // Stick with "Generic" for non-DV to keep our custom extra profile.
         let clientProfileName = useDolbyVision ? "Plex Apple TV" : "Generic"

        // Match the official Plex tvOS profile so the server returns Apple decoder-friendly streams.
        // Keep our explicit limitations (dvhe/hev1 remap) to ensure compatible codec tags.
        let clientProfile = [
            // Direct play profiles - tells the server what formats we can preserve in the HLS remux path
            "add-direct-play-profile(type=videoProfile&protocol=http&container=mp4,mov&videoCodec=h264,mpeg4,hevc&audioCodec=aac,ac3,eac3&subtitleCodec=mov_text,tx3g,ttxt,text,webvtt)",
            "add-direct-play-profile(type=musicProfile&protocol=http&container=flac&audioCodec=flac)",
            "add-direct-play-profile(type=musicProfile&protocol=http&container=mp4&audioCodec=alac)",

            // Transcode targets - tells server how to transcode incompatible content
            // IMPORTANT: exclude flac here so Plex transcodes audio to AAC/AC3/EAC3 for DV HLS
            // segmentContainer=mp4 forces CMAF/fMP4 segments instead of TS (required for DV on tvOS)
            "add-transcode-target(type=videoProfile&context=streaming&protocol=hls&container=mp4&segmentContainer=mp4&videoCodec=h264,hevc&audioCodec=aac,ac3,eac3&replace=true)",
            "add-transcode-target(type=subtitleProfile&context=streaming&protocol=hls&container=webvtt&subtitleCodec=webvtt)",
            "add-transcode-target(type=musicProfile&context=streaming&protocol=hls&container=mpegts&audioCodec=aac)",

            // Limitations - tells server about codec/format restrictions
            "add-limitation(scope=videoAudioCodec&scopeName=*&type=upperBound&name=audio.channels&value=8&replace=true)",
            // Block dvhe/hev1 for direct play only - forces server to remux to dvh1/hvc1 for HLS
            // With onlyDirectPlay=true: Server remuxes dvhe→dvh1 (preserves DV)
            // Without it: Server may transcode HEVC→H.264 (loses DV)
            "add-limitation(scope=videoCodec&scopeName=*&type=notMatch&name=video.codecID&value=dvhe&onlyDirectPlay=true)",
            "add-limitation(scope=videoCodec&scopeName=*&type=notMatch&name=video.codecID&value=hev1&onlyDirectPlay=true)",
            "add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.width&value=4096&replace=true)",
            "add-limitation(scope=videoCodec&scopeName=*&type=upperBound&name=video.height&value=2160&replace=true)"
        ].joined(separator: "+")

        // Plex HLS requires auth in HTTP headers, not query params
        // Without these headers, endpoint returns 400 Bad Request
        var headers = plexHeaders(authToken: authToken)
        headers["X-Plex-Client-Profile-Extra"] = clientProfile
        headers["X-Plex-Client-Profile-Name"] = clientProfileName

        // URL query params (no auth here - must be in headers)
        var items: [URLQueryItem] = [
            URLQueryItem(name: "X-Plex-Client-Profile-Name", value: clientProfileName),
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "offset", value: "\(offsetMs / 1000)"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "container", value: "mp4"),
            URLQueryItem(name: "segmentFormat", value: "mp4"),
            URLQueryItem(name: "segmentContainer", value: "mp4"),  // Force CMAF/fMP4 segments (required for DV on tvOS)
            // directPlay=1 tells server we CAN direct play mp4/mov - without this, server may transcode instead of remux
            URLQueryItem(name: "directPlay", value: "1"),
            // For MKV+DV, we must force video transcoding (not just remux) to get Apple-compatible codec tags (dvh1/hvc1)
            // MKV files typically use dvhe/hev1 which the tvOS decoder path does not accept here
            URLQueryItem(name: "directStream", value: forceVideoTranscode ? "0" : "1"),
            // directStreamAudio controls whether Plex passes through compatible audio or transcodes it
            // When allowAudioDirectStream=false (e.g., AirPlay/HomePod with multichannel AAC), force transcode
            // HomePod supports Dolby Digital surround (EAC3/AC3) but NOT multichannel AAC
            // Note: segmentContainer=mp4 ensures fMP4 segments regardless of this setting
            URLQueryItem(name: "directStreamAudio", value: allowAudioDirectStream ? "1" : "0"),
            URLQueryItem(name: "fastSeek", value: "1"),
            URLQueryItem(name: "videoCodec", value: "h264,hevc"),
            URLQueryItem(name: "videoResolution", value: "4096x2160"),
            URLQueryItem(name: "videoQuality", value: "100"),
            URLQueryItem(name: "segmentDuration", value: "6"),
            // EAC3 preferred for surround (HomePod compatible), AAC for stereo fallback
            URLQueryItem(name: "audioCodec", value: allowAudioDirectStream ? "aac,eac3,ac3" : "eac3,ac3,aac"),
            URLQueryItem(name: "audioBitrate", value: "1024"),
            URLQueryItem(name: "audioChannels", value: "8"),
            URLQueryItem(name: "subtitles", value: "auto"),
            URLQueryItem(name: "subtitleSize", value: "100"),
            URLQueryItem(name: "context", value: "streaming"),
            URLQueryItem(name: "location", value: "lan"),
            URLQueryItem(name: "session", value: sessionId),
            URLQueryItem(name: "autoAdjustQuality", value: "0"),
            URLQueryItem(name: "hasMDE", value: "1"),
            // Keyframe playlist improves seeking accuracy in HLS streams
            URLQueryItem(name: "includeKeyframePlaylist", value: "1")
        ]

        items.append(URLQueryItem(name: "X-Plex-Client-Profile-Extra", value: clientProfile))

        components.queryItems = items

        // Add HDR-related parameters for proper DV remuxing and codec signaling.
        // useDoviCodecs=1 ensures Plex preserves Dolby Vision metadata in the HLS output.
        if hasHDR && useDolbyVision {
            components.queryItems?.append(URLQueryItem(name: "useDoviCodecs", value: "1"))
            components.queryItems?.append(URLQueryItem(name: "includeCodecs", value: "1"))
        }

        print("[Plex HLS] Using \(clientProfileName) profile for \(useDolbyVision ? "Dolby Vision" : "HDR/SDR") (session: \(sessionId))")

        guard let url = components.url else { return nil }
        return (url, headers)
    }

    /// Set the preferred audio stream on a media part.
    /// Plex reads this preference when starting a new transcode session.
    /// Must be called BEFORE starting the transcode for the selection to take effect.
    func setSelectedAudioStream(
        serverURL: String,
        authToken: String,
        partId: Int,
        audioStreamID: Int
    ) async {
        guard var components = URLComponents(string: "\(serverURL)/library/parts/\(partId)") else {
            print("[Plex] Failed to build audio stream selection URL")
            return
        }
        components.queryItems = [
            URLQueryItem(name: "audioStreamID", value: "\(audioStreamID)"),
            URLQueryItem(name: "X-Plex-Token", value: authToken)
        ]
        guard let url = components.url else {
            print("[Plex] Failed to build audio stream selection URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[Plex] Set audio stream \(audioStreamID) on part \(partId): HTTP \(status)")
        } catch {
            print("[Plex] Failed to set audio stream: \(error.localizedDescription)")
        }
    }

    /// Set the preferred subtitle stream on a media part. Pass `0` for
    /// `subtitleStreamID` to disable subtitles. Plex persists this
    /// per-user-per-part, so it survives across plays from any client.
    func setSelectedSubtitleStream(
        serverURL: String,
        authToken: String,
        partId: Int,
        subtitleStreamID: Int
    ) async {
        guard var components = URLComponents(string: "\(serverURL)/library/parts/\(partId)") else {
            print("[Plex] Failed to build subtitle stream selection URL")
            return
        }
        components.queryItems = [
            URLQueryItem(name: "subtitleStreamID", value: "\(subtitleStreamID)"),
            URLQueryItem(name: "X-Plex-Token", value: authToken)
        ]
        guard let url = components.url else {
            print("[Plex] Failed to build subtitle stream selection URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[Plex] Set subtitle stream \(subtitleStreamID) on part \(partId): HTTP \(status)")
        } catch {
            print("[Plex] Failed to set subtitle stream: \(error.localizedDescription)")
        }
    }

    /// Ping the `/decision` endpoint to tell Plex to actually start the transcode/remux session.
    /// Without this, Plex may return a playlist with segment URLs but never begin muxing,
    /// causing the init segment (`/base/header`) to hang indefinitely.
    /// Takes the `start.m3u8` URL and swaps the path to `/decision`.
    func startTranscodeDecision(hlsURL: URL, headers: [String: String]) async {
        guard var components = URLComponents(url: hlsURL, resolvingAgainstBaseURL: false) else { return }

        // Swap start.m3u8 → decision
        let currentPath = components.path
        components.path = currentPath.replacingOccurrences(
            of: "/video/:/transcode/universal/start.m3u8",
            with: "/video/:/transcode/universal/decision"
        )

        guard let decisionURL = components.url else { return }

        var request = URLRequest(url: decisionURL)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.addValue(value, forHTTPHeaderField: key)
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            print("[Plex] Decision request failed: \(error.localizedDescription)")
        }
    }

    /// Warm up a direct-play URL so the first real playback request sees lower startup latency.
    /// This is best-effort and intentionally silent on failures.
    func warmDirectPlayStream(url: URL, headers: [String: String]) async {
        var headRequest = URLRequest(url: url)
        headRequest.httpMethod = "HEAD"
        headRequest.timeoutInterval = 4
        headRequest.cachePolicy = .reloadIgnoringLocalCacheData
        for (key, value) in headers {
            headRequest.addValue(value, forHTTPHeaderField: key)
        }

        do {
            let (_, response) = try await session.data(for: headRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if (200...399).contains(status) {
                return
            }
            if status != 405 && status != 501 {
                return
            }
        } catch {
            // Fall through to range probe.
        }

        var rangeRequest = URLRequest(url: url)
        rangeRequest.httpMethod = "GET"
        rangeRequest.timeoutInterval = 4
        rangeRequest.cachePolicy = .reloadIgnoringLocalCacheData
        rangeRequest.addValue("bytes=0-1", forHTTPHeaderField: "Range")
        for (key, value) in headers {
            rangeRequest.addValue(value, forHTTPHeaderField: key)
        }

        do {
            let (_, response) = try await session.data(for: rangeRequest)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            // Best effort only.
        }
    }

    /// Stop a Plex transcode session. Call this when stopping playback to free server resources
    /// and prevent timeouts when immediately starting a new session.
    func stopTranscodeSession(serverURL: String, authToken: String, sessionId: String) async {
        let endpoint = "/video/:/transcode/universal/stop"
        guard var components = URLComponents(string: "\(serverURL)\(endpoint)") else { return }
        components.queryItems = [URLQueryItem(name: "session", value: sessionId)]
        guard let url = components.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            // Best-effort — don't block on failure
            print("[Plex] Failed to stop transcode session \(sessionId): \(error.localizedDescription)")
        }
    }

    /// Detect if a server URL is on the local network
    private func isLocalServer(_ serverURL: String) -> Bool {
        guard let url = URL(string: serverURL), let host = url.host else {
            return false
        }

        // Check for private IP ranges
        let localPrefixes = [
            "192.168.", "10.", "172.16.", "172.17.", "172.18.", "172.19.",
            "172.20.", "172.21.", "172.22.", "172.23.", "172.24.", "172.25.",
            "172.26.", "172.27.", "172.28.", "172.29.", "172.30.", "172.31.",
            "127.", "localhost"
        ]

        return localPrefixes.contains(where: { host.hasPrefix($0) }) || host == "localhost"
    }

    /// Get decision info from Plex about what playback method to use
    /// This also initializes the transcode session on the server
    func getPlaybackDecision(
        serverURL: String,
        authToken: String,
        ratingKey: String
    ) async throws -> PlaybackDecision {
        guard var components = URLComponents(string: "\(serverURL)/video/:/transcode/universal/decision") else {
            throw PlexAPIError.invalidURL
        }

        // Use parameters that request HLS with direct play/stream enabled
        components.queryItems = [
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: "0"),
            URLQueryItem(name: "partIndex", value: "0"),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "directPlay", value: "1"),
            URLQueryItem(name: "directStream", value: "1"),
            URLQueryItem(name: "directStreamAudio", value: "1"),
            URLQueryItem(name: "videoCodec", value: "h264,hevc"),
            URLQueryItem(name: "audioCodec", value: "aac,ac3,eac3,dca"),
            URLQueryItem(name: "subtitles", value: "auto"),
            URLQueryItem(name: "hasMDE", value: "1"),
            URLQueryItem(name: "X-Plex-Client-Profile-Name", value: "Generic"),
            URLQueryItem(name: "X-Plex-Token", value: authToken),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
            URLQueryItem(name: "X-Plex-Platform", value: PlexAPI.platform),
            URLQueryItem(name: "X-Plex-Device", value: PlexAPI.deviceName),
            URLQueryItem(name: "X-Plex-Product", value: PlexAPI.productName)
        ]
        
        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }
        
        let container: PlaybackDecisionContainer = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )
        
        return container.MediaContainer
    }

    /// Build thumbnail URL
    func buildThumbnailURL(
        serverURL: String,
        authToken: String,
        thumbPath: String,
        width: Int = 400,
        height: Int = 600
    ) -> URL? {
        guard var components = URLComponents(string: "\(serverURL)/photo/:/transcode") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "url", value: thumbPath),
            URLQueryItem(name: "width", value: "\(width)"),
            URLQueryItem(name: "height", value: "\(height)"),
            URLQueryItem(name: "minSize", value: "1"),
            URLQueryItem(name: "X-Plex-Token", value: authToken)
        ]

        return components.url
    }

    // MARK: - Search

    /// Search library
    func search(
        serverURL: String,
        authToken: String,
        query: String,
        sectionId: String? = nil,
        start: Int = 0,
        size: Int = 60
    ) async throws -> [PlexMetadata] {
        var urlString = "\(serverURL)/search"
        if let section = sectionId {
            urlString = "\(serverURL)/library/sections/\(section)/search"
        }

        guard var components = URLComponents(string: urlString) else {
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "X-Plex-Container-Start", value: "\(start)"),
            URLQueryItem(name: "X-Plex-Container-Size", value: "\(size)")
        ]

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        let container: PlexMediaContainerWrapper = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        return container.MediaContainer.Metadata ?? []
    }

    // MARK: - Live TV

    /// Check if the Plex server supports Live TV
    func getLiveTVCapabilities(
        serverURL: String,
        authToken: String
    ) async throws -> PlexLiveTVCapabilities {
        // Check for DVR/tuner capability by requesting the livetv endpoint
        guard let url = URL(string: "\(serverURL)/livetv/dvrs") else {
            throw PlexAPIError.invalidURL
        }

        do {
            let container: PlexDVRContainer = try await request(
                url,
                headers: plexHeaders(authToken: authToken)
            )

            let dvrs = container.MediaContainer.Dvr ?? []
            let hasDVRs = !dvrs.isEmpty

            // Log capabilities check result (GitHub #64 - DVB diagnostics)
            let breadcrumb = Breadcrumb(level: .info, category: "plex_livetv")
            breadcrumb.message = "Live TV capabilities check completed"
            breadcrumb.data = [
                "allow_tuners": hasDVRs,
                "live_tv_enabled": hasDVRs,
                "has_dvr": hasDVRs,
                "dvr_count": dvrs.count,
                "dvr_types": dvrs.compactMap { $0.make ?? $0.model }.joined(separator: ", "),
                "server_host": URL(string: serverURL)?.host ?? "unknown"
            ]
            SentrySDK.addBreadcrumb(breadcrumb)

            return PlexLiveTVCapabilities(
                allowTuners: hasDVRs,
                liveTVEnabled: hasDVRs,
                hasDVR: hasDVRs
            )
        } catch {
            // Log capability check failure (GitHub #64 - DVB diagnostics)
            let breadcrumb = Breadcrumb(level: .warning, category: "plex_livetv")
            breadcrumb.message = "Live TV capabilities check failed"
            breadcrumb.data = [
                "error": error.localizedDescription,
                "server_host": URL(string: serverURL)?.host ?? "unknown"
            ]
            SentrySDK.addBreadcrumb(breadcrumb)

            // If the endpoint fails, Live TV is not available
            return PlexLiveTVCapabilities()
        }
    }

    /// Get all Live TV channels
    func getLiveTVChannels(
        serverURL: String,
        authToken: String
    ) async throws -> [PlexLiveTVChannel] {
        // The grid endpoint returns ALL channels with their info
        return try await fetchChannelsFromGrid(serverURL: serverURL, authToken: authToken)
    }

    /// Fetch channels from grid endpoint using DVR lineup
    /// The grid returns programs with channel info embedded in each program's Media array
    private func fetchChannelsFromGrid(
        serverURL: String,
        authToken: String
    ) async throws -> [PlexLiveTVChannel] {
        guard let dvrsURL = URL(string: "\(serverURL)/livetv/dvrs") else {
            throw PlexAPIError.invalidURL
        }

        let dvrContainer: PlexDVRContainer = try await request(
            dvrsURL,
            headers: plexHeaders(authToken: authToken)
        )

        guard let dvr = dvrContainer.MediaContainer.Dvr?.first,
              let lineup = dvr.lineup,
              let dvrKey = dvr.key else {
            print("🌐 PlexNetwork: No DVR or lineup found for Live TV")
            // Log missing DVR/lineup (GitHub #64 - DVB diagnostics)
            let breadcrumb = Breadcrumb(level: .warning, category: "plex_livetv")
            breadcrumb.message = "No DVR or lineup found for Live TV channels"
            breadcrumb.data = [
                "server_host": URL(string: serverURL)?.host ?? "unknown",
                "has_dvr_array": dvrContainer.MediaContainer.Dvr != nil,
                "dvr_count": dvrContainer.MediaContainer.Dvr?.count ?? 0
            ]
            SentrySDK.addBreadcrumb(breadcrumb)
            return []
        }

        // Get HDHomeRun device URI for stream URLs
        var hdhrStreamURLs: [String: String] = [:]
        let hasHDHomeRunDevice = dvr.Device?.first?.uri != nil
        if let device = dvr.Device?.first, let deviceURI = device.uri {
            // Log HDHomeRun device discovery (GitHub #64 - DVB diagnostics)
            let hdhrBreadcrumb = Breadcrumb(level: .info, category: "plex_livetv")
            hdhrBreadcrumb.message = "Fetching HDHomeRun stream URLs"
            hdhrBreadcrumb.data = [
                "device_uri_host": URL(string: deviceURI)?.host ?? "unknown",
                "dvr_make": dvr.make ?? "unknown",
                "dvr_model": dvr.model ?? "unknown"
            ]
            SentrySDK.addBreadcrumb(hdhrBreadcrumb)

            hdhrStreamURLs = await fetchHDHomeRunLineup(deviceURI: deviceURI)
        } else {
            // No HDHomeRun device - likely a DVB tuner (GitHub #64)
            let dvbBreadcrumb = Breadcrumb(level: .info, category: "plex_livetv")
            dvbBreadcrumb.message = "No HDHomeRun device found - will use Plex transcode URLs"
            dvbBreadcrumb.data = [
                "dvr_make": dvr.make ?? "unknown",
                "dvr_model": dvr.model ?? "unknown",
                "dvr_friendly_name": dvr.friendlyName ?? "unknown",
                "has_device_array": dvr.Device != nil,
                "device_count": dvr.Device?.count ?? 0
            ]
            SentrySDK.addBreadcrumb(dvbBreadcrumb)
        }

        // Extract provider path using DVR key (e.g., tv.plex.providers.epg.xmltv:28)
        let providerPath = extractProviderPath(from: lineup, dvrKey: dvrKey)

        // Grid requires time parameters to return data
        let now = Int(Date().timeIntervalSince1970)
        let sixHoursLater = now + (6 * 3600)

        guard var components = URLComponents(string: "\(serverURL)/\(providerPath)/grid") else {
            print("🌐 PlexNetwork: Could not build grid URL from lineup: \(lineup)")
            throw PlexAPIError.invalidURL
        }

        components.queryItems = [
            URLQueryItem(name: "type", value: "1,4"),
            URLQueryItem(name: "sort", value: "beginsAt"),
            URLQueryItem(name: "beginsAt<=", value: "\(sixHoursLater)"),
            URLQueryItem(name: "endsAt>=", value: "\(now)")
        ]

        guard let gridURL = components.url else {
            throw PlexAPIError.invalidURL
        }

        // The grid returns programs with channel info in each program's Media array
        struct GridContainer: Codable {
            let MediaContainer: GridMediaContainer
        }
        struct GridMediaContainer: Codable {
            let size: Int?
            let Metadata: [GridProgram]?
        }
        struct GridProgram: Codable {
            let ratingKey: String?
            let key: String?
            let Media: [GridMedia]?
        }
        struct GridMedia: Codable {
            let channelCallSign: String?
            let channelIdentifier: String?
            let channelThumb: String?
            let channelTitle: String?
            let channelVcn: String?  // Visual channel number
        }

        let container: GridContainer = try await request(
            gridURL,
            headers: plexHeaders(authToken: authToken)
        )

        // Extract unique channels from all programs' Media arrays
        var seenChannels = Set<String>()
        var channels: [PlexLiveTVChannel] = []

        for program in container.MediaContainer.Metadata ?? [] {
            for media in program.Media ?? [] {
                guard let channelId = media.channelIdentifier,
                      !seenChannels.contains(channelId) else {
                    continue
                }

                seenChannels.insert(channelId)

                let channelTitle = media.channelTitle ?? "Channel \(channelId)"
                let channelNumber = media.channelVcn ?? channelId

                // Get stream URL from HDHomeRun lineup (keyed by channel number)
                let streamURL = hdhrStreamURLs[channelNumber] ?? hdhrStreamURLs[channelId]

                let channel = PlexLiveTVChannel(
                    ratingKey: channelId,
                    key: "/tv.plex.providers.epg.xmltv:\(dvrKey)/metadata/\(channelId)",
                    guid: nil,
                    type: "channel",
                    title: channelTitle,
                    summary: nil,
                    thumb: media.channelThumb,
                    art: nil,
                    year: nil,
                    channelCallSign: media.channelCallSign,
                    channelIdentifier: channelId,
                    channelShortTitle: nil,
                    channelThumb: media.channelThumb,
                    channelTitle: channelTitle,
                    channelNumber: channelNumber,
                    streamURL: streamURL
                )

                channels.append(channel)
            }
        }

        // Log channel breakdown for DVB debugging (GitHub #64)
        let channelsWithStreamURL = channels.filter { $0.streamURL != nil }.count
        let channelsNeedingTranscode = channels.count - channelsWithStreamURL
        let summaryBreadcrumb = Breadcrumb(level: .info, category: "plex_livetv")
        summaryBreadcrumb.message = "Live TV channel fetch completed"
        summaryBreadcrumb.data = [
            "total_channels": channels.count,
            "channels_with_hdhr_url": channelsWithStreamURL,
            "channels_needing_transcode": channelsNeedingTranscode,
            "has_hdhr_device": hasHDHomeRunDevice,
            "server_host": URL(string: serverURL)?.host ?? "unknown"
        ]
        SentrySDK.addBreadcrumb(summaryBreadcrumb)

        return channels
    }

    /// Fetch stream URLs from HDHomeRun device lineup
    /// Returns a dictionary mapping channel number to stream URL
    private func fetchHDHomeRunLineup(deviceURI: String) async -> [String: String] {
        guard let lineupURL = URL(string: "\(deviceURI)/lineup.json") else {
            print("🌐 PlexNetwork: Invalid HDHomeRun lineup URL")
            return [:]
        }

        struct HDHomeRunChannel: Codable {
            let GuideNumber: String?
            let GuideName: String?
            let URL: String?
        }

        do {
            let (data, response) = try await session.data(from: lineupURL)

            // Validate HTTP response before attempting JSON decode
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                print("🌐 PlexNetwork: HDHomeRun lineup returned HTTP \(httpResponse.statusCode)")
                return [:]
            }

            let channels = try JSONDecoder().decode([HDHomeRunChannel].self, from: data)

            var urlMap: [String: String] = [:]
            for channel in channels {
                if let number = channel.GuideNumber, let url = channel.URL {
                    urlMap[number] = url
                }
            }

            // Log HDHomeRun lineup success (GitHub #64 - DVB diagnostics)
            let breadcrumb = Breadcrumb(level: .info, category: "plex_livetv")
            breadcrumb.message = "HDHomeRun lineup fetched successfully"
            breadcrumb.data = [
                "device_host": lineupURL.host ?? "unknown",
                "total_channels": channels.count,
                "channels_with_urls": urlMap.count
            ]
            SentrySDK.addBreadcrumb(breadcrumb)

            return urlMap
        } catch {
            print("🌐 PlexNetwork: Failed to fetch HDHomeRun lineup: \(error)")

            // Log HDHomeRun lineup failure (GitHub #64 - DVB diagnostics)
            let breadcrumb = Breadcrumb(level: .error, category: "plex_livetv")
            breadcrumb.message = "HDHomeRun lineup fetch failed"
            breadcrumb.data = [
                "device_host": lineupURL.host ?? "unknown",
                "error": error.localizedDescription
            ]
            SentrySDK.addBreadcrumb(breadcrumb)

            // Capture error event for HDHomeRun failures
            SentrySDK.capture(error: error) { scope in
                scope.setTag(value: "plex_livetv", key: "component")
                scope.setTag(value: "hdhr_lineup_fetch", key: "operation")
                scope.setExtra(value: lineupURL.host ?? "unknown", key: "device_host")
            }

            return [:]
        }
    }

    /// Extract provider path from DVR key and lineup URL for EPG access
    /// The correct format is: tv.plex.providers.epg.xmltv:{dvrKey}
    private func extractProviderPath(from lineup: String, dvrKey: String) -> String {
        // Extract the provider identifier from the lineup URL
        // lineup://tv.plex.providers.epg.xmltv/... -> tv.plex.providers.epg.xmltv
        var providerIdentifier = lineup
        if providerIdentifier.hasPrefix("lineup://") {
            providerIdentifier = String(providerIdentifier.dropFirst("lineup://".count))
        }
        // Take just the first part before any / or #
        if let slashIndex = providerIdentifier.firstIndex(of: "/") {
            providerIdentifier = String(providerIdentifier[..<slashIndex])
        }
        if let hashIndex = providerIdentifier.firstIndex(of: "#") {
            providerIdentifier = String(providerIdentifier[..<hashIndex])
        }

        // Build the provider path using the DVR key
        // Format: tv.plex.providers.epg.xmltv:28
        return "\(providerIdentifier):\(dvrKey)"
    }

    /// Get Live TV guide (EPG) for specified channels and time range
    func getLiveTVGuide(
        serverURL: String,
        authToken: String,
        channelIds: [String]? = nil,
        startTime: Date,
        endTime: Date
    ) async throws -> [PlexLiveTVGuideChannel] {
        // Get the DVR lineup to build the grid URL
        guard let dvrsURL = URL(string: "\(serverURL)/livetv/dvrs") else {
            throw PlexAPIError.invalidURL
        }

        let dvrContainer: PlexDVRContainer = try await request(
            dvrsURL,
            headers: plexHeaders(authToken: authToken)
        )

        guard let dvr = dvrContainer.MediaContainer.Dvr?.first,
              let lineup = dvr.lineup,
              let dvrKey = dvr.key else {
            print("🌐 PlexNetwork: No DVR or lineup found for Live TV guide")
            return []
        }

        // Extract provider path using DVR key (e.g., tv.plex.providers.epg.xmltv:28)
        let providerPath = extractProviderPath(from: lineup, dvrKey: dvrKey)

        guard var components = URLComponents(string: "\(serverURL)/\(providerPath)/grid") else {
            throw PlexAPIError.invalidURL
        }

        let startTimestamp = Int(startTime.timeIntervalSince1970)
        let endTimestamp = Int(endTime.timeIntervalSince1970)

        var queryItems = [
            URLQueryItem(name: "type", value: "1,4"),  // 1=movies, 4=shows
            URLQueryItem(name: "sort", value: "beginsAt"),
            URLQueryItem(name: "beginsAt<=", value: "\(endTimestamp)"),
            URLQueryItem(name: "endsAt>=", value: "\(startTimestamp)")
        ]

        if let ids = channelIds, !ids.isEmpty {
            queryItems.append(URLQueryItem(name: "channelId", value: ids.joined(separator: ",")))
        }

        components.queryItems = queryItems

        guard let url = components.url else {
            throw PlexAPIError.invalidURL
        }

        // The grid returns flat programs with channel info in each program's Media array
        // We need to parse this and group by channel
        struct GridEPGContainer: Codable {
            let MediaContainer: GridEPGMediaContainer
        }
        struct GridEPGMediaContainer: Codable {
            let size: Int?
            let Metadata: [GridEPGProgram]?
        }
        struct GridEPGProgram: Codable {
            let ratingKey: String?
            let key: String?
            let guid: String?
            let type: String?
            let title: String?
            let grandparentTitle: String?
            let parentTitle: String?
            let summary: String?
            let thumb: String?
            let art: String?
            let year: Int?
            let originallyAvailableAt: String?
            let Media: [GridEPGMedia]?
        }
        struct GridEPGMedia: Codable {
            let channelCallSign: String?
            let channelIdentifier: String?
            let channelThumb: String?
            let channelTitle: String?
            let channelVcn: String?
            let beginsAt: Int?
            let endsAt: Int?
        }

        let container: GridEPGContainer = try await request(
            url,
            headers: plexHeaders(authToken: authToken)
        )

        let programs = container.MediaContainer.Metadata ?? []

        // Group programs by channel and convert to PlexLiveTVGuideChannel format
        // Each program can have multiple Media entries representing different time slots
        var channelPrograms: [String: (channel: GridEPGMedia, programs: [PlexLiveTVProgram])] = [:]

        for program in programs {
            guard let mediaList = program.Media, !mediaList.isEmpty else {
                continue
            }

            // Iterate over ALL Media entries - each represents a time slot
            for media in mediaList {
                guard let channelId = media.channelIdentifier else {
                    continue
                }

                // Convert to PlexLiveTVProgram for this time slot
                let liveTVProgram = PlexLiveTVProgram(
                    ratingKey: program.ratingKey,
                    key: program.key,
                    guid: program.guid,
                    type: program.type,
                    title: program.title ?? "Unknown",
                    grandparentTitle: program.grandparentTitle,
                    parentTitle: program.parentTitle,
                    summary: program.summary,
                    thumb: program.thumb,
                    art: program.art,
                    year: program.year,
                    originallyAvailableAt: program.originallyAvailableAt,
                    beginsAt: media.beginsAt,
                    endsAt: media.endsAt,
                    onAir: nil,
                    live: nil,
                    premiere: nil,
                    Genre: nil,
                    Media: nil
                )

                if channelPrograms[channelId] == nil {
                    channelPrograms[channelId] = (channel: media, programs: [])
                }
                channelPrograms[channelId]?.programs.append(liveTVProgram)
            }
        }

        // Convert to PlexLiveTVGuideChannel array
        let guideChannels = channelPrograms.map { (channelId, data) -> PlexLiveTVGuideChannel in
            PlexLiveTVGuideChannel(
                ratingKey: channelId,
                key: nil,
                guid: nil,
                channelIdentifier: channelId,
                channelTitle: data.channel.channelTitle,
                channelNumber: data.channel.channelVcn,
                channelThumb: data.channel.channelThumb,
                Metadata: data.programs
            )
        }

        return guideChannels
    }

    /// Build Live TV stream URL for a channel
    func buildLiveTVStreamURL(
        serverURL: String,
        authToken: String,
        channelKey: String
    ) -> URL? {
        guard var components = URLComponents(string: "\(serverURL)\(channelKey)") else {
            return nil
        }

        components.queryItems = [
            URLQueryItem(name: "X-Plex-Token", value: authToken),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: PlexAPI.clientIdentifier),
            URLQueryItem(name: "X-Plex-Platform", value: PlexAPI.platform),
            URLQueryItem(name: "X-Plex-Device", value: PlexAPI.deviceName),
            URLQueryItem(name: "X-Plex-Product", value: PlexAPI.productName)
        ]

        return components.url
    }

    // MARK: - Helper Methods

    /// Generate standard Plex API headers
    /// - Parameters:
    ///   - authToken: The authentication token
    ///   - userId: Optional user ID for Plex Home profile switching (X-Plex-User-Id header)
    func plexHeaders(authToken: String, userId: Int? = nil) -> [String: String] {
        var headers = [
            "X-Plex-Token": authToken,
            "X-Plex-Client-Identifier": PlexAPI.clientIdentifier,
            "X-Plex-Product": PlexAPI.productName,
            "X-Plex-Platform": PlexAPI.platform,
            "X-Plex-Device": PlexAPI.deviceName
        ]

        // Add user context header for Plex Home profile switching
        if let userId = userId {
            headers["X-Plex-User-Id"] = String(userId)
        }

        return headers
    }

    // MARK: - Plex Home Users

    /// Get all users in the Plex Home (managed profiles)
    /// GET https://plex.tv/api/home/users (XML) or /api/v2/home/users (JSON)
    func getHomeUsers(authToken: String) async throws -> [PlexHomeUser] {
        // Try the v2 JSON endpoint first
        let v2URL = URL(string: "\(PlexAPI.baseUrl)/api/v2/home/users")!

        var headers = plexHeaders(authToken: authToken)
        headers["Accept"] = "application/json"

        do {
            let data = try await requestData(v2URL, headers: headers)

            let decoder = JSONDecoder()

            // Try wrapped format: {"users": [...]} or {"home": {"users": [...]}}
            if let response = try? decoder.decode(PlexHomeUsersResponse.self, from: data) {
                return response.users
            }

            // Try home wrapper: {"home": {..., "users": [...]}}
            if let homeWrapper = try? decoder.decode(PlexHomeWrapper.self, from: data) {
                return homeWrapper.users
            }

            // Try direct array format: [...]
            if let users = try? decoder.decode([PlexHomeUser].self, from: data) {
                return users
            }

            print("🌐 PlexNetwork: ❌ Could not decode home users JSON response")
        } catch {
            print("🌐 PlexNetwork: v2 endpoint failed: \(error)")
        }

        // Fallback: try the XML endpoint and parse it
        print("🌐 PlexNetwork: Trying XML endpoint...")
        let xmlURL = URL(string: "\(PlexAPI.baseUrl)/api/home/users")!

        let xmlData = try await requestData(xmlURL, headers: plexHeaders(authToken: authToken))

        if let xmlString = String(data: xmlData, encoding: .utf8) {
            let users = parseHomeUsersXML(xmlString)
            return users
        }

        throw PlexAPIError.parsingError
    }

    /// Parse home users from XML response
    /// Format: <home ...><users><user id="..." title="..." .../></users></home>
    private func parseHomeUsersXML(_ xml: String) -> [PlexHomeUser] {
        var users: [PlexHomeUser] = []

        // Simple regex-based XML parsing for <user .../> elements
        let userPattern = "<user\\s+([^>]+)/>"
        guard let regex = try? NSRegularExpression(pattern: userPattern, options: []) else {
            print("🌐 PlexNetwork: Failed to create user regex")
            return users
        }

        let matches = regex.matches(in: xml, range: NSRange(xml.startIndex..., in: xml))

        for match in matches {
            guard let attrRange = Range(match.range(at: 1), in: xml) else { continue }
            let attributes = String(xml[attrRange])

            // Extract a single attribute value by name
            func attr(_ name: String) -> String? {
                let pattern = "\(name)=\"([^\"]*)\""
                guard let attrRegex = try? NSRegularExpression(pattern: pattern),
                      let attrMatch = attrRegex.firstMatch(in: attributes, range: NSRange(attributes.startIndex..., in: attributes)),
                      let valueRange = Range(attrMatch.range(at: 1), in: attributes) else {
                    return nil
                }
                return String(attributes[valueRange])
            }

            guard let idStr = attr("id"), let id = Int(idStr),
                  let uuid = attr("uuid"),
                  let title = attr("title") else {
                continue
            }

            let user = PlexHomeUser(
                id: id,
                uuid: uuid,
                title: title,
                username: attr("username"),
                friendlyName: attr("friendlyName"),
                thumb: attr("thumb"),
                email: attr("email"),
                admin: attr("admin") == "1",
                restricted: attr("restricted") == "1",
                protected: attr("protected") == "1",
                guest: attr("guest") == "1",
                restrictionProfile: attr("restrictionProfile")
            )
            users.append(user)
        }

        return users
    }

    /// Get the access token for a specific server URL using the user's auth token
    /// This is used after switching users to get a server-specific access token
    func getServerAccessToken(authToken: String, serverURL: String) async -> String? {
        do {
            let servers = try await getServers(authToken: authToken)

            // Extract the machine identifier from plex.direct URL if present
            // Format: https://IP.MACHINEID.plex.direct:PORT
            var targetMachineId: String?
            if serverURL.contains(".plex.direct") {
                let components = serverURL.components(separatedBy: ".")
                if components.count >= 3 {
                    // The machine ID is the second-to-last component before "plex.direct"
                    targetMachineId = components[1]
                }
            }

            // Find a server that matches
            for server in servers {

                // Check if machine identifier matches
                if let targetMachineId = targetMachineId,
                   let serverMachineId = server.machineIdentifier,
                   serverMachineId == targetMachineId {
                    if let accessToken = server.accessToken {
                        return accessToken
                    }
                }

                // Also check by clientIdentifier (sometimes used interchangeably)
                if let targetMachineId = targetMachineId,
                   server.clientIdentifier == targetMachineId {
                    if let accessToken = server.accessToken {
                        return accessToken
                    }
                }

                // Check connections - look for matching plex.direct URL or same host
                for connection in server.connections ?? [] {
                    // Direct match
                    if serverURL == connection.uri {
                        if let accessToken = server.accessToken {
                            return accessToken
                        }
                    }

                    // Check if connection URI contains the same plex.direct identifier
                    if let targetMachineId = targetMachineId,
                       connection.uri.contains(targetMachineId) {
                        if let accessToken = server.accessToken {
                            return accessToken
                        }
                    }

                    // Partial match for same server
                    if serverURL.contains(connection.uri) || connection.uri.contains(serverURL) {
                        if let accessToken = server.accessToken {
                            return accessToken
                        }
                    }
                }

                // If we found a server with accessToken (last resort - only 1 server in list)
                if servers.count == 1, let accessToken = server.accessToken {
                    return accessToken
                }
            }

            // Fallback: return the authToken itself (works for server owners)
            print("🌐 PlexNetwork: ⚠️ No server-specific token found, using plex.tv auth token")
            return authToken
        } catch {
            print("🌐 PlexNetwork: ❌ Failed to get server access token: \(error)")
            return authToken
        }
    }

    /// Switch to a home user profile (validates PIN if protected)
    /// POST https://plex.tv/api/v2/home/users/{uuid}/switch
    /// - Returns: The user's auth token if switch succeeded, nil if PIN invalid
    func switchToHomeUser(userUUID: String, pin: String?, authToken: String) async throws -> String? {
        guard let url = URL(string: "\(PlexAPI.baseUrl)/api/v2/home/users/\(userUUID)/switch") else {
            throw PlexAPIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        // Add standard Plex headers
        for (key, value) in plexHeaders(authToken: authToken) {
            request.addValue(value, forHTTPHeaderField: key)
        }

        // Add PIN if provided
        if let pin = pin, !pin.isEmpty {
            request.addValue(pin, forHTTPHeaderField: "X-Plex-Pin")
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlexAPIError.invalidResponse
        }

        // Log response for debugging

        // 200/201 = success, 401 = invalid PIN, 403 = PIN required
        switch httpResponse.statusCode {
        case 200, 201:
            // Parse the user's auth token from response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let userToken = json["authToken"] as? String {
                return userToken
            }
            return authToken // Fall back to original token
        case 401:
            print("🌐 PlexNetwork: ❌ Invalid PIN")
            return nil
        case 403:
            print("🌐 PlexNetwork: ❌ PIN required but not provided")
            return nil
        default:
            print("🌐 PlexNetwork: ❌ User switch failed with status \(httpResponse.statusCode)")
            throw PlexAPIError.httpError(statusCode: httpResponse.statusCode, data: data)
        }
    }
}

// MARK: - URLSessionDelegate (SSL Certificate Handling)

extension PlexNetworkManager: URLSessionDelegate {
    /// Handle SSL certificate challenges for self-signed certificates
    nonisolated func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        let port = challenge.protectionSpace.port

        // Trust self-signed certificates for:
        // - IP addresses (local Plex servers)
        // - plex.direct domains
        // - Port 32400 (default Plex port)
        let isIPAddress = host.range(of: #"^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$"#, options: .regularExpression) != nil
        let isPlexDirect = host.hasSuffix(".plex.direct")
        let isPlexPort = port == 32400

        if isIPAddress || isPlexDirect || isPlexPort {
            // Trust the self-signed certificate
            let credential = URLCredential(trust: serverTrust)
            completionHandler(.useCredential, credential)
        } else {
            // Use default handling for other hosts (like plex.tv)
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - API Errors

enum PlexAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case httpError(statusCode: Int, data: Data?)
    case parsingError
    case authenticationFailed
    case notFound
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid URL"
        case .invalidResponse:
            return "Invalid server response"
        case .httpError(let statusCode, _):
            return "HTTP error: \(statusCode)"
        case .parsingError:
            return "Failed to parse response"
        case .authenticationFailed:
            return "Authentication failed"
        case .notFound:
            return "Item not found"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        }
    }
}

// MARK: - Playback Decision Models

struct PlaybackDecisionContainer: Codable, Sendable {
    let MediaContainer: PlaybackDecision
}

struct PlaybackDecision: Codable, Sendable {
    let size: Int?
    let directPlayDecisionCode: Int?
    let directPlayDecisionText: String?
    let generalDecisionCode: Int?
    let generalDecisionText: String?
    let transcodeDecisionCode: Int?
    let transcodeDecisionText: String?
    // MDE (Media Decision Engine) fields - used when hasMDE=1
    let mdeDecisionCode: Int?
    let mdeDecisionText: String?

    /// Check if direct play is available
    var canDirectPlay: Bool {
        // Code 1000 = "Direct play OK" (from either directPlay or MDE)
        directPlayDecisionCode == 1000 || mdeDecisionCode == 1000
    }

    /// Check if transcoding is required/available
    var requiresTranscode: Bool {
        !canDirectPlay && transcodeDecisionCode != nil
    }
}
