// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DevVault",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "DevVault",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(
            name: "DevVaultTests",
            dependencies: ["DevVault"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
