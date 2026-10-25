// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "STTBench",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", exact: "4.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "STTBench",
            dependencies: [.product(name: "Voz", package: "desert-ant-core")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
