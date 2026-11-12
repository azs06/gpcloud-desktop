import Foundation

/// Download with real progress. The async `URLSession.download(from:delegate:)` doesn't deliver
/// `didWriteData` to per-task delegates, so this uses a session-level delegate.
public final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public static let shared = Downloader()

    private struct Pending {
        let continuation: CheckedContinuation<URL, Error>
        let progress: ((Double) -> Void)?
        var movedTo: URL?
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    /// Downloads `url` to a temporary file that the caller owns (move it somewhere).
    public func download(_ url: URL, progress: ((Double) -> Void)? = nil) async throws -> URL {
        let task = session.downloadTask(with: url)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { c in
                lock.lock(); pending[task.taskIdentifier] = Pending(continuation: c, progress: progress); lock.unlock()
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock(); let cb = pending[downloadTask.taskIdentifier]?.progress; lock.unlock()
        cb?(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // `location` is deleted when this returns, so move it now.
        let code = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { return }
        let keep = FileManager.default.temporaryDirectory.appendingPathComponent("gpcloud-dl-\(UUID().uuidString)")
        if (try? FileManager.default.moveItem(at: location, to: keep)) != nil {
            lock.lock(); pending[downloadTask.taskIdentifier]?.movedTo = keep; lock.unlock()
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let p = pending.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let p else { return }
        if let error {
            if let moved = p.movedTo { try? FileManager.default.removeItem(at: moved) }
            p.continuation.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
        } else if let moved = p.movedTo {
            p.continuation.resume(returning: moved)
        } else {
            let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
            p.continuation.resume(throwing: GPCloudError.http(code, "download failed"))
        }
    }
}
