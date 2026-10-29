// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  LiveHLSScrubThumbnails.swift
//  Rivulet
//

import CoreGraphics
import Foundation

/// Scrub previews for a live HLS channel on the native route, where AVPlayer
/// fetches the segments and the engine holds none (its own live scrub
/// thumbnails come from the loopback route's segment cache). Each preview reads only the head of the segment under the scrub
/// position, where a live segment's keyframe sits, and decodes one small frame
/// from it: about the cost of VOD's on-device fallback, but across the internet.
///
/// Preview I/O is capped independently of the origin's support for Range.
@MainActor
final class LiveHLSScrubThumbnails {
    struct Segment: Equatable {
        let url: URL
        let duration: TimeInterval
        /// EXT-X-MEDIA-SEQUENCE number, the default AES-128 IV.
        var sequence: Int = 0
        var key: Key?
    }

    /// An EXT-X-KEY in force for a segment.
    struct Key: Equatable {
        let method: String
        let url: URL?
        let iv: Data?
        let keyFormat: String?
    }

    struct Playlist: Equatable {
        var segments: [Segment]
        /// EXT-X-MAP: the init segment an fMP4 media segment needs to decode.
        var mapURL: URL?
    }

    private let playlistURL: URL
    private let headers: [String: String]
    /// The media playlist AVPlayer is actually fetching (its access log's URI).
    /// Preferred over `playlistURL`: a provider can bind the URL it handed out
    /// to the player's session, and this is the variant really playing.
    private let playingMediaPlaylist: @MainActor () -> URL?
    /// One small frame from a segment head (`ts`, `mp4`, or raw `h264`). The
    /// decoder is the engine's, so each app hands its own in: shared code
    /// names no per-platform player.
    typealias FrameDecoder = @Sendable (_ data: Data, _ fileExtension: String, _ maxWidth: Int) async -> CGImage?
    private let decodeFirstFrame: FrameDecoder
    private let session: URLSession
    private var mediaPlaylistURL: URL?
    private var playlist: Playlist?
    private var playlistFetchedAt: Date?
    /// Init segments by URL: each variant has its own, and AVPlayer moves
    /// between variants as bandwidth changes. One kept across a switch paired
    /// the new variant's segments with the old variant's init (green frames).
    private var initSegments: [URL: Data] = [:]
    private var cache: [URL: CGImage] = [:]
    private var cacheOrder: [URL] = []

    static let cacheLimit = 32
    /// How long a fetched media playlist is reused. A deep window is a long
    /// playlist (a megabyte at 2.5 hours of tokened URLs), and re-reading it
    /// every few seconds while scrubbing was most of each preview's wait. A
    /// live window slides in real time, so a playlist this old still finds the
    /// right segment once the offset is moved by its age (`thumbnail`).
    static let playlistLifetime: TimeInterval = 15

    init(
        playlistURL: URL, headers: [String: String],
        configuration: URLSessionConfiguration = .ephemeral,
        playingMediaPlaylist: @escaping @MainActor () -> URL? = { nil },
        decodeFirstFrame: @escaping FrameDecoder = { _, _, _ in nil }
    ) {
        self.playlistURL = playlistURL
        self.headers = headers
        self.playingMediaPlaylist = playingMediaPlaylist
        self.decodeFirstFrame = decodeFirstFrame
        // AVPlayer's own cookie store: a provider that sets a session cookie
        // when the player connects expects it back on every request.
        configuration.httpCookieStorage = .shared
        configuration.httpShouldSetCookies = true
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 12
        configuration.httpMaximumConnectionsPerHost = 2
        session = URLSession(configuration: configuration)
    }

    deinit { session.invalidateAndCancel() }

