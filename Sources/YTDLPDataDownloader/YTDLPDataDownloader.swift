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
    private let session: URLSession

    public init(url: URL, destination: URL, maxThreads: Int = 4, retryCount: Int = 3) {
        self.url = url
        self.destination = destination
        self.maxThreads = maxThreads
        self.retryCount = retryCount

        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 2
        self.session = URLSession(configuration: config)
    }

    public func start(progress: ((Int64, Int64, Double, Double) -> Void)? = nil) async throws {
        let (supportsRange, totalSize) = try await checkRangeSupport()
        
        guard supportsRange, totalSize > 0 else {
            try await directDownload(progress: progress)
            return
        }

        let isGoogleVideo = url.host?.contains("googlevideo.com") == true
        let effectiveThreads = isGoogleVideo ? 1 : maxThreads

        if effectiveThreads <= 1 {
            try await downloadSequential(totalSize: totalSize, progress: progress)
            return
        }

        let chunkSize = totalSize / Int64(effectiveThreads)
        var ranges: [Range<Int64>] = []
        for i in 0..<effectiveThreads {
            let start = Int64(i) * chunkSize
            let end = (i == effectiveThreads - 1) ? totalSize : start + chunkSize
            ranges.append(start..<end)
        }

        var partialData = Array(repeating: Data(), count: effectiveThreads)
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

    private func downloadSequential(totalSize: Int64, progress: ((Int64, Int64, Double, Double) -> Void)? = nil) async throws {
        let tracker = ProgressTracker(total: totalSize)

        let fm = FileManager.default
        let tmp = destination.deletingLastPathComponent().appendingPathComponent(destination.lastPathComponent + ".part")
        if fm.fileExists(atPath: tmp.path) {
            try? fm.removeItem(at: tmp)
        }
        fm.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        defer { try? handle.close() }

        let step: Int64 = 2 * 1024 * 1024
        var offset: Int64 = 0
        while offset < totalSize {
            let end = min(offset + step, totalSize)
            let range = offset..<end
            let data = try await downloadWithRetry(range: range)
            try handle.write(contentsOf: data)

            if let progress {
                let (downloaded, speed, remaining) = await tracker.update(by: Int64(data.count))
                progress(downloaded, totalSize, speed, remaining)
            }
            offset = end
        }

        if fm.fileExists(atPath: destination.path) {
            try? fm.removeItem(at: destination)
        }
        try fm.moveItem(at: tmp, to: destination)
    }

    private func directDownload(progress: ((Int64, Int64, Double, Double) -> Void)? = nil) async throws {
        let startTime = Date()

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 120

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.cannotParseResponse)
        }

        let totalSize: Int64
        if let len = http.allHeaderFields["Content-Length"] as? String, let v = Int64(len) {
            totalSize = v
        } else {
            totalSize = Int64(data.count)
        }

        if let progress {
            let elapsed = max(Date().timeIntervalSince(startTime), 0.001)
            let downloaded = Int64(data.count)
            let speed = Double(downloaded) / elapsed
            progress(downloaded, totalSize, speed, 0)
        }
        try data.write(to: destination)
    }

    private func checkRangeSupport() async throws -> (Bool, Int64) {
        do {
            var head = URLRequest(url: url)
            head.httpMethod = "HEAD"
            head.cachePolicy = .reloadIgnoringLocalCacheData
            head.timeoutInterval = 30
            head.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")

            let (_, response) = try await session.data(for: head)
            print("checkRangeSupport(HEAD) = \(response)")
            if let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                let acceptRanges = (http.allHeaderFields["Accept-Ranges"] as? String)?.lowercased()
                let supportsRange = acceptRanges?.contains("bytes") == true
                let lengthHeader = http.allHeaderFields["Content-Length"] as? String
                let totalSize = Int64(lengthHeader ?? "0") ?? 0
                if supportsRange, totalSize > 0 {
                    return (true, totalSize)
                }
            }
        } catch {
            print("[YTDLPDataDownloader] HEAD failed: \(error)")
        }
        
        var probe = URLRequest(url: url)
        probe.httpMethod = "GET"
        probe.cachePolicy = .reloadIgnoringLocalCacheData
        probe.timeoutInterval = 30
        probe.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        probe.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        probe.setValue("*/*", forHTTPHeaderField: "Accept")

        let (_, response) = try await session.data(for: probe)
        print("checkRangeSupport(PROBE) = \(response)")
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if http.statusCode == 206 {
            if let contentRange = http.allHeaderFields["Content-Range"] as? String {
                if let slash = contentRange.lastIndex(of: "/") {
                    let totalStr = String(contentRange[contentRange.index(after: slash)...]).trimmingCharacters(in: .whitespaces)
                    let total = Int64(totalStr) ?? 0
                    if total > 0 {
                        return (true, total)
                    }
                }
            }
            return (true, 0)
        }

        if (200...299).contains(http.statusCode) {
            let lengthHeader = http.allHeaderFields["Content-Length"] as? String
            let totalSize = Int64(lengthHeader ?? "0") ?? 0
            return (false, totalSize)
        }

        return (false, 0)
    }

    private func downloadWithRetry(range: Range<Int64>) async throws -> Data {
        var attempt = 0
        while attempt < retryCount {
            do {
                return try await downloadRange(range: range)
            } catch {
                print("[YTDLPDataDownloader] chunk range=\(range) attempt=\(attempt + 1) failed: \(error)")
                attempt += 1
                try await Task.sleep(nanoseconds: UInt64(1_000_000_000 * pow(2.0, Double(attempt))))
            }
        }
        print("[YTDLPDataDownloader] chunk range=\(range) exhausted retries (\(retryCount))")
        throw URLError(.networkConnectionLost)
    }

    private func downloadRange(range: Range<Int64>) async throws -> Data {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound - 1)", forHTTPHeaderField: "Range")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.cannotParseResponse)
        }
        return data
    }
}
