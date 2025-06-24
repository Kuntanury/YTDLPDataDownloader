// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "YTDLPDataDownloader",
    platforms: [
        .iOS(.v14)
    ],
    products: [
        .library(
            name: "YTDLPDataDownloader",
            targets: ["YTDLPDataDownloader"]
        ),
    ],
    targets: [
        .target(
            name: "YTDLPDataDownloader",
            dependencies: []
        ),
        .testTarget(
            name: "YTDLPDataDownloaderTests",
            dependencies: ["YTDLPDataDownloader"]
        ),
    ]
)
