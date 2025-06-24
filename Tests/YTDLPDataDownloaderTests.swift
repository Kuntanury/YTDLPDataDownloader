import XCTest
@testable import YTDLPDownloader

final class YTDLPDownloaderTests: XCTestCase {
    func testExampleDownload() async throws {
        let testURL = URL(string: "https://speed.hetzner.de/100MB.bin")!
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("test_100MB.bin")
        let downloader = YTDLPDownloader(url: testURL, destination: destination, maxThreads: 2)

        try await downloader.start { downloaded, total, speed, remaining in
            print("Progress: \\(downloaded)/\\(total), Speed: \\(speed), Remaining: \\(remaining)")
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        let fileSize = try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64
        XCTAssertEqual(fileSize, 104857600) // 100MB
    }
}
