// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CIDeck",
    defaultLocalization: "vi",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CIDeck",
            path: "Sources/CIDeck",
            resources: [.process("Resources")]
        )
    ]
)
