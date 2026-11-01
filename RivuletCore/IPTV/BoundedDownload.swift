// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright (C) 2025-2026 Bain Gurley

import Foundation

/// Downloads a playlist or guide into memory, giving up past `limit` bytes.
/// Counted after URLSession's transparent decompression, so a gzip-encoded
/// body that inflates to gigabytes stops at the cap instead of the app.
nonisolated enum BoundedDownload {
    static let playlistLimit = 256 << 20
    static let guideLimit = 512 << 20

    struct TooLarge: LocalizedError {
        var errorDescription: String? { "The download is too large." }
    }

    /// `credential` answers a Basic or Digest challenge once; a refused login
    /// comes back as its status rather than a thrown error.
    static func data(for request: URLRequest, limit: Int,
                     configuration: URLSessionConfiguration = .default,
                     credential: URLCredential? = nil) async throws -> (Data, URLResponse) {
        let loader = Loader(limit: limit, credential: credential)
        let session = URLSession(configuration: configuration, delegate: loader, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.dataTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loader.start(task, continuation: continuation)
            }
        } onCancel: {
            task.cancel()
        }
    }

    private final class Loader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let limit: Int
        private let credential: URLCredential?
        private let lock = NSLock()
        private var data = Data()
        private var tooLarge = false
        private var continuation: CheckedContinuation<(Data, URLResponse), Error>?

        init(limit: Int, credential: URLCredential?) {
            self.limit = limit
            self.credential = credential
        }

        func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
            lock.withLock { self.continuation = continuation }
            task.resume()
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            if response.expectedContentLength > limit {
                lock.withLock { tooLarge = true }
                completionHandler(.cancel)
            } else {
                completionHandler(.allow)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            let method = challenge.protectionSpace.authenticationMethod
            if let credential, challenge.previousFailureCount == 0,
               method == NSURLAuthenticationMethodHTTPBasic || method == NSURLAuthenticationMethodHTTPDigest {
                completionHandler(.useCredential, credential)
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive chunk: Data) {
            let over = lock.withLock {
                data.append(chunk)
                if data.count > limit { tooLarge = true }
                return tooLarge
            }
            if over { dataTask.cancel() }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            let (continuation, body, tooLarge) = lock.withLock {
                defer { self.continuation = nil; data = Data() }
                return (self.continuation, data, self.tooLarge)
            }
            if tooLarge {
                continuation?.resume(throwing: TooLarge())
            } else if let error {
                continuation?.resume(throwing: error)
            } else if let response = task.response {
                continuation?.resume(returning: (body, response))
            } else {
                continuation?.resume(throwing: URLError(.badServerResponse))
            }
        }
    }
}