    /// A frame near `offset` seconds after the start of AVPlayer's seekable
    /// range, which begins with the oldest segment of the playlist it holds.
    func thumbnail(secondsIntoWindow offset: TimeInterval, maxWidth: Int) async -> CGImage? {
        guard !Task.isCancelled, offset.isFinite else { return nil }
        guard let playlist = await currentPlaylist(), !Task.isCancelled else {
            Self.trace("no media playlist")
            return nil
        }
        // The window has slid on since this playlist was read: its first
        // segment is that much older than the one AVPlayer's range starts on.
        let age = playlistFetchedAt.map { max(0, Date().timeIntervalSince($0)) } ?? 0
        guard let segment = Self.segment(at: offset + age, in: playlist.segments) else {
            Self.trace("no segment at \(offset)s of \(playlist.segments.count)")
            return nil
        }
        if let cached = cache[segment.url] { return cached }
        if let key = segment.key, !Self.canDecrypt(key, fragmented: playlist.mapURL != nil) {
            Self.noteUnsupported("\(key.method) \(key.keyFormat ?? "identity")")
            return nil
        }
        // Small first: a keyframe usually fits, and the provider's throughput is
        // the whole wait. A head too short to decode is read again, longer.
        for (attempt, limit) in Self.headLimits.enumerated() {
            guard !Task.isCancelled else { return nil }
            guard var data = await head(of: segment.url, bytes: limit) else {
                Self.trace("segment head unavailable")
                return nil
            }
            let bytes = data.count
            let lastAttempt = attempt == Self.headLimits.count - 1 || bytes < limit
            var fileExtension = playlist.mapURL == nil ? "ts" : "mp4"
            var decryptedTransportHead = Data()
            var initSegment: Data?
            if let mapURL = playlist.mapURL {
                if initSegments[mapURL] == nil {
                    if initSegments.count >= 8 { initSegments.removeAll() }
                    initSegments[mapURL] = await whole(mapURL)
                }
                initSegment = initSegments[mapURL]
            }
            if let key = segment.key {
                guard let keyData = await keyBytes(for: key) else {
                    Self.trace("\(key.method) key unavailable")
                    return nil
                }
                let iv = key.iv ?? Self.sequenceIV(segment.sequence)
                switch key.method {
                case "AES-128":
                    guard let decrypted = HLSSampleDecryption.cbcDecrypt(data, key: keyData, iv: iv) else { return nil }
                    data = decrypted
                case _ where playlist.mapURL == nil:
                    // SAMPLE-AES in MPEG-TS: the decrypted H.264 stream itself.
                    // Packet structure is clear, so completeness reads the TS.
                    decryptedTransportHead = data
                    guard let stream = HLSSampleDecryption.decryptTransportStreamH264(data, key: keyData, iv: iv) else {
                        Self.noteUnsupported("SAMPLE-AES TS without H.264 video")
                        return nil
                    }
                    data = stream
                    fileExtension = "h264"
                default:
                    guard let initSegment,
                          let track = HLSSampleDecryption.videoTrackEncryption(initSegment: initSegment) else {
                        Self.noteUnsupported("fMP4 encryption without a readable tenc")
                        return nil
                    }
                    data = HLSSampleDecryption.decryptFragmentedMP4(
                        data, track: track, key: keyData, playlistIV: key.iv
                    )
                }
            }
            // A keyframe cut short decodes as a picture going green where its
            // bytes ran out: read further rather than show that.
            if !HLSSampleDecryption.leadingFrameIsComplete(
                fileExtension == "h264" ? decryptedTransportHead : data, fragmented: playlist.mapURL != nil) {
                guard !lastAttempt else {
                    Self.trace("leading frame incomplete in \(bytes) bytes")
                    return nil
                }
                continue
            }
            if playlist.mapURL != nil {
                guard let initSegment else { return nil }
                data = initSegment + data
            }
            guard !Task.isCancelled else { return nil }
            let image = await decodeFirstFrame(data, fileExtension, maxWidth)
            if let image, !Task.isCancelled {
                remember(image, for: segment.url)
                return image
            }
            guard !lastAttempt else {
                Self.trace("\(fileExtension) head of \(data.count) bytes did not decode")
                return nil
            }
        }
        return nil
    }

