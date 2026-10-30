// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import XCTest
import os
@testable import Rivulet

@MainActor
final class SiloMediaRelayTests: XCTestCase {
    func test_mediaReadsRefresh401OnceAndKeepRangeAndHeadSemantics() async throws {
        let host = "silo-relay-\(UUID().uuidString.lowercased()).invalid"
        let base = URL(string: "https://\(host)/proxy/silo")!
        let remote = base.appending(path: "api/v2/stream/session-a")
        let fixture = SiloMediaProtocolFixture()
        SiloMediaFixtureProtocol.install(fixture, host: host)
        defer { SiloMediaFixtureProtocol.remove(host: host) }
        fixture.respond("GET", remote, [
            .init(status: 401),
            .init(status: 206, headers: ["Content-Type": "video/mp4", "Content-Range": "bytes 2-5/8", "Accept-Ranges": "bytes"], body: Data("CDEF".utf8))
        ])
        fixture.respond("HEAD", remote, [.init(headers: ["Content-Type": "video/mp4", "Content-Length": "8", "Accept-Ranges": "bytes"])])
        let credentials = SiloMediaCredentialFixture()
        let client = SiloClient(baseURL: base, profileID: "profile-a", profileToken: "proof-a",
                                tokenSource: { await credentials.token(force: $0) })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SiloMediaFixtureProtocol.self]
        let relay = try await SiloMediaRelay.start(client: client, configuration: configuration)
        defer { relay.stop() }
        let local = try relay.localURL(for: remote)
        let consumer = URLSession(configuration: .ephemeral)
        defer { consumer.invalidateAndCancel() }
        var range = URLRequest(url: local)
        range.setValue("bytes=2-5", forHTTPHeaderField: "Range")
        let (data, response) = try await consumer.data(for: range)
        XCTAssertEqual(data, Data("CDEF".utf8))
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 206)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Content-Range"), "bytes 2-5/8")
        XCTAssertEqual(http.value(forHTTPHeaderField: "Accept-Ranges"), "bytes")

        await credentials.rotate(to: "later-access")
        var head = URLRequest(url: local)
        head.httpMethod = "HEAD"
        let (headBody, headResponse) = try await consumer.data(for: head)
        XCTAssertTrue(headBody.isEmpty)
        XCTAssertEqual(headResponse.expectedContentLength, 8)
        let requests = fixture.requests()
        XCTAssertEqual(requests.map { $0.httpMethod }, ["GET", "GET", "HEAD"])
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer initial-access", "Bearer refreshed-access", "Bearer later-access"])
        XCTAssertEqual(requests.prefix(2).map { $0.value(forHTTPHeaderField: "Range") }, ["bytes=2-5", "bytes=2-5"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Profile-Id") == "profile-a" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Profile-Token") == "proof-a" })
        let forced = await credentials.refreshCount()
        XCTAssertEqual(forced, 1)
    }

    func test_playlistChildrenStayRelayedWithoutLeakingNativeOrForeignGrants() async throws {
        let suffix = UUID().uuidString.lowercased()
        let nativeHost = "silo-relay-\(suffix).invalid"
        let edgeHost = "silo-edge-\(suffix).invalid"
        let otherHost = "silo-other-\(suffix).invalid"
        let base = URL(string: "https://\(nativeHost)/proxy/silo")!
        let master = base.appending(path: "api/v2/playback/transcode/session-a/master.m3u8")
        let foreignSegment = URL(string: "https://\(edgeHost)/segment.ts?st=a%2Bb")!
        let foreignKey = URL(string: "https://\(edgeHost)/key?st=key%2Bgrant")!
        let foreignSidecar = URL(string: "https://\(edgeHost)/sidecar.m3u8?st=side%2Bgrant")!
        let foreignSubtitle = URL(string: "https://\(edgeHost)/subtitle.vtt?st=sub%2Bgrant")!
        let otherSubtitle = URL(string: "https://\(otherHost)/subtitle.vtt?st=other%2Bgrant")!
        let fixture = SiloMediaProtocolFixture()
        for host in [nativeHost, edgeHost, otherHost] { SiloMediaFixtureProtocol.install(fixture, host: host) }
        defer { for host in [nativeHost, edgeHost, otherHost] { SiloMediaFixtureProtocol.remove(host: host) } }
        let masterBody = """
        #EXTM3U
        #EXT-X-KEY:METHOD=AES-128,URI="\(foreignKey.absoluteString)"
        #EXTINF:2,
        \(foreignSegment.absoluteString)
        """
        fixture.respond("GET", master, [.init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(masterBody.utf8))])
        fixture.respond("GET", foreignSegment, [.init(body: Data("segment".utf8))])
        fixture.respond("GET", foreignKey, [.init(body: Data("key".utf8))])
        fixture.respond("GET", foreignSidecar, [.init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data("#EXTM3U\n\(foreignSubtitle.absoluteString)\n\(otherSubtitle.absoluteString)\n".utf8))])
        fixture.respond("GET", foreignSubtitle, [.init(headers: ["Content-Type": "text/vtt"], body: Data("WEBVTT\n\n".utf8))])
        fixture.respond("GET", otherSubtitle, [.init(headers: ["Content-Type": "text/vtt"], body: Data("WEBVTT\n\n".utf8))])
        let credentials = SiloMediaCredentialFixture()
        let client = SiloClient(baseURL: base, profileID: "profile-a", profileToken: "proof-a",
                                tokenSource: { await credentials.token(force: $0) })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SiloMediaFixtureProtocol.self]
        let relay = try await SiloMediaRelay.start(client: client, configuration: configuration)
        defer { relay.stop() }
        let localMaster = try relay.localURL(for: master, headers: ["X-Plan-Grant": "native-grant", "X-Silo-Device-Id": "native-device"])
        XCTAssertEqual(localMaster.pathExtension, "m3u8")
        let localSidecar = try relay.localURL(for: foreignSidecar, headers: [
            "Authorization": "Foreign sidecar grant", "X-Profile-Id": "must-not-leak",
            "X-Silo-Device-Id": "must-not-leak", "X-Plan-Grant": "sidecar-grant"
        ])
        let consumer = URLSession(configuration: .ephemeral)
        defer { consumer.invalidateAndCancel() }
        let (masterData, _) = try await consumer.data(from: localMaster)
        let rewritten = try XCTUnwrap(String(data: masterData, encoding: .utf8))
        let segmentLine = try XCTUnwrap(rewritten.components(separatedBy: "\n").first { $0.hasPrefix("http://127.0.0.1:") })
        let segmentURL = try XCTUnwrap(URL(string: segmentLine))
        let keyLine = try XCTUnwrap(rewritten.components(separatedBy: "\n").first { $0.hasPrefix("#EXT-X-KEY:") })
        let keyValue = try XCTUnwrap(keyLine.components(separatedBy: "URI=\"").last?.split(separator: "\"").first)
        let keyURL = try XCTUnwrap(URL(string: String(keyValue)))
        let (segment, _) = try await consumer.data(from: segmentURL)
        let (key, _) = try await consumer.data(from: keyURL)
        XCTAssertEqual(segment, Data("segment".utf8))
        XCTAssertEqual(key, Data("key".utf8))
        let (sidecarData, _) = try await consumer.data(from: localSidecar)
        let sidecarText = try XCTUnwrap(String(data: sidecarData, encoding: .utf8))
        let subtitleLine = try XCTUnwrap(sidecarText.components(separatedBy: "\n").first { $0.hasPrefix("http://127.0.0.1:") })
        let subtitleURL = try XCTUnwrap(URL(string: subtitleLine))
        let (subtitle, _) = try await consumer.data(from: subtitleURL)
        XCTAssertEqual(subtitle, Data("WEBVTT\n\n".utf8))
        let otherLine = try XCTUnwrap(sidecarText.components(separatedBy: "\n").filter { $0.hasPrefix("http://127.0.0.1:") }.last)
        let otherURL = try XCTUnwrap(URL(string: otherLine))
        _ = try await consumer.data(from: otherURL)

        let requests = fixture.requests()
        let native = try XCTUnwrap(requests.first { $0.url == master })
        XCTAssertEqual(native.value(forHTTPHeaderField: "Authorization"), "Bearer initial-access")
        XCTAssertEqual(native.value(forHTTPHeaderField: "X-Plan-Grant"), "native-grant")
        XCTAssertEqual(native.value(forHTTPHeaderField: "X-Silo-Device-Id"), "native-device")
        for url in [foreignSegment, foreignKey] {
            let request = try XCTUnwrap(requests.first { $0.url == url })
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Profile-Id"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Profile-Token"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Plan-Grant"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Silo-Device-Id"))
            XCTAssertEqual(request.url?.absoluteString, url.absoluteString, "signed query bytes must remain unchanged")
        }
        for url in [foreignSidecar, foreignSubtitle] {
            let request = try XCTUnwrap(requests.first { $0.url == url })
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Foreign sidecar grant")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Profile-Id"))
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Profile-Token"))
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Plan-Grant"), "sidecar-grant")
            XCTAssertNil(request.value(forHTTPHeaderField: "X-Silo-Device-Id"))
        }
        let other = try XCTUnwrap(requests.first { $0.url == otherSubtitle })
        XCTAssertNil(other.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(other.value(forHTTPHeaderField: "X-Plan-Grant"))
        XCTAssertNil(other.value(forHTTPHeaderField: "X-Profile-Id"))
        XCTAssertNil(other.value(forHTTPHeaderField: "X-Silo-Device-Id"))
    }

    func test_stoppedRelayCannotRegisterNewCapabilities() async throws {
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid/proxy/silo")!, token: "access")
        let relay = try await SiloMediaRelay.start(client: client)
        relay.stop()
        XCTAssertThrowsError(try relay.localURL(for: URL(string: "https://silo.invalid/proxy/silo/api/v2/stream/session-a")!)) {
            XCTAssertTrue($0 is CancellationError)
        }
    }
}

