// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

//
//  StreamHeaderProbeTests.swift
//  RivuletTests
//
//  Reading a stream's picture height and audio channels from its first bytes,
//  on transport streams built here packet by packet, and HLS playlists.
//

import XCTest
@testable import Rivulet

final class StreamHeaderProbeTests: XCTestCase {
    // MARK: Building a stream

    private struct BitWriter {
        var bits: [Int] = []
        mutating func put(_ value: Int, _ count: Int) { for i in (0..<count).reversed() { bits.append((value >> i) & 1) } }
        mutating func ue(_ value: Int) {
            let code = value + 1
            let length = Int(log2(Double(code)))
            put(0, length)
            put(code, length + 1)
        }
        var bytes: [UInt8] {
            var padded = bits + [1]
            while padded.count % 8 != 0 { padded.append(0) }
            return stride(from: 0, to: padded.count, by: 8).map { start in
                UInt8(padded[start..<start + 8].reduce(0) { $0 << 1 | $1 })
            }
        }
    }

    /// An H.264 SPS for 1920x1080: 1088 lines of macroblocks, 8 cropped off the bottom.
    private func h264SPS(profile: Int) -> [UInt8] {
        var w = BitWriter()
        w.put(profile, 8); w.put(0, 8); w.put(40, 8); w.ue(0)
        if profile == 100 { w.ue(1); w.ue(0); w.ue(0); w.put(0, 1); w.put(0, 1) }
        w.ue(0); w.ue(2); w.ue(1); w.put(0, 1)
        w.ue(119); w.ue(67); w.put(1, 1); w.put(1, 1)
        w.put(1, 1); w.ue(0); w.ue(0); w.ue(0); w.ue(4)
        w.put(0, 1)
        return [0x00, 0x00, 0x00, 0x01, 0x67] + w.bytes
    }

    private func packet(pid: Int, unitStart: Bool, _ payload: [UInt8]) -> [UInt8] {
        let header: [UInt8] = [0x47, UInt8((unitStart ? 0x40 : 0) | (pid >> 8)), UInt8(pid & 0xFF), 0x10]
        let body = Array(payload.prefix(184))
        return header + body + Array(repeating: 0xFF, count: 184 - body.count)
    }

    private func pes(streamID: UInt8, _ data: [UInt8]) -> [UInt8] {
        [0x00, 0x00, 0x01, streamID, 0x00, 0x00, 0x80, 0x80, 0x05, 0x21, 0x00, 0x01, 0x00, 0x01] + data
    }

    /// PAT, a PMT listing `streams` (type, pid, descriptors), then one PES per stream.
    private func transportStream(_ streams: [(type: UInt8, pid: Int, descriptors: [UInt8], pes: [UInt8])]) -> Data {
        let pat: [UInt8] = [0x00, 0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xE1, 0x00, 0, 0, 0, 0]
        var entries: [UInt8] = []
        for stream in streams {
            entries += [stream.type, UInt8(0xE0 | (stream.pid >> 8)), UInt8(stream.pid & 0xFF),
                        0xF0, UInt8(stream.descriptors.count)] + stream.descriptors
        }
        let length = 9 + entries.count + 4
        let pmt: [UInt8] = [0x00, 0x02, 0xB0, UInt8(length), 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1, 0x01, 0xF0, 0x00]
            + entries + [0, 0, 0, 0]
        var bytes = packet(pid: 0, unitStart: true, pat) + packet(pid: 0x100, unitStart: true, pmt)
        for stream in streams { bytes += packet(pid: stream.pid, unitStart: true, stream.pes) }
        return Data(bytes)
    }

    // MARK: Transport stream

    func test_h264_andAAC() {
        let adts: [UInt8] = [0xFF, 0xF1, 0x50, 0x80, 0x2E, 0x7F, 0xFC]
        for profile in [66, 100] {
            let ts = transportStream([(0x1B, 0x101, [], pes(streamID: 0xE0, h264SPS(profile: profile))),
                                      (0x0F, 0x102, [], pes(streamID: 0xC0, adts + Array(repeating: 0, count: 16)))])
            XCTAssertEqual(StreamHeaderProbe.transportStream(ts), .init(height: 1080, audioChannels: 2), "profile \(profile)")
        }
    }

