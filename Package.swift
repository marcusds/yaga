// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Yaga",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Yaga",
            path: "Sources/Yaga",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
