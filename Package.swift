// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Stackriot",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(path: "Vendor/SwiftTerm"),
    ],
    targets: [
        .executableTarget(
            name: "Stackriot",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
            ]
        ),
        .testTarget(
            name: "StackriotTests",
            dependencies: ["Stackriot"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
