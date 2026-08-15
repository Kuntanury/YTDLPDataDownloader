import XCTest
@testable import YTDLPDataDownloader

final class YTDLPDataDownloaderTests: XCTestCase {
    override func tearDown() {
        MockURLProtocol.requestHandler = nil
        super.tearDown()
    }

    func testPreservesExtractorHeadersForHeadAndRangeRequests() async throws {
        let source = URL(string: "https://rr.example.googlevideo.com/videoplayback")!
        let destination = temporaryDestination()
        defer { try? FileManager.default.removeItem(at: destination) }

        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            recorder.append(request)

            if request.httpMethod == "HEAD" {
                return Self.response(
                    request: request,
                    statusCode: 200,
                    headers: ["Accept-Ranges": "bytes", "Content-Length": "4"]
                )
            }
            return Self.response(
                request: request,
                statusCode: 206,
                headers: ["Content-Range": "bytes 0-3/4", "Content-Length": "4"],
                data: Data("test".utf8)
            )
        }

        let downloader = makeDownloader(
            source: source,
            destination: destination,
            headers: ["User-Agent": "ExtractorAgent/1.0", "X-Playback-Context": "context"]
        )
        try await downloader.start()

        XCTAssertEqual(try Data(contentsOf: destination), Data("test".utf8))
        let requests = recorder.snapshot()
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "User-Agent") == "ExtractorAgent/1.0" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Playback-Context") == "context" })
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Range"), "bytes=0-3")
    }

    func testAuthenticationFailureIsStructuredAndDoesNotRetry() async throws {
        let source = URL(string: "https://rr.example.googlevideo.com/videoplayback")!
        let destination = temporaryDestination()
        var requestCount = 0
        MockURLProtocol.requestHandler = { request in
            requestCount += 1
            return Self.response(request: request, statusCode: 403)
        }

        let downloader = makeDownloader(
            source: source,
            destination: destination,
            retryCount: 3
        )

        do {
            try await downloader.start()
            XCTFail("Expected download to fail")
        } catch let error as YTDLPDownloadError {
            XCTAssertEqual(error.stage, .rangeCheckProbe)
            XCTAssertEqual(error.kind, .httpStatus)
            XCTAssertEqual(error.statusCode, 403)
            XCTAssertEqual(error.attempt, 1)
            XCTAssertTrue(error.shouldRefreshSource)
        }
        XCTAssertEqual(requestCount, 2)
    }

    func testHeadAuthenticationFailureFallsBackToValidRangedGet() async throws {
        let source = URL(string: "https://rr.example.googlevideo.com/videoplayback")!
        let destination = temporaryDestination()
        defer { try? FileManager.default.removeItem(at: destination) }

        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "HEAD" {
                return Self.response(request: request, statusCode: 403)
            }
            if request.value(forHTTPHeaderField: "Range") == "bytes=0-0" {
                return Self.response(
                    request: request,
                    statusCode: 206,
                    headers: ["Content-Range": "bytes 0-0/4", "Content-Length": "1"],
                    data: Data("t".utf8)
                )
            }
            return Self.response(
                request: request,
                statusCode: 206,
                headers: ["Content-Range": "bytes 0-3/4", "Content-Length": "4"],
                data: Data("test".utf8)
            )
        }

        let downloader = makeDownloader(source: source, destination: destination)
        try await downloader.start()

        XCTAssertEqual(try Data(contentsOf: destination), Data("test".utf8))
    }

    func testDirectDownloadRetriesTransientHTTPFailure() async throws {
        let source = URL(string: "https://media.example.com/audio")!
        let destination = temporaryDestination()
        defer { try? FileManager.default.removeItem(at: destination) }

        var directRequestCount = 0
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "HEAD" {
                return Self.response(request: request, statusCode: 405)
            }
            if request.value(forHTTPHeaderField: "Range") != nil {
                return Self.response(
                    request: request,
                    statusCode: 206,
                    headers: ["Content-Range": "bytes 0-0/*", "Content-Length": "1"],
                    data: Data("t".utf8)
                )
            }

            directRequestCount += 1
            if directRequestCount == 1 {
                return Self.response(request: request, statusCode: 503)
            }
            return Self.response(
                request: request,
                statusCode: 200,
                headers: ["Content-Length": "4"],
                data: Data("test".utf8)
            )
        }

        let downloader = makeDownloader(
            source: source,
            destination: destination,
            retryCount: 2
        )
        try await downloader.start()

        XCTAssertEqual(directRequestCount, 2)
        XCTAssertEqual(try Data(contentsOf: destination), Data("test".utf8))
    }

    func testRejectsTruncatedRangeResponse() async throws {
        let source = URL(string: "https://rr.example.googlevideo.com/videoplayback")!
        let destination = temporaryDestination()
        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "HEAD" {
                return Self.response(
                    request: request,
                    statusCode: 200,
                    headers: ["Accept-Ranges": "bytes", "Content-Length": "4"]
                )
            }
            return Self.response(
                request: request,
                statusCode: 206,
                headers: ["Content-Range": "bytes 0-3/4", "Content-Length": "3"],
                data: Data("bad".utf8)
            )
        }

        let downloader = makeDownloader(
            source: source,
            destination: destination,
            retryCount: 1
        )

        do {
            try await downloader.start()
            XCTFail("Expected truncated range to fail")
        } catch let error as YTDLPDownloadError {
            XCTAssertEqual(error.stage, .rangeDownload)
            XCTAssertEqual(error.kind, .unexpectedContentLength)
            XCTAssertEqual(error.statusCode, 206)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path + ".part"))
    }

    func testGoogleVideoUsesSmallAdaptiveRanges() async throws {
        let source = URL(string: "https://rr.example.googlevideo.com/videoplayback")!
        let destination = temporaryDestination()
        let totalSize = 1_400_000
        defer {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(atPath: destination.path + ".part")
        }

        let recorder = RequestRecorder()
        MockURLProtocol.requestHandler = { request in
            recorder.append(request)
            if request.httpMethod == "HEAD" {
                return Self.response(
                    request: request,
                    statusCode: 200,
                    headers: ["Accept-Ranges": "bytes", "Content-Length": "\(totalSize)"]
                )
            }

            let range = try XCTUnwrap(Self.requestedRange(request))
            return Self.response(
                request: request,
                statusCode: 206,
                headers: [
                    "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(totalSize)",
                    "Content-Length": "\(range.count)",
                ],
                data: Data(repeating: 1, count: range.count)
            )
        }

        let downloader = makeDownloader(source: source, destination: destination)
        try await downloader.start()

        let rangeHeaders = recorder.snapshot().compactMap {
            $0.value(forHTTPHeaderField: "Range")
        }
        XCTAssertEqual(
            rangeHeaders,
            [
                "bytes=0-262143",
                "bytes=262144-524287",
                "bytes=524288-786431",
                "bytes=786432-1310719",
                "bytes=1310720-1399999",
            ]
        )
        XCTAssertEqual(try Data(contentsOf: destination).count, totalSize)
    }

    func testResumesPartialGoogleVideoDownloadAfterAuthenticationRefresh() async throws {
        let source = URL(string: "https://rr.example.googlevideo.com/videoplayback")!
        let destination = temporaryDestination()
        let partial = URL(fileURLWithPath: destination.path + ".part")
        let totalSize = 700_000
        var firstRun = true
        var successfulRanges = [Range<Int>]()
        defer {
            try? FileManager.default.removeItem(at: destination)
            try? FileManager.default.removeItem(at: partial)
        }

        MockURLProtocol.requestHandler = { request in
            if request.httpMethod == "HEAD" {
                return Self.response(
                    request: request,
                    statusCode: 200,
                    headers: ["Accept-Ranges": "bytes", "Content-Length": "\(totalSize)"]
                )
            }

            let range = try XCTUnwrap(Self.requestedRange(request))
            if firstRun, range.lowerBound > 0 {
                return Self.response(request: request, statusCode: 403)
            }
            successfulRanges.append(range)
            return Self.response(
                request: request,
                statusCode: 206,
                headers: [
                    "Content-Range": "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(totalSize)",
                    "Content-Length": "\(range.count)",
                ],
                data: Data(repeating: 2, count: range.count)
            )
        }

        let firstDownloader = makeDownloader(
            source: source,
            destination: destination,
            retryCount: 3,
            resumePartialDownload: true
        )
        do {
            try await firstDownloader.start()
            XCTFail("Expected the signed URL to require refresh")
        } catch let error as YTDLPDownloadError {
            XCTAssertEqual(error.statusCode, 403)
            XCTAssertTrue(error.shouldRefreshSource)
        }
        XCTAssertEqual(
            (try FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.intValue,
            256 * 1024
        )

        firstRun = false
        successfulRanges.removeAll()
        let refreshedDownloader = makeDownloader(
            source: source,
            destination: destination,
            retryCount: 3,
            resumePartialDownload: true
        )
        try await refreshedDownloader.start()

        XCTAssertEqual(successfulRanges.first?.lowerBound, 256 * 1024)
        XCTAssertEqual(try Data(contentsOf: destination).count, totalSize)
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    }

    private func makeDownloader(
        source: URL,
        destination: URL,
        headers: [String: String] = [:],
        retryCount: Int = 1,
        resumePartialDownload: Bool = false
    ) -> YTDLPDataDownloader {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return YTDLPDataDownloader(
            url: source,
            destination: destination,
            headers: headers,
            maxThreads: 4,
            retryCount: retryCount,
            resumePartialDownload: resumePartialDownload,
            session: session,
            retryDelay: { _ in }
        )
    }

    private func temporaryDestination() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("YTDLPDataDownloaderTests-\(UUID().uuidString)")
    }

    private static func response(
        request: URLRequest,
        statusCode: Int,
        headers: [String: String] = [:],
        data: Data = Data()
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        return (response, data)
    }

    private static func requestedRange(_ request: URLRequest) -> Range<Int>? {
        guard let value = request.value(forHTTPHeaderField: "Range"),
              value.hasPrefix("bytes=") else {
            return nil
        }
        let bounds = value.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
        guard bounds.count == 2, bounds[0] <= bounds[1] else { return nil }
        return bounds[0]..<(bounds[1] + 1)
    }
}

private final class MockURLProtocol: URLProtocol {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class RequestRecorder {
    private let lock = NSLock()
    private var requests = [URLRequest]()

    func append(_ request: URLRequest) {
        lock.lock()
        requests.append(request)
        lock.unlock()
    }

    func snapshot() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}
