// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DevVault",
    platforms: [
        .macOS(.v14),
    ],
    targets: [
        .executableTarget(
            name: "DevVault"
        ),
        .testTarget(
            name: "DevVaultTests",
            dependencies: ["DevVault"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