    /// Debug-only, like `playerDebugLog`, but callable off the main actor: the
    /// fetch path reports from URLSession's side. Hosts only, never a URL.
    nonisolated static func trace(_ message: String) {
        #if DEBUG
        print("📺 Scrub preview: \(message)")
        #endif
    }

    /// 256 KB holds a typical 1080p keyframe; high-bitrate sport needs more.
    static let headLimits = [256 * 1_024, 768 * 1_024, 2 * 1_024 * 1_024]

    private var keys: [URL: Data] = [:]

    /// Every scheme a plain key URL can open; DRM key formats (FairPlay's
    /// `com.apple.streamingkeydelivery`, Widevine, PlayReady) cannot be.
    nonisolated static func canDecrypt(_ key: Key, fragmented: Bool) -> Bool {
        guard key.url != nil, key.keyFormat.map({ $0 == "identity" }) ?? true else { return false }
        switch key.method {
        case "AES-128": return true
        case "SAMPLE-AES": return true
        case "SAMPLE-AES-CTR": return fragmented
        default: return false
        }
    }

    /// The 16-byte key, fetched once per URI (with the channel's headers), or
    /// read from a `data:` URI inline.
    /// Reads the playlist, its init segment and its key ahead of the first
    /// scrub, so that one waits only on its own segment head. A cold first
    /// preview read five resources in a row (master, media playlist, init,
    /// key, segment), about two seconds on a deep window.
    func prewarm() async {
        guard let playlist = await currentPlaylist(), !Task.isCancelled else { return }
        if let mapURL = playlist.mapURL, initSegments[mapURL] == nil {
            if initSegments.count >= 8 { initSegments.removeAll() }
            initSegments[mapURL] = await whole(mapURL)
        }
        if let key = playlist.segments.last?.key, Self.canDecrypt(key, fragmented: playlist.mapURL != nil) {
            _ = await keyBytes(for: key)
        }
    }

    private func keyBytes(for key: Key) async -> Data? {
        guard let keyURL = key.url else { return nil }
        if let cached = keys[keyURL] { return cached }
        let fetched: Data?
        if keyURL.scheme == "data" {
            fetched = keyURL.absoluteString.split(separator: ",", maxSplits: 1).last
                .flatMap { Data(base64Encoded: String($0)) }
        } else {
            fetched = await fetch(request(keyURL), maximumBytes: 16)
        }
        guard let fetched, fetched.count == 16 else {
            return nil
        }
        if keys.count >= 8 { keys.removeAll() }
        keys[keyURL] = fetched
        return fetched
    }

    /// One quiet line per kind of stream previews can't open (DRM, layouts).
    private static var notedUnsupported: Set<String> = []
    private static func noteUnsupported(_ kind: String) {
        guard notedUnsupported.insert(kind).inserted else { return }
        playerDebugLog("📺 Scrub previews unavailable: \(kind)")
    }

    // MARK: Playlist

    /// The variant previews come from, chosen once from the master playlist;
    /// nil when there is none to read, and previews follow AVPlayer instead.
    private var thumbnailVariant: URL?
    private var masterChecked = false

    private func currentPlaylist() async -> Playlist? {
        if !masterChecked {
            masterChecked = true
            // Relative URIs resolve against where the playlist came from: a
            // provider that redirects its master to a CDN lists its variants
            // relative to the CDN, as AVPlayer reads them.
            if let (text, base) = await text(of: playlistURL) {
                if let variant = Self.thumbnailVariant(in: text, base: base) {
                    thumbnailVariant = variant
                } else if text.contains("#EXTINF") {
                    thumbnailVariant = base
                }
            }
        }
        // A provider that refuses the master (session-bound URLs) still lets
        // previews follow the media playlist AVPlayer is fetching.
        guard let target = thumbnailVariant ?? playingMediaPlaylist() else { return playlist }
        if target != mediaPlaylistURL {
            // A new variant: the cached playlist, its segments and map belong
            // to the one just left.
            mediaPlaylistURL = target
            playlist = nil
            playlistFetchedAt = nil
        }
        if let playlist, let playlistFetchedAt,
           Date().timeIntervalSince(playlistFetchedAt) < Self.playlistLifetime {
            return playlist
        }
        guard let (text, base) = await text(of: target) else {
            // A variant read from the master that its origin refuses: follow
            // the media playlist AVPlayer plays instead.
            if target == thumbnailVariant, playingMediaPlaylist() != nil { thumbnailVariant = nil }
            return playlist
        }
        return store(Self.parseMediaPlaylist(text, base: base))
    }

