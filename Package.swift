// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "WhoSaidWhat",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/Desert-Ant-Labs/desert-ant-core.git", from: "4.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "WhoSaidWhat",
            dependencies: [.product(name: "Who", package: "desert-ant-core")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