private actor SiloMediaCredentialFixture {
    private var value = "initial-access"
    private var refreshes = 0
    func token(force: Bool) -> String {
        if force { value = "refreshed-access"; refreshes += 1 }
        return value
    }
    func rotate(to value: String) { self.value = value }
    func refreshCount() -> Int { refreshes }
}

private nonisolated final class SiloMediaProtocolFixture: @unchecked Sendable {
    nonisolated struct Reply: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
        init(status: Int = 200, headers: [String: String] = [:], body: Data = Data()) {
            self.status = status; self.headers = headers; self.body = body
        }
    }
    private let lock = NSLock()
    private var routes: [String: [Reply]] = [:]
    private var recorded: [URLRequest] = []
    func respond(_ method: String, _ url: URL, _ replies: [Reply]) {
        lock.withLock { routes[method + " " + url.absoluteString] = replies }
    }
    func requests() -> [URLRequest] { lock.withLock { recorded } }
    func receive(_ request: URLRequest) -> Reply? {
        lock.withLock {
            recorded.append(request)
            let key = (request.httpMethod ?? "GET") + " " + (request.url?.absoluteString ?? "")
            guard let reply = routes[key]?.first else { return nil }
            if routes[key]!.count > 1 { routes[key]!.removeFirst() }
            return reply
        }
    }
}

