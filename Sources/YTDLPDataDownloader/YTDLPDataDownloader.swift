// Sources/YTDLPDataDownloader/YTDLPDataDownloader.swift

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

public class YTDLPDataDownloader {
    public let url: URL
    public let destination: URL
    public let maxThreads: Int
    public let retryCount: Int

    public init(url: URL, destination: URL, maxThreads: Int = 4, retryCount: Int = 3) {
        self.url = url
        self.destination = destination
        self.maxThreads = maxThreads
        self.retryCount = retryCount
    }

    public func start(progress: ((Int64, Int64, Double, Double) -> Void)? = nil) async throws {
        let (supportsRange, totalSize) = try await checkRangeSupport()
        guard supportsRange else {
            throw URLError(.badServerResponse)
        }

        let chunkSize = totalSize / Int64(maxThreads)
        var ranges: [Range<Int64>] = []
        for i in 0..<maxThreads {
            let start = Int64(i) * chunkSize
            let end = (i == maxThreads - 1) ? totalSize : start + chunkSize
            ranges.append(start..<end)
        }

        var partialData = Array(repeating: Data(), count: maxThreads)
        let tracker = ProgressTracker(total: totalSize)

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            for (index, range) in ranges.enumerated() {
                group.addTask {
                    let data = try await self.downloadWithRetry(range: range)
                    return (index, data)
                }
            }

            for try await (index, data) in group {
                partialData[index] = data
                if let progress = progress {
                    let (downloaded, speed, remaining) = await tracker.update(by: Int64(data.count))
                    progress(downloaded, totalSize, speed, remaining)
                }
            }
        }

        let fullData = partialData.reduce(Data(), +)
        try fullData.write(to: destination)
    }

    private func checkRangeSupport() async throws -> (Bool, Int64) {
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        let supportsRange = (200...299).contains(http.statusCode) || http.allHeaderFields["Accept-Ranges"] as? String == "bytes"
        let lengthHeader = http.allHeaderFields["Content-Length"] as? String
        let totalSize = Int64(lengthHeader ?? "0") ?? 0
        return (supportsRange, totalSize)
    }

    private func downloadWithRetry(range: Range<Int64>) async throws -> Data {
        var attempt = 0
        while attempt < retryCount {
            do {
                return try await downloadRange(range: range)
            } catch {
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000 * pow(2.0, Double(attempt))))
            }
        }
        throw URLError(.networkConnectionLost)
    }

    private func downloadRange(range: Range<Int64>) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 206 else {
            throw URLError(.cannotParseResponse)
        }
        return data
    }
}
