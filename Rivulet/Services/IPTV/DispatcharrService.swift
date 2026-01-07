//
//  DispatcharrService.swift
//  Rivulet
//
//  Service for interacting with Dispatcharr IPTV server
//  Dispatcharr provides M3U and XMLTV EPG endpoints at /output/m3u and /output/epg
//

import Foundation

/// Service for fetching data from a Dispatcharr server
actor DispatcharrService {

    // MARK: - Properties

    let baseURL: URL
    private let session: URLSession

    // MARK: - Initialization

    init(baseURL: URL) {
        self.baseURL = baseURL

        // Configure session with reasonable timeouts for potentially large M3U/EPG files
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120  // EPG files can be large
        self.session = URLSession(configuration: config)
    }

    /// Create a DispatcharrService from a URL string, cleaning up the URL if needed
    static func create(from urlString: String) -> DispatcharrService? {
        // Clean up the URL string
        var cleanedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove trailing slash if present
        if cleanedURL.hasSuffix("/") {
            cleanedURL = String(cleanedURL.dropLast())
        }

        // Add http:// if no scheme
        if !cleanedURL.hasPrefix("http://") && !cleanedURL.hasPrefix("https://") {
            cleanedURL = "http://\(cleanedURL)"
        }

        // Strip /output/m3u or /output/epg paths if user pasted a full endpoint URL
        // This prevents URL duplication when we append these paths later
        // Handles: /output/m3u, /output/m3u/, /output/m3u/ProfileName, etc.
        if let range = cleanedURL.range(of: "/output/m3u", options: .caseInsensitive) {
            cleanedURL = String(cleanedURL[..<range.lowerBound])
        } else if let range = cleanedURL.range(of: "/output/epg", options: .caseInsensitive) {
            cleanedURL = String(cleanedURL[..<range.lowerBound])
        }

        guard let url = URL(string: cleanedURL) else {
            return nil
        }

        return DispatcharrService(baseURL: url)
    }

    // MARK: - Public Methods

    /// Fetch the M3U playlist from Dispatcharr
    /// - Returns: Raw M3U data
    func fetchM3U() async throws -> Data {
        let url = baseURL.appendingPathComponent("output/m3u")
        print("📡 DispatcharrService: Fetching M3U from \(url)")

        let (data, response) = try await session.data(from: url)

        try validateResponse(response)

        print("📡 DispatcharrService: ✅ Fetched M3U (\(data.count) bytes)")
        return data
    }

    /// Fetch the XMLTV EPG from Dispatcharr
    /// - Returns: Raw XMLTV data
    func fetchEPG() async throws -> Data {
        let url = baseURL.appendingPathComponent("output/epg")
        print("📡 DispatcharrService: Fetching EPG from \(url)")

        let (data, response) = try await session.data(from: url)

        try validateResponse(response)

        print("📡 DispatcharrService: ✅ Fetched EPG (\(data.count) bytes)")
        return data
    }

    /// Check if the Dispatcharr server is reachable and responding
    /// - Returns: Status information about the server
    func getStatus() async throws -> DispatcharrStatus {
        // Try to fetch a small portion of the M3U to verify connectivity
        var request = URLRequest(url: baseURL.appendingPathComponent("output/m3u"))
        request.httpMethod = "HEAD"

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw DispatcharrError.invalidResponse
        }

        let isAvailable = (200...299).contains(httpResponse.statusCode)

        return DispatcharrStatus(
            baseURL: baseURL,
            isAvailable: isAvailable,
            statusCode: httpResponse.statusCode,
            checkedAt: Date()
        )
    }

    /// Fetch and parse channels from Dispatcharr
    /// - Returns: Parsed channels ready for use
    func fetchChannels() async throws -> [M3UParser.ParsedChannel] {
        let data = try await fetchM3U()
        let parser = M3UParser()
        return try await parser.parse(data: data)
    }

    /// Fetch and parse EPG from Dispatcharr
    /// - Returns: Parsed EPG data
    func fetchParsedEPG() async throws -> XMLTVParser.ParseResult {
        let data = try await fetchEPG()
        let parser = XMLTVParser()
        return try await parser.parse(data: data)
    }

    // MARK: - Private Methods

    private func validateResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DispatcharrError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return  // Success
        case 401, 403:
            throw DispatcharrError.unauthorized
        case 404:
            throw DispatcharrError.notFound
        case 500...599:
            throw DispatcharrError.serverError(httpResponse.statusCode)
        default:
            throw DispatcharrError.httpError(httpResponse.statusCode)
        }
    }
}

// MARK: - Status

struct DispatcharrStatus: Sendable {
    let baseURL: URL
    let isAvailable: Bool
    let statusCode: Int
    let checkedAt: Date

    var statusDescription: String {
        if isAvailable {
            return "Connected"
        } else {
            return "Error (\(statusCode))"
        }
    }
}

// MARK: - Errors

enum DispatcharrError: LocalizedError {
    case invalidResponse
    case unauthorized
    case notFound
    case serverError(Int)
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from Dispatcharr server"
        case .unauthorized:
            return "Unauthorized - check Dispatcharr authentication"
        case .notFound:
            return "Dispatcharr endpoint not found - verify URL"
        case .serverError(let code):
            return "Dispatcharr server error (\(code))"
        case .httpError(let code):
            return "HTTP error \(code)"
        }
    }
}

// MARK: - URL Builder Extensions

extension DispatcharrService {
    /// Build the M3U URL for this Dispatcharr instance
    var m3uURL: URL {
        baseURL.appendingPathComponent("output/m3u")
    }

    /// Build the EPG URL for this Dispatcharr instance
    var epgURL: URL {
        baseURL.appendingPathComponent("output/epg")
    }

    /// Build the Swagger API URL (for reference/debugging)
    var swaggerURL: URL {
        baseURL.appendingPathComponent("swagger")
    }
}