    /// The variant to draw previews from: the smallest video rendition at least
    /// `preferredWidth` wide (decoded at that width, it needs no upscaling),
    /// else the widest below it; without resolutions, the lowest-bandwidth video
    /// rendition. Audio-only entries never qualify. nil for a media playlist.
    nonisolated static func thumbnailVariant(in text: String, base: URL, preferredWidth: Int = 640) -> URL? {
        struct Variant { let url: URL; let width: Int?; let bandwidth: Int }
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var variants: [Variant] = []
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
            guard let uri = lines[(index + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let url = URL(string: uri, relativeTo: base)?.absoluteURL else { continue }
            if let codecs = attribute("CODECS", in: line)?.lowercased() {
                let video = ["avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe", "av01", "vp09", "mp4v"]
                guard video.contains(where: { codecs.contains($0) }) else { continue }
            }
            let width = attribute("RESOLUTION", in: line)?.lowercased().split(separator: "x").first.flatMap { Int($0) }
            let bandwidth = attribute("BANDWIDTH", in: line).flatMap(Int.init) ?? .max
            variants.append(Variant(url: url, width: width, bandwidth: bandwidth))
        }
        guard !variants.isEmpty else { return nil }
        let sized = variants.filter { $0.width != nil }
        if let atLeast = sized.filter({ $0.width! >= preferredWidth }).min(by: { ($0.width!, $0.bandwidth) < ($1.width!, $1.bandwidth) }) {
            return atLeast.url
        }
        if let widest = sized.max(by: { ($0.width!, -$0.bandwidth) < ($1.width!, -$1.bandwidth) }) {
            return widest.url
        }
        return variants.min { $0.bandwidth < $1.bandwidth }?.url
    }

    private func store(_ parsed: Playlist?) -> Playlist? {
        guard let parsed, !parsed.segments.isEmpty else { return nil }
        playlist = parsed
        playlistFetchedAt = Date()
        return parsed
    }

    nonisolated static func parseMediaPlaylist(_ text: String, base: URL) -> Playlist? {
        guard text.contains("#EXTM3U") else { return nil }
        var segments: [Segment] = []
        var mapURL: URL?
        var pendingDuration: TimeInterval?
        var sequence = 0
        var key: Key?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            // A URL alone cannot identify one byte-range segment. Until range
            // offsets are modelled, omit previews rather than cache the wrong frame.
            if line.hasPrefix("#EXT-X-BYTERANGE:") { return nil }
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let method = attribute("METHOD", in: line) ?? "NONE"
                key = method == "NONE" ? nil : Key(
                    method: method,
                    url: attribute("URI", in: line).flatMap { URL(string: $0, relativeTo: base)?.absoluteURL },
                    iv: attribute("IV", in: line).flatMap(hexData),
                    keyFormat: attribute("KEYFORMAT", in: line)
                )
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",").first.map(String.init)
                pendingDuration = value.flatMap(Double.init).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            } else if line.hasPrefix("#EXT-X-MAP:"), let uri = attribute("URI", in: line) {
                let next = URL(string: uri, relativeTo: base)?.absoluteURL
                guard attribute("BYTERANGE", in: line) == nil, mapURL == nil || mapURL == next else { return nil }
                mapURL = next
            } else if !line.isEmpty, !line.hasPrefix("#"), let duration = pendingDuration {
                if let url = URL(string: line, relativeTo: base)?.absoluteURL {
                    segments.append(Segment(url: url, duration: duration, sequence: sequence, key: key))
                }
                guard sequence < Int.max else { return nil }
                sequence += 1
                pendingDuration = nil
            }
        }
        return Playlist(segments: segments, mapURL: mapURL)
    }

    /// A tag attribute, quoted or not (`URI="…"`, `METHOD=AES-128`).
    nonisolated static func attribute(_ name: String, in line: String) -> String? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        var rest = line[line.index(after: colon)...]
        while !rest.isEmpty {
            guard let equals = rest.firstIndex(of: "=") else { return nil }
            let key = rest[..<equals].trimmingCharacters(in: .whitespaces)
            rest = rest[rest.index(after: equals)...]
            let value: Substring
            if rest.first == "\"" {
                rest = rest.dropFirst()
                let end = rest.firstIndex(of: "\"") ?? rest.endIndex
                value = rest[..<end]
                rest = end < rest.endIndex ? rest[rest.index(after: end)...] : rest[end...]
                if rest.first == "," { rest = rest.dropFirst() }
            } else {
                let end = rest.firstIndex(of: ",") ?? rest.endIndex
                value = rest[..<end]
                rest = end < rest.endIndex ? rest[rest.index(after: end)...] : rest[end...]
            }
            if key == name { return String(value) }
        }
        return nil
    }

    nonisolated static func hexData(_ text: String) -> Data? {
        var hex = text.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard hex.count % 2 == 0 else { return nil }
        var data = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data
    }

    /// The default IV: the media sequence number as a 128-bit big-endian value.
    nonisolated static func sequenceIV(_ sequence: Int) -> Data {
        var iv = Data(count: 16)
        var value = UInt64(max(0, sequence)).bigEndian
        withUnsafeBytes(of: &value) { iv.replaceSubrange(8..<16, with: $0) }
        return iv
    }

    /// The segment covering `offset` seconds from the playlist's start; past the
    /// end clamps to the newest segment.
    nonisolated static func segment(at offset: TimeInterval, in segments: [Segment]) -> Segment? {
        var elapsed: TimeInterval = 0
        for segment in segments {
            elapsed += segment.duration
            if offset < elapsed { return segment }
        }
        return segments.last
    }

    // MARK: Network

    /// IPTV servers commonly answer only media players: identify as AVPlayer
    /// does unless the channel declared its own User-Agent.
    ///
    /// The device in the fallback User-Agent. Host-injected at launch, like
    /// `PlexAPI.deviceName`; defaults to the tvOS value.
    static var playerDevice = "Apple TV"

    static var playerUserAgent: String {
        // AVPlayer's own form: AppleCoreMedia/1.0.0.<build> (<device>; U; CPU OS <v> like Mac OS X; <locale>).
        var size = 0
        sysctlbyname("kern.osversion", nil, &size, nil, 0)
        var build = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("kern.osversion", &build, &size, nil, 0)
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let os = "\(version.majorVersion)_\(version.minorVersion)" + (version.patchVersion > 0 ? "_\(version.patchVersion)" : "")
        let device = playerDevice
        let locale = Locale.current.identifier.lowercased()
        return "AppleCoreMedia/1.0.0.\(String(cString: build)) (\(device); U; CPU OS \(os) like Mac OS X; \(locale))"
    }

    /// Headers that say which client is asking rather than who it is. AVPlayer
    /// sends them on every request, and providers check them on their CDN and
    /// key hosts too: without them an encrypted channel's keys come back 403.
    nonisolated static let clientIdentityHeaders: Set<String> = ["user-agent", "referer", "origin"]

    nonisolated static func isClientIdentityHeader(_ name: String) -> Bool {
        clientIdentityHeaders.contains(name.lowercased())
    }

    /// Same scheme, host and port, both plain http(s) without userinfo. A URL
    /// compared with itself answers whether it is one this fetcher may open.
    nonisolated static func sameOrigin(_ first: URL, _ second: URL) -> Bool {
        func isHTTP(_ url: URL) -> Bool {
            ["http", "https"].contains(url.scheme?.lowercased() ?? "")
                && url.host != nil && url.user == nil && url.password == nil
        }
        guard isHTTP(first), isHTTP(second) else { return false }
        func port(_ url: URL) -> Int { url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80) }
        return first.scheme?.lowercased() == second.scheme?.lowercased()
            && first.host?.lowercased() == second.host?.lowercased()
            && port(first) == port(second)
    }

    func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        // Playlist-provided CDN/key URLs do not authorize forwarding the
        // channel's credentials to another origin, only its client identity.
        let sameOrigin = LiveHLSScrubThumbnails.sameOrigin(playlistURL, url)
        for (name, value) in headers where sameOrigin || Self.isClientIdentityHeader(name) {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(Self.playerUserAgent, forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    /// The largest playlist read. A deep window is a long playlist: Fox Footy's
    /// 2.5 hours is 2,009 segments, each URL carrying a CDN token, close to
    /// 1 MB of text. The old 512 KB cap refused it outright, so those channels
    /// never had a preview. Four hours of such URLs is about 1.6 MB.
    static let playlistByteLimit = 4 * 1_024 * 1_024

    /// The playlist's text and the URL it was finally served from.
    private func text(of url: URL) async -> (String, URL)? {
        guard let (data, served) = await Self.fetchServed(request(url), session: session,
                                                           maximumBytes: Self.playlistByteLimit),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return (text, served)
    }

    private func whole(_ url: URL) async -> Data? {
        await fetch(request(url), maximumBytes: 2 * 1_024 * 1_024)
    }

    private func fetch(_ request: URLRequest, maximumBytes: Int, allowsPrefix: Bool = false) async -> Data? {
        await Self.fetch(request, session: session, maximumBytes: maximumBytes, allowsPrefix: allowsPrefix)
    }

    nonisolated static func fetch(
        _ request: URLRequest, session: URLSession, maximumBytes: Int, allowsPrefix: Bool = false
    ) async -> Data? {
        await fetchServed(request, session: session, maximumBytes: maximumBytes, allowsPrefix: allowsPrefix)?.data
    }

    /// The body, and the URL that served it after any redirects.
    ///
    /// Read in the chunks the network delivers. An earlier version walked
    /// `URLSession.AsyncBytes` a byte at a time: fine for a key or a segment
    /// head, but a megabyte playlist took long enough on an Apple TV to hit
    /// the request timeout, and every preview waited behind it.
    nonisolated static func fetchServed(
        _ request: URLRequest, session: URLSession, maximumBytes: Int, allowsPrefix: Bool = false
    ) async -> (data: Data, url: URL)? {
        guard let url = request.url, LiveHLSScrubThumbnails.sameOrigin(url, url), maximumBytes > 0,
              !Task.isCancelled else { return nil }
        let load = LiveHLSBoundedLoad(maximumBytes: maximumBytes, allowsPrefix: allowsPrefix)
        let task = session.dataTask(with: request)
        task.delegate = load
        let result = await withTaskCancellationHandler {
            await load.run(task)
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled else { return nil }
        return result
    }

    /// The first `bytes` of a segment by range request. An origin that ignores
    /// the range is cancelled once the bounded prefix has arrived.
    private func head(of url: URL, bytes: Int) async -> Data? {
        var request = request(url)
        request.setValue("bytes=0-\(bytes - 1)", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        guard let data = await fetch(request, maximumBytes: bytes, allowsPrefix: true), !data.isEmpty else { return nil }
        return data
    }

    // MARK: Cache

    private func remember(_ image: CGImage, for url: URL) {
        cache[url] = image
        cacheOrder.removeAll { $0 == url }
        cacheOrder.append(url)
        while cacheOrder.count > Self.cacheLimit {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
    }
}

nonisolated class LiveHLSScrubRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(Self.redirect(task.originalRequest, to: request.url))
    }

    /// Providers commonly hand a channel's playlist, segments or keys to a CDN
    /// by redirect, as AVPlayer follows them. A redirect within the origin keeps
    /// every header; one to another origin keeps the client identity and the
    /// byte range but drops credentials, and never downgrades to plain HTTP.
    static func redirect(_ original: URLRequest?, to destination: URL?) -> URLRequest? {
        guard let original, let origin = original.url, let destination,
              LiveHLSScrubThumbnails.sameOrigin(destination, destination),
              !(origin.scheme?.lowercased() == "https" && destination.scheme?.lowercased() == "http")
        else { return nil }
        var redirected = original
        redirected.url = destination
        if !LiveHLSScrubThumbnails.sameOrigin(origin, destination) {
            let kept: Set<String> = ["range", "accept-encoding"]
            for name in (original.allHTTPHeaderFields ?? [:]).keys
            where !kept.contains(name.lowercased()) && !LiveHLSScrubThumbnails.isClientIdentityHeader(name) {
                redirected.setValue(nil, forHTTPHeaderField: name)
            }
        }
        return redirected
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
}

/// One bounded read: the body as it arrives, cut off at `maximumBytes`. With
/// `allowsPrefix` (a segment head, from an origin that may ignore Range) the
/// first `maximumBytes` are the answer; without it (a playlist, a key, an
/// init segment) anything longer is refused. Redirects follow the
/// `LiveHLSScrubRedirects` policy. All state is touched under `lock`: the
/// session calls back on its own queue.
nonisolated final class LiveHLSBoundedLoad: LiveHLSScrubRedirects, URLSessionDataDelegate, @unchecked Sendable {
    private let maximumBytes: Int
    private let allowsPrefix: Bool
    private let lock = NSLock()
    private var data = Data()
    private var servedURL: URL?
    private var continuation: CheckedContinuation<(data: Data, url: URL)?, Never>?
    private var outcome: (data: Data, url: URL)??

    init(maximumBytes: Int, allowsPrefix: Bool) {
        self.maximumBytes = maximumBytes
        self.allowsPrefix = allowsPrefix
    }

    func run(_ task: URLSessionDataTask) async -> (data: Data, url: URL)? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            self.continuation = continuation
            lock.unlock()
            task.resume()
        }
    }

    /// The first outcome wins; later callbacks (the cancel it triggers) are ignored.
    private func finish(_ result: (data: Data, url: URL)?) {
        lock.lock()
        guard outcome == nil else { lock.unlock(); return }
        outcome = .some(result)
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: result)
    }

    func urlSession(
        _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let url = response.url ?? dataTask.originalRequest?.url
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let url,
              allowsPrefix || response.expectedContentLength <= maximumBytes else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            LiveHLSScrubThumbnails.trace("\(Self.describe(response.url)) answered HTTP \(status), \(response.expectedContentLength) bytes")
            finish(nil)
            completionHandler(.cancel)
            return
        }
        // A prefix must start at zero, not an unrelated cached range.
        if http.statusCode == 206,
           http.value(forHTTPHeaderField: "Content-Range")?.lowercased().hasPrefix("bytes 0-") != true {
            finish(nil)
            completionHandler(.cancel)
            return
        }
        lock.lock()
        servedURL = url
        data.reserveCapacity(min(maximumBytes, max(0, Int(response.expectedContentLength))))
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
        lock.lock()
        data.append(chunk)
        let count = data.count
        let served = servedURL
        lock.unlock()
        guard count >= maximumBytes else { return }
        if allowsPrefix, let served {
            lock.lock()
            let prefix = data.prefix(maximumBytes)
            lock.unlock()
            finish((Data(prefix), served))
            dataTask.cancel()
        } else if count > maximumBytes {
            finish(nil)
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            if (error as? URLError)?.code != .cancelled {
                LiveHLSScrubThumbnails.trace("\(Self.describe(task.originalRequest?.url)) failed: \((error as? URLError)?.code.rawValue ?? 0)")
            }
            finish(nil)
            return
        }
        lock.lock()
        let body = data
        let served = servedURL
        lock.unlock()
        finish(served.map { (body, $0) })
    }

    /// Host and path only: queries carry tokens.
    private static func describe(_ url: URL?) -> String {
        guard let url else { return "?" }
        return (url.host ?? "?") + url.path
    }
}
