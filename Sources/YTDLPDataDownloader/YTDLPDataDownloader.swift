import Foundation

public actor ProgressTracker {
    var downloaded: Int64 = 0
    let total: Int64
    let startTime = Date()

    public init(total: Int64) {
        self.total = total
    }

    public func update(by count: Int64) -> (downloaded: Int64, speed: Double, remaining: Double) {
        downloaded += count
        let elapsed = max(Date().timeIntervalSince(startTime), 0.001)
        let speed = Double(downloaded) / elapsed
        let remaining = speed > 0 ? Double(total - downloaded) / speed : 0
        return (downloaded, speed, remaining)
    }
}

public struct YTDLPDownloadError: Error, LocalizedError {
    public enum Stage: String {
        case rangeCheckHead = "range_check_head"
        case rangeCheckProbe = "range_check_probe"
        case directDownload = "direct_download"
        case rangeDownload = "range_download"
    }

    public enum Kind: String {
        case transport
        case httpStatus = "http_status"
        case invalidResponse = "invalid_response"
        case invalidContentRange = "invalid_content_range"
        case unexpectedContentLength = "unexpected_content_length"
    }

    public let stage: Stage
    public let kind: Kind
    public let url: URL
    public let statusCode: Int?
    public let attempt: Int
    public let underlyingErrorDomain: String?
    public let underlyingErrorCode: Int?
    public let details: String?

    public var shouldRefreshSource: Bool {
        guard let statusCode else { return false }
        return statusCode == 401 || statusCode == 403 || statusCode == 410
    }

    public var errorDescription: String? {
        var components = ["YTDLP download failed", "stage=\(stage.rawValue)", "kind=\(kind.rawValue)"]
        if let statusCode {
            components.append("status=\(statusCode)")
        }
        components.append("attempt=\(attempt)")
        if let underlyingErrorDomain, let underlyingErrorCode {
            components.append("error=\(underlyingErrorDomain):\(underlyingErrorCode)")
        }
        if let details, !details.isEmpty {
            components.append("details=\(details)")
        }
        return components.joined(separator: " ")
    }
}

public final class YTDLPDataDownloader {
    public let url: URL
    public let destination: URL
    public let requestHeaders: [String: String]
    public let maxThreads: Int
    public let retryCount: Int

    typealias RetryDelay = (_ failedAttempt: Int) async throws -> Void

    private static let defaultUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    private let session: URLSession
    private let retryDelay: RetryDelay