    func test_mpeg2_andAC3InADVBPrivateStream() {
        // 720x576 sequence header; AC-3 3/2 with LFE: 5.1.
        let sequence: [UInt8] = [0x00, 0x00, 0x01, 0xB3, 0x2D, 0x02, 0x40, 0x33]
        let ac3: [UInt8] = [0x0B, 0x77, 0x00, 0x00, 0x10, 0x40, 0xEB, 0x00, 0x00, 0x00, 0x00, 0x00]
        let ts = transportStream([(0x02, 0x101, [], pes(streamID: 0xE0, sequence)),
                                  (0x06, 0x102, [0x6A, 0x01, 0x00], pes(streamID: 0xBD, ac3))])
        XCTAssertEqual(StreamHeaderProbe.transportStream(ts), .init(height: 576, audioChannels: 6))
    }

    func test_partOrNothing() {
        let video = transportStream([(0x1B, 0x101, [], pes(streamID: 0xE0, h264SPS(profile: 66)))])
        XCTAssertEqual(StreamHeaderProbe.transportStream(video), .init(height: 1080, audioChannels: nil))
        XCTAssertEqual(StreamHeaderProbe.transportStream(Data("<html>no</html>".utf8)), .init())
    }

    // MARK: HLS

    func test_masterPlaylist_bestVariant_andAudioChannels() {
        let master = """
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Main",CHANNELS="6"
            #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,AUDIO="aac"
            720.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,AUDIO="aac"
            1080.m3u8
            """
        XCTAssertEqual(StreamHeaderProbe.playlist(master), .init(height: 1080, audioChannels: 6))
        XCTAssertEqual(StreamHeaderProbe.firstURI(in: master, base: URL(string: "http://p.example/live/1/index.m3u8")!),
                       URL(string: "http://p.example/live/1/720.m3u8"))
        XCTAssertEqual(StreamHeaderProbe.playlist("#EXTM3U\n#EXTINF:6,\nseg1.ts"), .init())
    }

    // MARK: Prober

    @MainActor
    func test_prober_measuresOnlyUnknownPlaylistChannels_andStopsWhenAsked() async {
        let defaults = UserDefaults(suiteName: "StreamHeaderProbeTests-\(UUID().uuidString)")!
        let store = LiveStreamQualityStore(defaults: defaults)
        store.record(channelId: "x:known", height: 720, audioChannels: 2)
        store.record(channelId: "x:soundOnly", height: nil, audioChannels: 6)
        let asked = Asked()
        let prober = LiveStreamProber(store: store) { url, _ in
            await asked.add(url.lastPathComponent)
            return .init(height: 1080, audioChannels: 2)
        }
        func channel(_ id: String, _ type: LiveTVSourceType) -> UnifiedChannel {
            UnifiedChannel(id: id, sourceType: type, sourceId: "s", name: id, streamURL: URL(string: "http://p.example/\(id)"))
        }
        prober.probe([channel("x:known", .xtream), channel("x:new", .xtream), channel("p:tuner", .plex),
                      channel("x:soundOnly", .xtream)]) { true }
        for _ in 0..<150 where store.quality(for: "x:soundOnly")?.height == nil { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(store.quality(for: "x:new")?.labels, ["1080p", "Stereo"])
        let urls = await asked.urls
        XCTAssertEqual(urls, ["x:new", "x:soundOnly"], "a known channel is not asked again, and a Plex tuner never")
        XCTAssertEqual(store.quality(for: "x:soundOnly")?.labels, ["1080p", "Stereo"])

        prober.probe([channel("x:later", .xtream)]) { false }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(store.quality(for: "x:later"), "nothing is opened while the page says something plays")
    }
}

private actor Asked {
    var urls: [String] = []
    func add(_ url: String) { urls.append(url) }
}
