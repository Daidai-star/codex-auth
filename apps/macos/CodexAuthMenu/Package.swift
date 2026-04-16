// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodexAuthMenu",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexAuthMenu", targets: ["CodexAuthMenu"])
    ],
    targets: [
        .executableTarget(name: "CodexAuthMenu"),
        .testTarget(
            name: "CodexAuthMenuTests",
            dependencies: ["CodexAuthMenu"]
        )
    ]
)
