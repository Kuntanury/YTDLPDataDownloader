# YTDLPDataDownloader
A Swift package for high-performance segmented downloading of direct media streams.

## Features

- ⚡ Concurrent segmented downloading, with a single connection for Google Video URLs
- 📉 Real-time download progress, speed, and estimated remaining time
- 🧾 Preserves extractor-provided HTTP headers on every request
- 🔁 Retries transient transport, validation, 408, 429, and 5xx failures
- 🔎 Exposes structured stage, HTTP status, and transport diagnostics
- ✅ Designed for iOS 14+
- 🔐 Swift Concurrency based

## Usage

```swift
import YTDLPDataDownloader

let downloader = YTDLPDataDownloader(
    url: URL(string: "https://example.com/audio.m4a")!,
    destination: FileManager.default.temporaryDirectory.appendingPathComponent("audio.m4a"),
    headers: format.http_headers
)

try await downloader.start { downloaded, total, speed, remaining in
    print("Progress: \(Double(downloaded) / Double(total) * 100)%")
    print("Speed: \(speed / 1024) KB/s, Remaining: \(remaining) sec")
}
```

Authentication failures such as 401, 403, and 410 are not retried with the same
signed URL. Callers can catch `YTDLPDownloadError` and refresh their extractor info
when `shouldRefreshSource` is `true`.

## License

MIT