    public init(
        url: URL,
        destination: URL,
        headers: [String: String] = [:],
        maxThreads: Int = 4,
        retryCount: Int = 3
    ) {
        self.url = url
        self.destination = destination
        self.requestHeaders = headers
        self.maxThreads = maxThreads
        self.retryCount = max(1, retryCount)

        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = true
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: config)
        self.retryDelay = Self.defaultRetryDelay
    }

    public convenience init(
        request: URLRequest,
        destination: URL,
        maxThreads: Int = 4,
        retryCount: Int = 3
    ) {
        guard let url = request.url else {
            preconditionFailure("YTDLPDataDownloader requires a request URL")
        }
        self.init(
            url: url,
            destination: destination,
            headers: request.allHTTPHeaderFields ?? [:],
            maxThreads: maxThreads,
            retryCount: retryCount
        )
    }

    init(
        url: URL,
        destination: URL,
        headers: [String: String] = [:],
        maxThreads: Int = 4,
        retryCount: Int = 3,
        session: URLSession,
        retryDelay: @escaping RetryDelay
    ) {
        self.url = url
        self.destination = destination
        self.requestHeaders = headers
        self.maxThreads = maxThreads
        self.retryCount = max(1, retryCount)
        self.session = session
        self.retryDelay = retryDelay
    }

    public func start(progress: ((Int64, Int64, Double, Double) -> Void)? = nil) async throws {
        switch try await downloadStrategy() {
        case .direct(let prefetched):
            if let prefetched {
                try writeDirectDownload(prefetched.data, response: prefetched.response, progress: progress)
            } else {
                try await directDownload(progress: progress)
            }
        case .ranged(let totalSize):
            let isGoogleVideo = url.host?.contains("googlevideo.com") == true
            let requestedThreads = isGoogleVideo ? 1 : maxThreads
            let effectiveThreads = max(1, min(requestedThreads, Int(totalSize)))

            if effectiveThreads <= 1 {
                try await downloadSequential(totalSize: totalSize, progress: progress)
            } else {
                try await downloadConcurrently(
                    totalSize: totalSize,
                    threadCount: effectiveThreads,
                    progress: progress
                )
            }
        }
    }

    private enum DownloadStrategy {
        case direct(PrefetchedDownload?)
        case ranged(Int64)
    }

    private struct PrefetchedDownload {
        let data: Data
        let response: HTTPURLResponse
    }

    private struct ParsedContentRange {
        let range: Range<Int64>
        let total: Int64?
    }

    private func downloadConcurrently(
        totalSize: Int64,
        threadCount: Int,
        progress: ((Int64, Int64, Double, Double) -> Void)?
    ) async throws {
        let chunkSize = totalSize / Int64(threadCount)
        let ranges = (0..<threadCount).map { index -> Range<Int64> in
            let start = Int64(index) * chunkSize
            let end = index == threadCount - 1 ? totalSize : start + chunkSize
            return start..<end
        }

        var partialData = Array(repeating: Data(), count: threadCount)
        let tracker = ProgressTracker(total: totalSize)

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (index, range) in ranges.enumerated() {
                group.addTask {
                    let data = try await self.downloadRangeWithRetry(range: range, totalSize: totalSize)
                    return (index, data)
                }
            }

            for try await (index, data) in group {
                partialData[index] = data
                if let progress {
                    let state = await tracker.update(by: Int64(data.count))
                    progress(state.downloaded, totalSize, state.speed, state.remaining)
                }
            }
        }

        let fullData = partialData.reduce(Data(), +)
        guard Int64(fullData.count) == totalSize else {
            throw makeError(
                stage: .rangeDownload,
                kind: .unexpectedContentLength,
                attempt: retryCount,
                details: "expected=\(totalSize) actual=\(fullData.count)"
            )
        }
        try fullData.write(to: destination, options: .atomic)
    }

    private func downloadSequential(
        totalSize: Int64,
        progress: ((Int64, Int64, Double, Double) -> Void)?
    ) async throws {
        let tracker = ProgressTracker(total: totalSize)
        let fileManager = FileManager.default
        let temporaryURL = destination
            .deletingLastPathComponent()
            .appendingPathComponent(destination.lastPathComponent + ".part")

        if fileManager.fileExists(atPath: temporaryURL.path) {
            try? fileManager.removeItem(at: temporaryURL)
        }
        fileManager.createFile(atPath: temporaryURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: temporaryURL)
        var completed = false
        defer {
            try? handle.close()
            if !completed {
                try? fileManager.removeItem(at: temporaryURL)
            }
        }

        let step: Int64 = 2 * 1024 * 1024
        var offset: Int64 = 0
        while offset < totalSize {
            try Task.checkCancellation()
            let end = min(offset + step, totalSize)
            let data = try await downloadRangeWithRetry(range: offset..<end, totalSize: totalSize)
            try handle.write(contentsOf: data)

            if let progress {
                let state = await tracker.update(by: Int64(data.count))
                progress(state.downloaded, totalSize, state.speed, state.remaining)
            }
            offset = end
        }

        try handle.close()
        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: temporaryURL, to: destination)
        completed = true
    }

    private func directDownload(progress: ((Int64, Int64, Double, Double) -> Void)?) async throws {
        let startTime = Date()
        let request = makeRequest(method: "GET", range: nil, timeout: 120)
        let result = try await performWithRetry(stage: .directDownload, request: request) { data, response, attempt in
            try self.validateDirectDownload(data, response: response, attempt: attempt)
        }
        try writeDirectDownload(result.data, response: result.response, startTime: startTime, progress: progress)
    }

    private func writeDirectDownload(
        _ data: Data,
        response: HTTPURLResponse,
        startTime: Date = Date(),
        progress: ((Int64, Int64, Double, Double) -> Void)?
    ) throws {
        try validateDirectDownload(data, response: response, attempt: 1)
        let totalSize = contentLength(from: response) ?? Int64(data.count)
        if let progress {
            let elapsed = max(Date().timeIntervalSince(startTime), 0.001)
            let downloaded = Int64(data.count)
            progress(downloaded, totalSize, Double(downloaded) / elapsed, 0)
        }
        try data.write(to: destination, options: .atomic)
    }

    private func downloadStrategy() async throws -> DownloadStrategy {
        do {
            let head = makeRequest(method: "HEAD", range: nil, timeout: 30)
            let result = try await performWithRetry(stage: .rangeCheckHead, request: head) { _, response, attempt in
                guard (200...299).contains(response.statusCode) || response.statusCode == 405 || response.statusCode == 501 else {
                    throw self.httpError(stage: .rangeCheckHead, response: response, attempt: attempt)
                }
            }
            if (200...299).contains(result.response.statusCode),
               result.response.value(forHTTPHeaderField: "Accept-Ranges")?.lowercased().contains("bytes") == true,
               let totalSize = contentLength(from: result.response),
               totalSize > 0 {
                return .ranged(totalSize)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // HEAD can be rejected even when a signed ranged GET is valid. A one-byte GET
            // remains the source of truth for both authorization and range support.
        }

        let probeRange: Range<Int64> = 0..<1
        let probe = makeRequest(method: "GET", range: probeRange, timeout: 30)
        let result = try await performWithRetry(stage: .rangeCheckProbe, request: probe) { data, response, attempt in
            guard response.statusCode == 200 || response.statusCode == 206 else {
                throw self.httpError(stage: .rangeCheckProbe, response: response, attempt: attempt)
            }
            if response.statusCode == 206 {
                _ = try self.validateRangeResponse(
                    data,
                    response: response,
                    expectedRange: probeRange,
                    totalSize: nil,
                    stage: .rangeCheckProbe,
                    attempt: attempt
                )
            } else {
                try self.validateDirectDownload(data, response: response, attempt: attempt, stage: .rangeCheckProbe)
            }
        }

        if result.response.statusCode == 206,
           let parsed = parseContentRange(result.response.value(forHTTPHeaderField: "Content-Range")),
           let total = parsed.total,
           total > 0 {
            return .ranged(total)
        }

        if result.response.statusCode == 200 {
            return .direct(PrefetchedDownload(data: result.data, response: result.response))
        }
        return .direct(nil)
    }

    private func downloadRangeWithRetry(range: Range<Int64>, totalSize: Int64) async throws -> Data {
        let request = makeRequest(method: "GET", range: range, timeout: 30)
        let result = try await performWithRetry(stage: .rangeDownload, request: request) { data, response, attempt in
            _ = try self.validateRangeResponse(
                data,
                response: response,
                expectedRange: range,
                totalSize: totalSize,
                stage: .rangeDownload,
                attempt: attempt
            )
        }
        return result.data
    }

    private func performWithRetry(
        stage: YTDLPDownloadError.Stage,
        request: URLRequest,
        validation: (_ data: Data, _ response: HTTPURLResponse, _ attempt: Int) throws -> Void
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var lastError: YTDLPDownloadError?

        for attempt in 1...retryCount {
            try Task.checkCancellation()
            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw makeError(stage: stage, kind: .invalidResponse, attempt: attempt)
                }
                try validation(data, httpResponse, attempt)
                return (data, httpResponse)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as URLError where error.code == .cancelled {
                throw CancellationError()
            } catch {
                let normalized = normalize(error, stage: stage, attempt: attempt)
                lastError = normalized
                guard attempt < retryCount, isRetryable(normalized) else {
                    throw normalized
                }
                try await retryDelay(attempt)
            }
        }

        throw lastError ?? makeError(stage: stage, kind: .invalidResponse, attempt: retryCount)
    }

    private func validateDirectDownload(
        _ data: Data,
        response: HTTPURLResponse,
        attempt: Int,
        stage: YTDLPDownloadError.Stage = .directDownload
    ) throws {
        guard (200...299).contains(response.statusCode) else {
            throw httpError(stage: stage, response: response, attempt: attempt)
        }
        guard !data.isEmpty else {
            throw makeError(
                stage: stage,
                kind: .unexpectedContentLength,
                statusCode: response.statusCode,
                attempt: attempt,
                details: "expected=>0 actual=0"
            )
        }

        let encoding = response.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        if encoding == nil || encoding == "identity",
           let expectedLength = contentLength(from: response),
           expectedLength != Int64(data.count) {
            throw makeError(
                stage: stage,
                kind: .unexpectedContentLength,
                statusCode: response.statusCode,
                attempt: attempt,
                details: "expected=\(expectedLength) actual=\(data.count)"
            )
        }
    }

    @discardableResult
    private func validateRangeResponse(
        _ data: Data,
        response: HTTPURLResponse,
        expectedRange: Range<Int64>,
        totalSize: Int64?,
        stage: YTDLPDownloadError.Stage,
        attempt: Int
    ) throws -> ParsedContentRange {
        guard response.statusCode == 206 else {
            throw makeError(
                stage: stage,
                kind: .invalidContentRange,
                statusCode: response.statusCode,
                attempt: attempt,
                details: "expected_status=206"
            )
        }
        guard let value = response.value(forHTTPHeaderField: "Content-Range"),
              let parsed = parseContentRange(value),
              parsed.range == expectedRange,
              totalSize == nil || parsed.total == totalSize else {
            throw makeError(
                stage: stage,
                kind: .invalidContentRange,
                statusCode: response.statusCode,
                attempt: attempt,
                details: "expected=bytes \(expectedRange.lowerBound)-\(expectedRange.upperBound - 1)/\(totalSize.map(String.init) ?? "*") actual=\(response.value(forHTTPHeaderField: "Content-Range") ?? "missing")"
            )
        }

        let expectedLength = expectedRange.upperBound - expectedRange.lowerBound
        guard Int64(data.count) == expectedLength else {
            throw makeError(
                stage: stage,
                kind: .unexpectedContentLength,
                statusCode: response.statusCode,
                attempt: attempt,
                details: "expected=\(expectedLength) actual=\(data.count)"
            )
        }
        return parsed
    }

    private func makeRequest(method: String, range: Range<Int64>?, timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        requestHeaders.forEach { field, value in
            request.setValue(value, forHTTPHeaderField: field)
        }
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("*/*", forHTTPHeaderField: "Accept")
        }
        if request.value(forHTTPHeaderField: "Accept-Encoding") == nil {
            request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        }
        if let range {
            request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        } else {
            request.setValue(nil, forHTTPHeaderField: "Range")
        }
        return request
    }

    private func parseContentRange(_ value: String?) -> ParsedContentRange? {
        guard let value else { return nil }
        let components = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard components.count == 2, components[0].lowercased() == "bytes" else { return nil }
        let rangeAndTotal = components[1].split(separator: "/", maxSplits: 1).map(String.init)
        guard rangeAndTotal.count == 2 else { return nil }
        let bounds = rangeAndTotal[0].split(separator: "-", maxSplits: 1).compactMap { Int64($0) }
        guard bounds.count == 2, bounds[0] <= bounds[1] else { return nil }
        let total = rangeAndTotal[1] == "*" ? nil : Int64(rangeAndTotal[1])
        return ParsedContentRange(range: bounds[0]..<(bounds[1] + 1), total: total)
    }

    private func contentLength(from response: HTTPURLResponse) -> Int64? {
        guard let value = response.value(forHTTPHeaderField: "Content-Length"),
              let length = Int64(value),
              length >= 0 else {
            return nil
        }
        return length
    }

    private func normalize(
        _ error: Error,
        stage: YTDLPDownloadError.Stage,
        attempt: Int
    ) -> YTDLPDownloadError {
        if let error = error as? YTDLPDownloadError {
            return error
        }
        let nsError = error as NSError
        return makeError(
            stage: stage,
            kind: .transport,
            attempt: attempt,
            underlyingErrorDomain: nsError.domain,
            underlyingErrorCode: nsError.code,
            details: nsError.localizedDescription
        )
    }

    private func httpError(
        stage: YTDLPDownloadError.Stage,
        response: HTTPURLResponse,
        attempt: Int
    ) -> YTDLPDownloadError {
        makeError(
            stage: stage,
            kind: .httpStatus,
            statusCode: response.statusCode,
            attempt: attempt
        )
    }

    private func makeError(
        stage: YTDLPDownloadError.Stage,
        kind: YTDLPDownloadError.Kind,
        statusCode: Int? = nil,
        attempt: Int,
        underlyingErrorDomain: String? = nil,
        underlyingErrorCode: Int? = nil,
        details: String? = nil
    ) -> YTDLPDownloadError {
        YTDLPDownloadError(
            stage: stage,
            kind: kind,
            url: url,
            statusCode: statusCode,
            attempt: attempt,
            underlyingErrorDomain: underlyingErrorDomain,
            underlyingErrorCode: underlyingErrorCode,
            details: details
        )
    }

    private func isRetryable(_ error: YTDLPDownloadError) -> Bool {
        if error.shouldRefreshSource {
            return false
        }
        if let statusCode = error.statusCode {
            return statusCode == 408 || statusCode == 429 || (500...599).contains(statusCode)
        }
        switch error.kind {
        case .transport, .invalidResponse, .invalidContentRange, .unexpectedContentLength:
            return true
        case .httpStatus:
            return false
        }
    }

    private static func defaultRetryDelay(failedAttempt: Int) async throws {
        let exponent = min(max(failedAttempt - 1, 0), 5)
        let seconds = UInt64(1 << exponent)
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
    }
}
