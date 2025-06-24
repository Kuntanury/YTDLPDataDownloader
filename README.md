# YTDLPDataDownloader
A Swift package for high-performance segmented downloading of direct media streams.

## Features

- ⚡ High-speed concurrent segmented downloading
- 📉 Real-time download progress, speed, and estimated remaining time
- ✅ Designed for iOS 14+
- 🔐 Swift Concurrency & Swift 6 safe

## Usage

```swift
import YTDLPDownloader

let downloader = YTDLPDownloader(
    url: URL(string: "https://example.com/audio.m4a")!,
    destination: FileManager.default.temporaryDirectory.appendingPathComponent("audio.m4a")
)

try await downloader.start { downloaded, total, speed, remaining in
    print("Progress: \\(Double(downloaded) / Double(total) * 100)%")
    print("Speed: \\(speed / 1024) KB/s, Remaining: \\(remaining) sec")
}
```

## License

MIT
"""
