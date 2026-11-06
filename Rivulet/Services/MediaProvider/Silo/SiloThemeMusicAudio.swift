import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// A signed grant is kept only in memory. This output never changes the app audio session.
@MainActor
final class SiloThemeMusicAudio {
    nonisolated static let maximumConvertedBytes = 32 * 1024 * 1024
    var onFailure: (() -> Void)?
    var loop: Bool

    private let grant: SiloThemeMusicGrant
    private var player: AVPlayer?
    private var item: AVPlayerItem?
    private var loader: SiloThemeMemoryLoader?
    private var download: Task<Data?, Never>?
    private var observers: [NSObjectProtocol] = []
    private var statusObservation: NSKeyValueObservation?
    private var stopped = false

    init(grant: SiloThemeMusicGrant, loop: Bool) {
        self.grant = grant
        self.loop = loop
    }

    func start() async {
        guard !stopped else { return }
        if grant.converted {
            let url = grant.url
            let task = Task { await Self.downloadConverted(url) }
            download = task
            guard let data = await task.value, !stopped, !Task.isCancelled else {
                if !stopped { fail() }
                return
            }
            let source = SiloThemeMemoryLoader(data: data)
            loader = source
            attach(AVPlayerItem(asset: source.asset))
        } else {
            attach(AVPlayerItem(url: grant.url))
        }
    }

    private func attach(_ next: AVPlayerItem) {
        guard !stopped else { return }
        item = next
        let audio = AVPlayer(playerItem: next)
        audio.allowsExternalPlayback = false
        player = audio
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: next, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.item === next else { return }
                if self.loop { audio.seek(to: .zero); audio.play() }
                else { self.stop() }
            }
        })
        observers.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: next, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.fail() }
        })
        statusObservation = next.observe(\.status) { [weak self] observed, _ in
            guard observed.status == .failed else { return }
            Task { @MainActor [weak self] in self?.fail() }
        }
        audio.play()
    }

    private func fail() {
        guard !stopped else { return }
        onFailure?()
        stop()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        download?.cancel()
        download = nil
        statusObservation = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        item = nil
        loader?.invalidate()
        loader = nil
        onFailure = nil
    }

    /// A converted stream has no length or byte ranges; hold at most 32 MiB and never cache it on disk.
    private nonisolated static func downloadConverted(_ url: URL) async -> Data? {
        let session = URLSession(configuration: .ephemeral, delegate: SiloThemeNoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  response.url == url else { return nil }
            if response.expectedContentLength > Int64(maximumConvertedBytes) { return nil }
            var result = Data()
            result.reserveCapacity(256 * 1024)
            var chunk = [UInt8]()
            chunk.reserveCapacity(64 * 1024)
            for try await byte in bytes {
                try Task.checkCancellation()
                chunk.append(byte)
                if chunk.count == 64 * 1024 {
                    guard result.count <= maximumConvertedBytes - chunk.count else { return nil }
                    result.append(contentsOf: chunk)
                    chunk.removeAll(keepingCapacity: true)
                }
            }
            guard result.count <= maximumConvertedBytes - chunk.count else { return nil }
            result.append(contentsOf: chunk)
            return result.isEmpty ? nil : result
        } catch { return nil }
    }
}

/// A complete converted fMP4 in memory, exposed as a seekable local asset.
final class SiloThemeMemoryLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let asset: AVURLAsset
    private let data: Data
    private let queue = DispatchQueue(label: "org.rivulet.silo.theme-memory")
    private var active = true

    init(data: Data) {
        self.data = data
        asset = AVURLAsset(url: URL(string: "rivulet-theme-memory://audio/theme.m4a")!)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    static func bounds(requestedStart: Int64, current: Int64, length: Int,
                       count: Int, toEnd: Bool) -> Range<Int>? {
        guard count >= 0, requestedStart >= 0, current >= requestedStart,
              requestedStart <= Int64(count), current <= Int64(count), length >= 0 else { return nil }
        let start = Int(requestedStart)
        let upper = toEnd ? count : start + min(length, count - start)
        let lower = Int(current)
        guard lower <= upper else { return nil }
        return lower..<upper
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard active else { request.finishLoading(with: URLError(.cancelled)); return true }
        if let info = request.contentInformationRequest {
            info.contentType = UTType.mpeg4Audio.identifier
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = true
        }
        if let read = request.dataRequest {
            guard let bounds = Self.bounds(requestedStart: read.requestedOffset,
                                           current: max(read.currentOffset, read.requestedOffset),
                                           length: read.requestedLength,
                                           count: data.count, toEnd: read.requestsAllDataToEndOfResource) else {
                request.finishLoading(with: URLError(.badServerResponse))
                return true
            }
            read.respond(with: data.subdata(in: bounds))
        }
        request.finishLoading()
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        didCancel request: AVAssetResourceLoadingRequest) {
        // Requests are fulfilled synchronously on the delegate queue.
    }

    func invalidate() {
        queue.sync { self.active = false }
    }
}

private final class SiloThemeNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
