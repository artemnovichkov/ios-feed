// swift-tools-version: 6.3
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
        ),
        .testTarget(
            name: "iOSFeedBotTests",
            dependencies: ["iOSFeedBot"]
        )
    ],
    swiftLanguageModes: [.v6]
)
