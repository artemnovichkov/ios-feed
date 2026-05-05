// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "iOSFeedBot",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/nmdias/FeedKit.git", from: "9.1.2")
    ],
    targets: [
        .executableTarget(
            name: "iOSFeedBot",
            dependencies: [
                .product(name: "FeedKit", package: "FeedKit")
            ]
        )
    ]
)
