// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pixomancy",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Pixomancy",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