private nonisolated final class SiloMediaFixtureProtocol: URLProtocol, @unchecked Sendable {
    private nonisolated final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var fixtures: [String: SiloMediaProtocolFixture] = [:]
    }
    private static let registry = Registry()
    static func install(_ fixture: SiloMediaProtocolFixture, host: String) { registry.lock.withLock { registry.fixtures[host] = fixture } }
    static func remove(host: String) { _ = registry.lock.withLock { registry.fixtures.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool {
        registry.lock.withLock { request.url?.host.flatMap { registry.fixtures[$0] } != nil }
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let fixture = Self.registry.lock.withLock { request.url?.host.flatMap { Self.registry.fixtures[$0] } }
        guard let url = request.url, let reply = fixture?.receive(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        var headers = reply.headers
        if headers["Content-Length"] == nil { headers["Content-Length"] = String(reply.body.count) }
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension SiloMediaRelayTests {
    func test_nativeQueryVariableExpandsMapAndSegmentBeforeRegistration() async throws {
        let host = "silo-vars-\(UUID().uuidString.lowercased()).invalid"
        let base = URL(string: "https://\(host)/proxy/silo")!
        let master = base.appending(path: "api/v2/playback/transcode/session-a/master.m3u8")
        let query = "st=opaque%2Bsigned%2Fvalue%3D&seek=12"
        let initialization = URL(string: "segment/init.mp4?" + query, relativeTo: master)!.absoluteURL
        let segment = URL(string: "segment/seg_00000.m4s?" + query, relativeTo: master)!.absoluteURL
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:8
        #EXT-X-TARGETDURATION:2
        #EXT-X-DEFINE:NAME="silo_query",VALUE="\(query)"
        #EXT-X-MAP:URI="segment/init.mp4?{$silo_query}"
        #EXTINF:2,
        segment/seg_00000.m4s?{$silo_query}
        #EXT-X-ENDLIST
        """
        let fixture = SiloMediaProtocolFixture()
        SiloMediaFixtureProtocol.install(fixture, host: host)
        defer { SiloMediaFixtureProtocol.remove(host: host) }
        fixture.respond("GET", master, [.init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(manifest.utf8))])
        fixture.respond("GET", initialization, [.init(body: Data("init-bytes".utf8))])
        fixture.respond("GET", segment, [.init(body: Data("segment-bytes".utf8))])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SiloMediaFixtureProtocol.self]
        let client = SiloClient(baseURL: base, token: "access", profileID: "profile-a")
        let relay = try await SiloMediaRelay.start(client: client, configuration: configuration)
        defer { relay.stop() }
        let consumer = URLSession(configuration: .ephemeral)
        defer { consumer.invalidateAndCancel() }
        let (data, _) = try await consumer.data(from: relay.localURL(for: master))
        let rewritten = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(rewritten.contains("#EXT-X-DEFINE"))
        XCTAssertFalse(rewritten.contains("opaque%2Bsigned"))
        XCTAssertFalse(rewritten.contains("{$"))
        let map = try XCTUnwrap(rewritten.components(separatedBy: "\n").first { $0.hasPrefix("#EXT-X-MAP:") })
        let mapReference = try XCTUnwrap(map.components(separatedBy: "URI=\"").last?.split(separator: "\"").first)
        let mapURL = try XCTUnwrap(URL(string: String(mapReference)))
        let segmentLine = try XCTUnwrap(rewritten.components(separatedBy: "\n").first { $0.hasPrefix("http://127.0.0.1:") })
        let segmentURL = try XCTUnwrap(URL(string: segmentLine))
        let (initializationData, _) = try await consumer.data(from: mapURL)
        let (segmentData, _) = try await consumer.data(from: segmentURL)
        XCTAssertEqual(initializationData, Data("init-bytes".utf8))
        XCTAssertEqual(segmentData, Data("segment-bytes".utf8))
        let requests = fixture.requests()
        XCTAssertEqual(requests.map { $0.url?.absoluteString },
                       [master.absoluteString, initialization.absoluteString, segment.absoluteString])
    }

    func test_importAndQueryParameterUseParentScopeAndOriginalEncodedURI() async throws {
        let host = "silo-import-\(UUID().uuidString.lowercased()).invalid"
        let base = URL(string: "https://\(host)/proxy/silo")!
        let master = base.appending(path: "api/v2/playback/transcode/session-a/master.m3u8")
        let media = URL(string: "media.m3u8?part=decoded%252Bvalue", relativeTo: master)!.absoluteURL
        let noImport = URL(string: "missing-import.m3u8", relativeTo: master)!.absoluteURL
        let segment = URL(string: "segment/one.ts?st=parent%2Bgrant&part=decoded%2Bvalue", relativeTo: media)!.absoluteURL
        let manifest = """
        #EXTM3U
        #EXT-X-VERSION:11
        #EXT-X-DEFINE:NAME="auth",VALUE="st=parent%2Bgrant"
        #EXT-X-STREAM-INF:BANDWIDTH=1000
        media.m3u8?part=decoded%252Bvalue
        #EXT-X-STREAM-INF:BANDWIDTH=2000
        missing-import.m3u8
        """
        let child = """
        #EXTM3U
        #EXT-X-DEFINE:IMPORT="auth"
        #EXT-X-DEFINE:QUERYPARAM="part"
        #EXTINF:2,
        segment/one.ts?{$auth}&part={$part}
        """
        let fixture = SiloMediaProtocolFixture()
        SiloMediaFixtureProtocol.install(fixture, host: host)
        defer { SiloMediaFixtureProtocol.remove(host: host) }
        fixture.respond("GET", master, [.init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(manifest.utf8))])
        fixture.respond("GET", media, [.init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(child.utf8))])
        fixture.respond("GET", noImport, [.init(headers: ["Content-Type": "application/vnd.apple.mpegurl"],
                                               body: Data("#EXTM3U\n#EXTINF:2,\nsegment/one.ts?{$auth}\n".utf8))])
        fixture.respond("GET", segment, [.init(body: Data("imported-segment".utf8))])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SiloMediaFixtureProtocol.self]
        let relay = try await SiloMediaRelay.start(client: SiloClient(baseURL: base, token: "access"), configuration: configuration)
        defer { relay.stop() }
        let consumer = URLSession(configuration: .ephemeral)
        defer { consumer.invalidateAndCancel() }
        let (masterData, _) = try await consumer.data(from: relay.localURL(for: master))
        let masterText = try XCTUnwrap(String(data: masterData, encoding: .utf8))
        let children = masterText.components(separatedBy: "\n").filter { $0.hasPrefix("http://127.0.0.1:") }
        XCTAssertEqual(children.count, 2)
        let childURL = try XCTUnwrap(children.first.flatMap(URL.init(string:)))
        let (childData, _) = try await consumer.data(from: childURL)
        let childText = try XCTUnwrap(String(data: childData, encoding: .utf8))
        let segmentLine = try XCTUnwrap(childText.components(separatedBy: "\n").first { $0.hasPrefix("http://127.0.0.1:") })
        let (segmentData, _) = try await consumer.data(from: XCTUnwrap(URL(string: segmentLine)))
        XCTAssertEqual(segmentData, Data("imported-segment".utf8))
        XCTAssertEqual(fixture.requests().last?.url?.absoluteString, segment.absoluteString)
        let missingImportURL = try XCTUnwrap(children.last.flatMap(URL.init(string:)))
        let (missingBody, missingResponse) = try await consumer.data(from: missingImportURL)
        XCTAssertEqual((missingResponse as? HTTPURLResponse)?.statusCode, 502,
                       "parent definitions are not implicitly active without IMPORT")
        XCTAssertTrue(missingBody.isEmpty)
        // The same child loaded as an independent root must not borrow a
        // previously parsed parent's definitions from another capability.
        let (_, independentResponse) = try await consumer.data(from: relay.localURL(for: media))
        XCTAssertEqual((independentResponse as? HTTPURLResponse)?.statusCode, 502)
    }

    func test_literalFeatureFilmPlaylistOverTwoMiBLoadsItsLastSegment() async throws {
        let host = "silo-literal-\(UUID().uuidString.lowercased()).invalid"
        let base = URL(string: "https://\(host)/proxy/silo")!
        let master = base.appending(path: "api/v2/playback/transcode/session-a/master.m3u8")
        let query = "st=" + String(repeating: "signed", count: 285) + "%2Btail"
        var manifest = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n"
        for index in 0..<1_500 {
            manifest += "#EXTINF:2,\nsegment/seg_\(index).ts?\(query)\n"
        }
        manifest += "#EXT-X-ENDLIST\n"
        XCTAssertGreaterThan(manifest.utf8.count, 2 * 1_024 * 1_024)
        let finalSegment = URL(string: "segment/seg_1499.ts?" + query, relativeTo: master)!.absoluteURL
        let fixture = SiloMediaProtocolFixture()
        SiloMediaFixtureProtocol.install(fixture, host: host)
        defer { SiloMediaFixtureProtocol.remove(host: host) }
        fixture.respond("GET", master, [.init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(manifest.utf8))])
        fixture.respond("GET", finalSegment, [.init(body: Data("last-segment".utf8))])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SiloMediaFixtureProtocol.self]
        let relay = try await SiloMediaRelay.start(client: SiloClient(baseURL: base, token: "access"), configuration: configuration)
        defer { relay.stop() }
        let consumer = URLSession(configuration: .ephemeral)
        defer { consumer.invalidateAndCancel() }
        let (data, response) = try await consumer.data(from: relay.localURL(for: master))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let lastLine = try XCTUnwrap(text.components(separatedBy: "\n").last { $0.hasPrefix("http://127.0.0.1:") })
        let (lastData, lastResponse) = try await consumer.data(from: XCTUnwrap(URL(string: lastLine)))
        XCTAssertEqual((lastResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(lastData, Data("last-segment".utf8))
        XCTAssertEqual(fixture.requests().last?.url?.absoluteString, finalSegment.absoluteString)
    }

    func test_playlistAboveExplicitBoundIsRejectedWithoutPublishingChildren() async throws {
        let host = "silo-bound-\(UUID().uuidString.lowercased()).invalid"
        let base = URL(string: "https://\(host)/proxy/silo")!
        let master = base.appending(path: "api/v2/playback/transcode/session-a/master.m3u8")
        var body = Data("#EXTM3U\n#".utf8)
        body.append(Data(repeating: 120, count: SiloHLSVariables.maximumPlaylistBytes - body.count + 1))
        let fixture = SiloMediaProtocolFixture()
        SiloMediaFixtureProtocol.install(fixture, host: host)
        defer { SiloMediaFixtureProtocol.remove(host: host) }
        fixture.respond("GET", master, [.init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: body)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SiloMediaFixtureProtocol.self]
        let relay = try await SiloMediaRelay.start(client: SiloClient(baseURL: base, token: "access"), configuration: configuration)
        defer { relay.stop() }
        let consumer = URLSession(configuration: .ephemeral)
        defer { consumer.invalidateAndCancel() }
        let (data, response) = try await consumer.data(from: relay.localURL(for: master))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
        XCTAssertTrue(data.isEmpty)
        XCTAssertEqual(fixture.requests().count, 1)
    }
}

extension SiloMediaRelayTests {
    func test_compactVariableAmplificationFailsAtomicallyAndReleasesItsBudget() async throws {
        for aliases in [true, false] {
            let host = "silo-amplification-\(UUID().uuidString.lowercased()).invalid"
            let base = URL(string: "https://\(host)/proxy/silo")!
            let master = base.appending(path: "api/v2/playback/transcode/session-a/master.m3u8")
            let value = String(repeating: "x", count: aliases ? 512 : 1_024)
            var attack = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-DEFINE:NAME=\"base\",VALUE=\"\(value)\"\n"
            if aliases {
                for index in 0..<24 {
                    attack += "#EXT-X-DEFINE:NAME=\"alias_\(index)\",VALUE=\"{$base}\"\n"
                }
                attack += "#EXTINF:2,\nsegment/never.ts?st={$base}\n"
            } else {
                for index in 0..<12 {
                    attack += "#EXTINF:2,\nsegment/unique_\(index).ts?st={$base}\n"
                }
            }
            // Exercise the actual parser/HTTP failure with KiB, not a payload
            // that allocates GiB before a test can establish the regression.
            XCTAssertLessThan(attack.utf8.count, 8_192)
            var recovery = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n"
            for index in 0..<12 { recovery += "#EXTINF:2,\nsegment/recovered_\(index).ts\n" }
            recovery += "#EXT-X-ENDLIST\n"
            let finalSegment = URL(string: "segment/recovered_11.ts", relativeTo: master)!.absoluteURL
            let fixture = SiloMediaProtocolFixture()
            SiloMediaFixtureProtocol.install(fixture, host: host)
            defer { SiloMediaFixtureProtocol.remove(host: host) }
            fixture.respond("GET", master, [
                .init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(attack.utf8)),
                .init(headers: ["Content-Type": "application/vnd.apple.mpegurl"], body: Data(recovery.utf8))
            ])
            fixture.respond("GET", finalSegment, [.init(body: Data("recovered-final-segment".utf8))])
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SiloMediaFixtureProtocol.self]
            let relay = try await SiloMediaRelay.start(client: SiloClient(baseURL: base, token: "access"),
                                                       configuration: configuration, retainedByteLimit: 8_192)
            defer { relay.stop() }
            let local = try relay.localURL(for: master)
            let consumer = URLSession(configuration: .ephemeral)
            defer { consumer.invalidateAndCancel() }
            let (failedBody, failedResponse) = try await consumer.data(from: local)
            XCTAssertEqual((failedResponse as? HTTPURLResponse)?.statusCode, 502)
            XCTAssertTrue(failedBody.isEmpty, "a failed expansion must publish no child capabilities")

            // This normal manifest fits the same small aggregate budget, but
            // not if an earlier failed parse retained aliases or partial URI
            // registrations. Fetch its final child, not just the playlist text.
            let (recoveredBody, recoveredResponse) = try await consumer.data(from: local)
            XCTAssertEqual((recoveredResponse as? HTTPURLResponse)?.statusCode, 200)
            let text = try XCTUnwrap(String(data: recoveredBody, encoding: .utf8))
            let children = text.components(separatedBy: "\n").filter { $0.hasPrefix("http://127.0.0.1:") }
            XCTAssertEqual(children.count, 12)
            let last = try XCTUnwrap(children.last.flatMap(URL.init(string:)))
            let (segment, response) = try await consumer.data(from: last)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual(segment, Data("recovered-final-segment".utf8))
            XCTAssertEqual(fixture.requests().last?.url?.absoluteString, finalSegment.absoluteString)
            XCTAssertEqual(fixture.requests().count, 3)
        }
    }
}

extension SiloMediaRelayTests {
    func test_selectedArtifactUsesItsServedFormatAndAuthenticatedAbsoluteTimeline() async throws {
        let host = "silo-subtitles-\(UUID().uuidString.lowercased()).invalid"
        let base = URL(string: "https://\(host)/proxy/silo")!
        let artifact = base.appending(path: "api/v2/stream/session-a/subtitles/1.vtt")
            .appending(queryItems: [URLQueryItem(name: "file_id", value: "file-a"),
                                   URLQueryItem(name: "embedded_stream_index", value: "8")])
        let fixture = SiloMediaProtocolFixture()
        SiloMediaFixtureProtocol.install(fixture, host: host)
        defer { SiloMediaFixtureProtocol.remove(host: host) }
        let body = "WEBVTT\n\n00:01:05.000 --> 00:01:07.000\nA source-timed line\n\n"
        fixture.respond("GET", artifact, [
            .init(status: 401),
            .init(headers: ["Content-Type": "text/vtt"], body: Data(body.utf8))
        ])
        let credentials = SiloMediaCredentialFixture()
        let client = SiloClient(baseURL: base, profileID: "profile-a", profileToken: "proof-a",
                                tokenSource: { await credentials.token(force: $0) })
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SiloMediaFixtureProtocol.self]
        let relay = try await SiloMediaRelay.start(client: client, configuration: configuration)
        defer { relay.stop() }
        let provider = SiloProvider(serverID: "server-a", displayName: "Silo", profileID: "profile-a", client: client)
        let plan = try subtitlePlan(mode: "convert", route: """
        "artifact":{"url":"\(artifact.absoluteString)","mime_type":"text/vtt","format":"vtt","timing_origin_seconds":0}
        """, delivery: "server_transcode_hls")
        let tracks = try provider.planSubtitles(plan, relay: relay)
        XCTAssertEqual(tracks.map(\.index), [0, 1, 2, 3], "the picker retains authoritative combined ordinals")
        XCTAssertEqual(tracks.compactMap(\.externalURL).count, 1, "unselected inventory URLs must not trigger extraction")
        let selected = try XCTUnwrap(tracks.first(where: \.isSelected))
        XCTAssertEqual(selected.id, "file:file-a:subtitle:1")
        XCTAssertEqual(selected.codec, "vtt", "the ASS source codec does not describe the converted bytes")
        XCTAssertFalse(selected.isEmbedded)
        XCTAssertNil(selected.nativeStreamIndex)
        XCTAssertEqual(selected.externalHTTPHeaders, [:])
        let consumer = URLSession(configuration: .ephemeral)
        defer { consumer.invalidateAndCancel() }
        let (data, response) = try await consumer.data(from: XCTUnwrap(selected.externalURL))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let parsed = try VTTParser().parse(XCTUnwrap(String(data: data, encoding: .utf8)))
        XCTAssertEqual(parsed.activeCues(at: 5 + plan.timeline.timelineOffsetSeconds).map(\.text), ["A source-timed line"])
        XCTAssertTrue(parsed.activeCues(at: 5).isEmpty, "the transport must not rebase source-timed artifacts a second time")
        let requests = fixture.requests()
        XCTAssertEqual(requests.map(\.url), [artifact, artifact], "use the selected artifact, never the inventory's .ass fallback")
        XCTAssertEqual(requests.map { $0.value(forHTTPHeaderField: "Authorization") },
                       ["Bearer initial-access", "Bearer refreshed-access"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Profile-Id") == "profile-a" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Profile-Token") == "proof-a" })
    }

    func test_nativeSubtitleUsesExplicitDemuxerIdentityNotCombinedOrdinal() async throws {
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid/proxy/silo")!, token: "access")
        let relay = try await SiloMediaRelay.start(client: client)
        defer { relay.stop() }
        let provider = SiloProvider(serverID: "server-a", displayName: "Silo", profileID: "profile-a", client: client)
        let plan = try subtitlePlan(mode: "render", route: #""embedded":{"stream_index":8,"container_track_id":"42"}"#)
        let tracks = try provider.planSubtitles(plan, relay: relay)
        let selected = try XCTUnwrap(tracks.first(where: \.isSelected))
        XCTAssertEqual(selected.index, 1, "Silo replan selection remains in the combined inventory space")
        XCTAssertEqual(selected.nativeStreamIndex, 8, "Aether selection uses the explicit FFmpeg AVStream index, not container id 42")
        XCTAssertTrue(selected.isEmbedded)
        XCTAssertTrue(tracks.allSatisfy { $0.externalURL == nil }, "native selection must never mount its extracted fallback")
    }

    func test_offBurnInAndHLSRenditionKeepMenuWithoutMountingInventorySidecars() async throws {
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid/proxy/silo")!, token: "access")
        let relay = try await SiloMediaRelay.start(client: client)
        defer { relay.stop() }
        let provider = SiloProvider(serverID: "server-a", displayName: "Silo", profileID: "profile-a", client: client)
        let plans = [
            try subtitlePlan(mode: "off", selected: nil),
            try subtitlePlan(mode: "burn_in", selected: 2, delivery: "server_transcode_hls"),
            try subtitlePlan(mode: "render", route: """
            "hls_rendition":{"group_id":"subs","name":"Subtitles","format":"vtt","mime_type":"text/vtt"}
            """, delivery: "server_remux_hls")
        ]
        for plan in plans {
            let tracks = try provider.planSubtitles(plan, relay: relay)
            XCTAssertEqual(tracks.map(\.index), [0, 1, 2, 3])
            XCTAssertTrue(tracks.allSatisfy { $0.externalURL == nil && $0.nativeStreamIndex == nil })
            XCTAssertEqual(tracks.filter(\.isSelected).count, plan.subtitle.mode == "off" ? 0 : 1)
        }
    }

    func test_rejectsAmbiguousNativeDeliveryAndUnsupportedArtifactTimeline() async throws {
        let client = SiloClient(baseURL: URL(string: "https://silo.invalid/proxy/silo")!, token: "access")
        let relay = try await SiloMediaRelay.start(client: client)
        defer { relay.stop() }
        let provider = SiloProvider(serverID: "server-a", displayName: "Silo", profileID: "profile-a", client: client)
        for route in [
            #""embedded":{"stream_index":8},"artifact":{"url":"/api/v2/subtitle.vtt","mime_type":"text/vtt","format":"vtt","timing_origin_seconds":0}"#,
            #""artifact":{"url":"/api/v2/subtitle.vtt","mime_type":"text/vtt","format":"vtt","timing_origin_seconds":60}"#
        ] {
            let plan = try subtitlePlan(mode: "render", route: route)
            XCTAssertThrowsError(try provider.planSubtitles(plan, relay: relay))
        }
    }

    func test_negotiatedProgressiveStatusKeepsOpaqueQualityAndRecipeTruth() throws {
        let json = """
        {"protocol_version":3,"plan_id":"plan-a","plan_attempt_key":"opaque-key","session_id":"session-a",
         "delivery":"server_remux_progressive","effective_media_file_id":"file-a",
         "stream":{"url":"/api/v2/stream/session-a","protocol":"http_progressive","headers":{},
                   "header_refresh":"none","container":"mp4"},
         "timeline":{"source_start_seconds":0,"stream_origin_seconds":0,"player_start_seconds":0,
                     "timeline_offset_seconds":0,"can_seek_anywhere":true,"seek_restoration":"player_position"},
         "source":{"media_file_id":"file-a","duration_seconds":7200},"selected_tracks":{},
         "subtitle":{"mode":"off","inventory":[]},
         "available_qualities":[{"label":"tier:opaque/2","display_name":"Adaptive","bitrate_kbps":4000,
                                 "preserves_source":false}],
         "active_quality":"tier:opaque/2",
         "effective_recipe":{"video_codec":"h264","width":1280,"height":720,"bitrate_kbps":4000},
         "decision_reason":"bandwidth_budget","degradation_warnings":[]}
        """
        let plan = try SiloJSON.decoder().decode(SiloPlaybackPlan.self, from: Data(json.utf8))
        let status = plan.negotiatedStatus
        XCTAssertEqual(status.delivery, .progressiveRemux)
        XCTAssertEqual(status.availableQualities.map(\.id), ["tier:opaque/2"])
        XCTAssertEqual(status.activeQualityID, "tier:opaque/2")
        XCTAssertEqual(status.effectiveRecipe?.height, 720)
        XCTAssertEqual(status.effectiveRecipe?.videoCodec, "h264")
        XCTAssertEqual(status.decisionReason, "bandwidth_budget")
    }

    private func subtitlePlan(mode: String, selected: Int? = 1, route: String? = nil,
                              delivery: String = "original_http") throws -> SiloPlaybackPlan {
        let identity = selected.map { #""subtitle":{"id":"file:file-a:subtitle:\#($0)","index":\#($0)}"# } ?? ""
        let track = selected.map { #""track_id":"file:file-a:subtitle:\#($0)","# } ?? ""
        let routeField = route.map { $0 + "," } ?? ""
        let json = """
        {
          "protocol_version":3,"plan_id":"plan-a","plan_attempt_key":"attempt-a","session_id":"session-a",
          "delivery":"\(delivery)","effective_media_file_id":"file-a",
          "stream":{"url":"/api/v2/stream/session-a","protocol":"\(delivery == "original_http" ? "http_progressive" : "hls")",
                    "headers":{},"header_refresh":"none","container":"mkv"},
          "timeline":{"source_start_seconds":60,"stream_origin_seconds":0,"player_start_seconds":0,
                      "timeline_offset_seconds":60,"can_seek_anywhere":false,"seek_restoration":"server_reanchor"},
          "source":{"media_file_id":"file-a","duration_seconds":7200},"selected_tracks":{\(identity)},
          "subtitle":{"mode":"\(mode)",\(track)\(routeField)"inventory":[
            {"track_id":"file:file-a:subtitle:0","combined_index":0,"source":"external","codec":"srt",
             "forced":false,"default":false,"hearing_impaired":false,"delivery":"sidecar","url":"/api/v2/stream/session-a/subtitles/0.vtt"},
            {"track_id":"file:file-a:subtitle:1","combined_index":1,"source":"embedded","codec":"ass",
             "forced":false,"default":true,"hearing_impaired":false,"delivery":"sidecar","url":"/api/v2/stream/session-a/subtitles/1.ass"},
            {"track_id":"file:file-a:subtitle:2","combined_index":2,"source":"embedded","codec":"dvd_subtitle",
             "forced":true,"default":false,"hearing_impaired":false,"delivery":"burn_in_only"},
            {"track_id":"file:file-a:subtitle:3","combined_index":3,"source":"downloaded","codec":"srt",
             "forced":false,"default":false,"hearing_impaired":true,"delivery":"sidecar","url":"/api/v2/stream/session-a/subtitles/3.vtt"}
          ]}
        }
        """
        return try SiloJSON.decoder().decode(SiloPlaybackPlan.self, from: Data(json.utf8))
    }
}

extension SiloMediaRelayTests {
    func test_storedSubtitleActivationResolvesPinnedOpaqueRowAndReturnsOnePreparedStream() async throws {
        let host = "silo-stored-\(UUID().uuidString.lowercased()).invalid"
        let base = URL(string: "https://\(host)/proxy/silo")!
        let server = SiloAuthTestServer()
        let client = SiloClient(baseURL: base, token: "access", profileID: "profile-a", profileToken: "proof-a",
                                transport: server.transport)
        let provider = SiloProvider(serverID: "server-a", displayName: "Silo", profileID: "profile-a", client: client)
        let fixture = SiloMediaProtocolFixture()
        SiloMediaFixtureProtocol.install(fixture, host: host)
        defer { SiloMediaFixtureProtocol.remove(host: host) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SiloMediaFixtureProtocol.self]
        let relay = try await SiloMediaRelay.start(client: client, configuration: configuration)
        defer { relay.stop() }
        let (current, captured) = try storedSubtitleSession(provider: provider, relay: relay)
        let refreshed = storedSubtitlePlanJSON(planID: "refreshed")
        let selected = storedSubtitlePlanJSON(planID: "selected", selected: true)
        await server.respond("POST", "/proxy/silo/api/v2/playback/session-a/replan", [
            .init(body: #"{"protocol_version":3,"outcome":"playable","session_id":"session-a","playback_plan":\#(refreshed)}"#),
            .init(body: #"{"protocol_version":3,"outcome":"playable","session_id":"session-a","playback_plan":\#(selected)}"#)
        ])
        await server.respond("GET", "/proxy/silo/api/v2/watch/movie-a", [.init(body: """
        {"content_id":"movie-a","title":"Fixture","versions":[
          {"file_id":"file-a","resolution":"2160p","codec_video":"hevc","codec_audio":"truehd","hdr":true,
           "container":"mkv","file_size":1234,"bitrate":8000,"duration_seconds":7200,
           "audio_tracks":[{"codec":"aac","default":false},{"codec":"truehd","default":true}]}
        ]}
        """)])
        let remote = try XCTUnwrap(client.mediaURL("/api/v2/stream/session-a/subtitles/3.vtt?file_id=file-a&downloaded_subtitle_id=stored%2Brow%2F9%3Fx%3D1"))
        fixture.respond("GET", remote, [.init(headers: ["Content-Type": "text/vtt"],
                                            body: Data("WEBVTT\n\n00:01:05.000 --> 00:01:07.000\nImported line\n\n".utf8))])
        let prepared = try await provider.streamSelectingStoredSubtitle("stored+row/9?x=1", current: current, position: 65)
        XCTAssertEqual(prepared.source.id, current.source.id)
        XCTAssertEqual(prepared.source.audioTracks.first(where: \.isSelected)?.index, 1)
        XCTAssertEqual(prepared.source.subtitleTracks.first(where: \.isSelected)?.index, 3,
                       "resolve the pinned row, not the last inventory entry or a stored-row number")
        XCTAssertEqual(prepared.source.subtitleTracks.compactMap(\.externalURL).count, 1)
        let consumer = URLSession(configuration: .ephemeral)
        defer { consumer.invalidateAndCancel() }
        let local = try XCTUnwrap(prepared.source.subtitleTracks.first(where: \.isSelected)?.externalURL)
        let (bytes, response) = try await consumer.data(from: local)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let cues = try VTTParser().parse(XCTUnwrap(String(data: bytes, encoding: .utf8)))
        XCTAssertEqual(cues.activeCues(at: 65).map(\.text), ["Imported line"])
        XCTAssertEqual(fixture.requests().map(\.url), [remote])

        let requests = await server.requests()
        let posts = requests.filter { $0.httpMethod == "POST" }
        XCTAssertEqual(posts.count, 2, "the caller receives a prepared stream without a third replan")
        let expected = try XCTUnwrap(JSONSerialization.jsonObject(with: SiloJSON.encoder().encode(captured)) as? [String: Any])
        let bodies = try posts.map { try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap($0.httpBody)) as? [String: Any]) }
        for body in bodies {
            XCTAssertEqual(body["operation"] as? String, "track_change")
            XCTAssertEqual(body["position_seconds"] as? Double, 65)
            XCTAssertEqual(body["installation_id"] as? String, "installation-a")
            XCTAssertEqual(body["playback_attempt_id"] as? String, captured.playbackAttemptId)
            XCTAssertEqual(body["bandwidth_cap_kbps"] as? Int, 8000)
            XCTAssertEqual(body["client_capabilities"] as? NSDictionary, expected["client_capabilities"] as? NSDictionary)
            XCTAssertEqual(body["client_playback_context"] as? NSDictionary, expected["client_playback_context"] as? NSDictionary)
            let tracks = try XCTUnwrap(body["selected_tracks"] as? [String: Any])
            XCTAssertEqual((tracks["audio"] as? [String: Any])?["id"] as? String, "file:file-a:audio:1")
        }
        let initialTracks = try XCTUnwrap(bodies[0]["selected_tracks"] as? [String: Any])
        XCTAssertNil(initialTracks["subtitle"], "the inventory refresh preserves the current Off selection")
        let nextTracks = try XCTUnwrap(bodies[1]["selected_tracks"] as? [String: Any])
        XCTAssertEqual((nextTracks["subtitle"] as? [String: Any])?["id"] as? String, "file:file-a:subtitle:3")
        XCTAssertEqual((nextTracks["subtitle"] as? [String: Any])?["index"] as? Int, 3)
        XCTAssertEqual(bodies[1]["failed_plan_id"] as? String, "refreshed")
        XCTAssertEqual(bodies[1]["plan_attempt_key"] as? String, "refreshed-key")
        XCTAssertNotEqual(bodies[0]["replan_request_id"] as? String, bodies[1]["replan_request_id"] as? String)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Profile-Id") == "profile-a" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Profile-Token") == "proof-a" })
        XCTAssertEqual(requests.filter { $0.httpMethod == "GET" }.count, 1)
    }

    func test_storedSubtitleActivationRefusesMissingOrAmbiguousPinnedRowsWithoutGuessing() async throws {
        for (target, other) in [("unrelated", "other"), ("stored%2Brow%2F9%3Fx%3D1", "stored%2Brow%2F9%3Fx%3D1")] {
            let server = SiloAuthTestServer()
            let client = SiloClient(baseURL: URL(string: "https://silo.invalid/proxy/silo")!,
                                    token: "access", profileID: "profile-a", transport: server.transport)
            let provider = SiloProvider(serverID: "server-a", displayName: "Silo", profileID: "profile-a", client: client)
            let relay = try await SiloMediaRelay.start(client: client)
            defer { relay.stop() }
            let (current, _) = try storedSubtitleSession(provider: provider, relay: relay)
            let refreshed = storedSubtitlePlanJSON(planID: "refreshed", targetPin: target, otherPin: other)
            await server.respond("POST", "/proxy/silo/api/v2/playback/session-a/replan", [
                .init(body: #"{"protocol_version":3,"outcome":"playable","session_id":"session-a","playback_plan":\#(refreshed)}"#)
            ])
            do {
                _ = try await provider.streamSelectingStoredSubtitle("stored+row/9?x=1", current: current, position: 65)
                XCTFail("A stored row without one exact authoritative identity must not select an ordinal.")
            } catch {
                XCTAssertTrue(error is MediaProviderError)
            }
            let requests = await server.requests()
            XCTAssertEqual(requests.count, 1, "no guessed selection, source restart, or artifact fetch")
        }
    }

    private func storedSubtitleSession(provider: SiloProvider, relay: SiloMediaRelay) throws -> (StreamInfo, SiloPlaybackStart) {
        let hdr = SiloHDRCapabilities(hdr10: true, hdr10Plus: false, hlg: true, dolbyVisionProfiles: [5, 7, 8])
        let codec = SiloCodecCapabilities(codecsVideo: ["hevc"], codecsVideoHardware: ["hevc"], codecsAudio: ["truehd"],
                                          containers: ["mkv"], hdr: true, hdrDetails: hdr)
        let subtitles = SiloSubtitleCapabilities(embeddedText: false, sidecarText: true, assStyling: true,
                                                 embeddedBitmap: false, fontAttachments: false)
        let delivery = SiloDeliveryCapabilities(containers: ["mkv"], videoCodecs: ["hevc"], audioDecodeCodecs: ["truehd"],
                                                subtitles: subtitles, validatedClaims: ["client_selected_audio_track_v1"], hdrDetails: hdr)
        let playback = SiloPlaybackContext(appVersion: "test", appBuild: "98",
                                           device: SiloDeviceContext(model: "Apple TV", osVersion: "26"),
                                           output: SiloOutputContext(hdrDetails: hdr), deliveries: ["original_http": delivery])
        let request = SiloPlaybackStart(installationId: "installation-a", fileId: "file-a", profileId: "profile-a",
                                        playbackAttemptId: "playback-attempt-a", clientCapabilities: codec,
                                        clientPlaybackContext: playback, allowAlternateVersions: false, startPosition: 60,
                                        bandwidthCapKbps: 8000, audioTrackId: "file:file-a:audio:1", audioTrackIndex: 1,
                                        subtitleTrackId: nil, subtitleTrackIndex: nil)
        let plan = try SiloJSON.decoder().decode(SiloPlaybackPlan.self, from: Data(storedSubtitlePlanJSON(planID: "initial").utf8))
        let source = MediaSource(id: "file-a", container: "mkv", duration: 7200, bitrate: 8_000_000,
                                 fileSize: 1234, fileName: nil, videoResolution: "2160p", videoTracks: [],
                                 audioTracks: [], subtitleTracks: [], streamKind: .directPlay, streamURL: nil)
        let ref = MediaItemRef(providerID: provider.id, itemID: "movie-a")
        provider.playbackSessions.withLock {
            $0["session-a"] = SiloPlaybackSession(installationID: "installation-a", sessionID: "session-a", fileID: "file-a",
                                                   timelineOffset: 0, ref: ref, request: request, plan: plan,
                                                   lifetime: SiloPlaybackLifetime(), relay: relay)
        }
        return (StreamInfo(source: source, playSessionID: "session-a", trackInfoAvailable: true), request)
    }

    private func storedSubtitlePlanJSON(planID: String, selected: Bool = false,
                                        targetPin: String = "stored%2Brow%2F9%3Fx%3D1", otherPin: String = "other") -> String {
        let selectedTrack = selected ? #","subtitle":{"id":"file:file-a:subtitle:3","index":3}"# : ""
        let route = selected ? """
        ,"track_id":"file:file-a:subtitle:3","artifact":{"url":"/api/v2/stream/session-a/subtitles/3.vtt?file_id=file-a&downloaded_subtitle_id=\(targetPin)",
        "mime_type":"text/vtt","format":"vtt","timing_origin_seconds":0}
        """ : ""
        return """
        {"protocol_version":3,"plan_id":"\(planID)","plan_attempt_key":"\(planID)-key","session_id":"session-a",
         "delivery":"original_http","effective_media_file_id":"file-a",
         "stream":{"url":"/api/v2/stream/session-a","protocol":"http_progressive","headers":{},"header_refresh":"none","container":"mkv"},
         "timeline":{"source_start_seconds":0,"stream_origin_seconds":0,"player_start_seconds":65,
                     "timeline_offset_seconds":0,"can_seek_anywhere":true,"seek_restoration":"player_position"},
         "source":{"media_file_id":"file-a","duration_seconds":7200},
         "selected_tracks":{"audio":{"id":"file:file-a:audio:1","index":1}\(selectedTrack)},
         "subtitle":{"mode":"\(selected ? "render" : "off")"\(route),"inventory":[
           {"track_id":"file:file-a:subtitle:0","combined_index":0,"source":"external","codec":"srt",
            "forced":false,"default":false,"hearing_impaired":false,"delivery":"sidecar","url":"/api/v2/stream/session-a/subtitles/0.vtt"},
           {"track_id":"file:file-a:subtitle:1","combined_index":1,"source":"embedded","codec":"ass",
            "forced":false,"default":false,"hearing_impaired":false,"delivery":"sidecar","url":"/api/v2/stream/session-a/subtitles/1.ass"},
           {"track_id":"file:file-a:subtitle:2","combined_index":2,"source":"embedded","codec":"dvd_subtitle",
            "forced":false,"default":false,"hearing_impaired":false,"delivery":"burn_in_only"},
           {"track_id":"file:file-a:subtitle:3","combined_index":3,"source":"downloaded","codec":"srt",
            "forced":false,"default":false,"hearing_impaired":false,"delivery":"sidecar",
            "url":"/api/v2/stream/session-a/subtitles/3.vtt?file_id=file-a&downloaded_subtitle_id=\(targetPin)"},
           {"track_id":"file:file-a:subtitle:4","combined_index":4,"source":"downloaded","codec":"srt",
            "forced":false,"default":false,"hearing_impaired":false,"delivery":"sidecar",
            "url":"/api/v2/stream/session-a/subtitles/4.vtt?file_id=file-a&downloaded_subtitle_id=\(otherPin)"}
         ]}}
        """
    }
}

extension SiloMediaRelayTests {
    func test_bufferingObservationRejectsUnmeasuredAndOutOfRangeEvidence() throws {
        XCTAssertThrowsError(try SiloBufferingObservation(estimateKbps: 99, source: .probe))
        XCTAssertThrowsError(try SiloBufferingObservation(estimateKbps: 1_000_001, source: .observedRebuffer))
        XCTAssertThrowsError(try SiloBufferingObservation(estimateKbps: 4_000, source: .probe,
                                                           observedThroughputKbps: 3_000))
        let observed = try SiloBufferingObservation(estimateKbps: 4_000, source: .observedRebuffer,
                                                     observedThroughputKbps: 3_000)
        XCTAssertEqual(observed.source.rawValue, "observed_rebuffer")
        XCTAssertEqual(observed.observedThroughputKbps, 3_000)
    }

    func test_renewalClassificationNeverResurrectsAdministratorEndedSession() throws {
        func problem(_ status: Int, _ code: String) throws -> SiloAPIError {
            try SiloJSON.decoder().decode(SiloAPIError.self, from: Data("""
            {"type":"https://silo.invalid/problems/\(code)","title":"Synthetic","status":\(status),"detail":"Synthetic"}
            """.utf8))
        }
        XCTAssertFalse(SiloPlaybackSessionRenewal.permitsFreshAttempt(after: try problem(410, "playback_session_ended")))
        XCTAssertFalse(SiloPlaybackSessionRenewal.permitsFreshAttempt(after: try problem(409, "replan_in_progress")))
        XCTAssertTrue(SiloPlaybackSessionRenewal.permitsFreshAttempt(after: try problem(404, "session_not_found")))
        XCTAssertTrue(SiloPlaybackSessionRenewal.permitsFreshAttempt(after: try problem(409, "installation_changed")))
    }
}
