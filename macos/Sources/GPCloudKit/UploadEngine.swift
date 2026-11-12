import Foundation

/// Runs the GP Cloud upload protocol for a single file:
///   1. hash locally (sha256, per-slice midstates, proofCode)
///   2. POST files/create-file-meta  → fileId + presigned OBS PUT URL per slice (or rapidUpload)
///   3. PUT each slice to its uploadUrl (application/octet-stream)
///   4. GET files/complete-status/{fileId}
public final class UploadEngine: @unchecked Sendable {
    public enum Phase: Sendable { case hashing(Double), uploading(Double), finishing, done(fileId: String, rapid: Bool) }

    private let api: GPCloudAPI
    private let session: URLSession

    public init(api: GPCloudAPI) {
        self.api = api
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 60 * 60 * 6
        cfg.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: cfg)
    }

    public func upload(fileURL: URL, to parentId: String, cloudUserId: String,
                       onPhase: @escaping @Sendable (Phase) -> Void) async throws -> String {
        onPhase(.hashing(0))
        let flag = CancelFlag()
        let plan = try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try UploadPlanner.makePlan(for: fileURL, cloudUserId: cloudUserId,
                                           isCancelled: { flag.isSet }) { p in onPhase(.hashing(p)) }
            }.value
        } onCancel: { flag.set() }
        try Task.checkCancellation()

        let meta = try await api.createFileMeta(plan: plan, parentId: parentId)
        guard let fileId = meta.fileId else { throw GPCloudError.api("Server didn't return a file id") }

        if meta.rapidUpload == true {
            // Server already has these bytes (dedup); nothing to PUT.
            onPhase(.finishing)
            try? await api.completeUpload(fileId: fileId)
            onPhase(.done(fileId: fileId, rapid: true))
            return fileId
        }
        guard let serverParts = meta.multiParts, !serverParts.isEmpty else {
            throw GPCloudError.api("Server didn't return upload slots for \(plan.fileName)")
        }

        let parts = serverParts.sorted { ($0.partNumber ?? 0) < ($1.partNumber ?? 0) }
        let progress = ProgressTracker(total: plan.totalSize) { onPhase(.uploading($0)) }
        let maxConcurrent = plan.slices.first.map { $0.size >= 50 * 1_048_576 ? 1 : 3 } ?? 3

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = parts.makeIterator()
            var running = 0
            func addNext() -> Bool {
                guard let part = iterator.next() else { return false }
                group.addTask { [self] in try await self.putPart(part, fileURL: fileURL, progress: progress) }
                return true
            }
            while running < maxConcurrent, addNext() { running += 1 }
            while try await group.next() != nil {
                if !addNext() { running -= 1 }
            }
        }

        onPhase(.finishing)
        try await api.completeUpload(fileId: fileId)
        onPhase(.done(fileId: fileId, rapid: false))
        return fileId
    }

    private func putPart(_ part: CreateFileMetaResult.Part, fileURL: URL, progress: ProgressTracker) async throws {
        guard let urlString = part.uploadUrl, let url = URL(string: urlString),
              let offset = part.partOffset, let size = part.partSize else {
            throw GPCloudError.api("Malformed upload slice from server")
        }
        let body: Data = try {
            let h = try FileHandle(forReadingFrom: fileURL)
            defer { try? h.close() }
            try h.seek(toOffset: UInt64(offset))
            return try h.read(upToCount: Int(size)) ?? Data()
        }()
        guard body.count == Int(size) else { throw GPCloudError.api("File changed while uploading") }

        var lastError: Error?
        for attempt in 0..<4 {
            try Task.checkCancellation()
            if attempt > 0 { try await Task.sleep(nanoseconds: UInt64(attempt * attempt) * 1_000_000_000) }
            var req = URLRequest(url: url)
            req.httpMethod = "PUT"
            req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let partNo = part.partNumber ?? 0
            progress.set(part: partNo, sent: 0)
            let delegate = PartProgressDelegate { sent in progress.set(part: partNo, sent: sent) }
            do {
                let (data, response) = try await session.upload(for: req, from: body, delegate: delegate)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                if (200..<300).contains(code) {
                    progress.set(part: partNo, sent: size)
                    return
                }
                let text = String(data: data.prefix(300), encoding: .utf8) ?? ""
                lastError = GPCloudError.http(code, text)
                if (400..<500).contains(code) && code != 408 && code != 429 { break }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? GPCloudError.api("Upload failed")
    }
}

private final class ProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var perPart: [Int: Int64] = [:]
    private let total: Int64
    private let report: (Double) -> Void
    private var lastReported: Double = -1

    init(total: Int64, report: @escaping (Double) -> Void) { self.total = total; self.report = report }

    func set(part: Int, sent: Int64) {
        lock.lock()
        perPart[part] = sent
        let fraction = total > 0 ? Double(perPart.values.reduce(0, +)) / Double(total) : 1
        let shouldReport = fraction - lastReported >= 0.005 || fraction >= 1
        if shouldReport { lastReported = fraction }
        lock.unlock()
        if shouldReport { report(min(1, fraction)) }
    }
}

private final class PartProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let onSent: (Int64) -> Void
    init(onSent: @escaping (Int64) -> Void) { self.onSent = onSent }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        onSent(totalBytesSent)
    }
}

final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}
