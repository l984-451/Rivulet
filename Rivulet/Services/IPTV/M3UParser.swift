//
//  M3UParser.swift
//  Rivulet
//
//  Parses M3U/M3U8 playlist files for IPTV channel data
//

import Foundation

/// Actor for parsing M3U playlist files
actor M3UParser {

    // MARK: - Parsed Channel

    /// Represents a channel parsed from an M3U playlist
    struct ParsedChannel: Sendable {
        let tvgId: String?
        let tvgName: String?
        let tvgLogo: String?
        let groupTitle: String?
        let channelNumber: Int?
        let name: String
        let streamURL: URL

        /// Whether this appears to be an HD channel (based on name)
        var isHD: Bool {
            let lowercaseName = name.lowercased()
            return lowercaseName.contains(" hd") ||
                   lowercaseName.hasSuffix("hd") ||
                   lowercaseName.contains("1080") ||
                   lowercaseName.contains("720")
        }
    }

    // MARK: - Public Methods

    /// Parse an M3U playlist from a URL
    /// - Parameter url: URL to the M3U playlist
    /// - Returns: Array of parsed channels
    func parse(from url: URL) async throws -> [ParsedChannel] {
        let (data, _) = try await fetchWithHTTPSUpgrade(url: url)
        return try parse(data: data)
    }

    // MARK: - Private Networking

    /// Fetch data from URL, attempting HTTPS upgrade for HTTP URLs
    /// - Parameter url: The URL to fetch from
    /// - Returns: The fetched data and response
    private func fetchWithHTTPSUpgrade(url: URL) async throws -> (Data, URLResponse) {
        // If already HTTPS or not HTTP, use as-is
        guard url.scheme == "http",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return try await fetchData(from: url)
        }

        // Try HTTPS first with a short timeout
        components.scheme = "https"
        if let httpsURL = components.url {
            do {
                return try await fetchData(from: httpsURL, timeout: 3.0)
            } catch {
                // HTTPS failed, fall back to HTTP
                print("📺 M3UParser: HTTPS failed for \(httpsURL.host ?? "unknown"), falling back to HTTP")
            }
        }

        // Fall back to original HTTP URL
        return try await fetchData(from: url)
    }

    /// Fetch data from a URL with optional custom timeout
    private func fetchData(from url: URL, timeout: TimeInterval? = nil) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        if let timeout = timeout {
            request.timeoutInterval = timeout
        }

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw M3UParseError.httpError(httpResponse.statusCode)
        }

        return (data, response)
    }

    /// Parse M3U playlist from raw data
    /// - Parameter data: Raw M3U playlist data
    /// - Returns: Array of parsed channels
    func parse(data: Data) throws -> [ParsedChannel] {
        guard let content = String(data: data, encoding: .utf8) else {
            throw M3UParseError.invalidEncoding
        }

        return try parse(content: content)
    }

    /// Parse M3U playlist from string content
    /// - Parameter content: M3U playlist as string
    /// - Returns: Array of parsed channels
    func parse(content: String) throws -> [ParsedChannel] {
        let lines = content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard lines.first?.uppercased().hasPrefix("#EXTM3U") == true else {
            throw M3UParseError.invalidFormat("Missing #EXTM3U header")
        }

        var channels: [ParsedChannel] = []
        var currentExtInf: String?

        for line in lines.dropFirst() {
            if line.uppercased().hasPrefix("#EXTINF:") {
                currentExtInf = line
            } else if line.hasPrefix("#") {
                // Skip other directives
                continue
            } else if let extInf = currentExtInf, let url = URL(string: line) {
                // This is a stream URL following an EXTINF
                if let channel = parseChannel(extInf: extInf, streamURL: url) {
                    channels.append(channel)
                }
                currentExtInf = nil
            }
        }

        return channels
    }

    // MARK: - Private Methods

    /// Parse a single channel from EXTINF line and stream URL
    private func parseChannel(extInf: String, streamURL: URL) -> ParsedChannel? {
        // Parse the EXTINF line
        // Format: #EXTINF:-1 tvg-id="..." tvg-name="..." tvg-logo="..." group-title="..." tvg-chno="123",Channel Name
        // The comma separates attributes from the display name

        guard let commaIndex = extInf.lastIndex(of: ",") else {
            return nil
        }

        let attributesPart = String(extInf[extInf.startIndex..<commaIndex])
        let name = String(extInf[extInf.index(after: commaIndex)...]).trimmingCharacters(in: .whitespaces)

        guard !name.isEmpty else {
            return nil
        }

        // Parse attributes
        let tvgId = extractAttribute(from: attributesPart, name: "tvg-id")
        let tvgName = extractAttribute(from: attributesPart, name: "tvg-name")
        let tvgLogo = extractAttribute(from: attributesPart, name: "tvg-logo")
        let groupTitle = extractAttribute(from: attributesPart, name: "group-title")
        let channelNumberStr = extractAttribute(from: attributesPart, name: "tvg-chno")
            ?? extractAttribute(from: attributesPart, name: "channel-number")
        let channelNumber = channelNumberStr.flatMap { Int($0) }

        return ParsedChannel(
            tvgId: tvgId,
            tvgName: tvgName,
            tvgLogo: tvgLogo,
            groupTitle: groupTitle,
            channelNumber: channelNumber,
            name: name,
            streamURL: streamURL
        )
    }

    /// Extract an attribute value from the EXTINF attributes string
    /// - Parameters:
    ///   - string: The attributes portion of EXTINF line
    ///   - name: Attribute name to extract
    /// - Returns: The attribute value, or nil if not found
    private func extractAttribute(from string: String, name: String) -> String? {
        // Look for patterns like: tvg-id="value" or tvg-id='value'
        let patterns = [
            "\(name)=\"([^\"]*)\"",  // Double quotes
            "\(name)='([^']*)'",      // Single quotes
            "\(name)=([^\\s,]+)"      // No quotes (until space or comma)
        ]

        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)),
               let range = Range(match.range(at: 1), in: string) {
                let value = String(string[range])
                return value.isEmpty ? nil : value
            }
        }

        return nil
    }
}

// MARK: - Errors

enum M3UParseError: LocalizedError {
    case invalidEncoding
    case invalidFormat(String)
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidEncoding:
            return "Could not decode M3U content as UTF-8"
        case .invalidFormat(let message):
            return "Invalid M3U format: \(message)"
        case .httpError(let code):
            return "HTTP error \(code)"
        }
    }
}

// MARK: - Convenience Extensions

extension M3UParser.ParsedChannel {
    /// Convert to UnifiedChannel
    func toUnifiedChannel(sourceType: LiveTVSourceType, sourceId: String) -> UnifiedChannel {
        // Create a unique ID for this channel
        let channelId = tvgId ?? tvgName ?? name
        let id = UnifiedChannel.makeId(sourceType: sourceType, sourceId: sourceId, channelId: channelId)

        return UnifiedChannel(
            id: id,
            sourceType: sourceType,
            sourceId: sourceId,
            channelNumber: channelNumber,
            name: tvgName ?? name,
            callSign: nil,
            logoURL: tvgLogo.flatMap { URL(string: $0) },
            streamURL: streamURL,
            tvgId: tvgId,
            groupTitle: groupTitle,
            isHD: isHD
        )
    }
}
