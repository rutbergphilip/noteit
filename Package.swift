// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Inkwell",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Inkwell", targets: ["Inkwell"])
    ],
    targets: [
        .target(
            name: "InkwellSync",
            path: "Sources/InkwellSync"
        ),
        .executableTarget(
            name: "Inkwell",
            dependencies: ["InkwellSync"],
            path: "Sources/Inkwell"
        ),
        .testTarget(
            name: "InkwellSyncTests",
            dependencies: ["InkwellSync"],
            path: "Tests/InkwellSyncTests"
        )
    ]
)
