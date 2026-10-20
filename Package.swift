// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NoteIt",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "NoteIt", targets: ["NoteIt"]),
        .library(name: "NoteItCore", targets: ["NoteItCore"]),
        .library(name: "NoteItSync", targets: ["NoteItSync"]),
        .library(name: "NoteItAPI", targets: ["NoteItAPI"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .target(
            name: "NoteItCore",
            path: "Sources/NoteItCore"
        ),
        .target(
            name: "NoteItSync",
            path: "Sources/NoteItSync"
        ),
        .target(
            name: "NoteItAPI",
            dependencies: ["NoteItCore", "NoteItSync"],
            path: "Sources/NoteItAPI"
        ),
        .executableTarget(
            name: "NoteItCLI",
            dependencies: ["NoteItAPI", "NoteItSync"],
            path: "Sources/NoteItCLI"
        ),
        .executableTarget(
            name: "NoteIt",
            dependencies: [
                "NoteItCore",
                "NoteItSync",
                "NoteItAPI",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/NoteIt",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "NoteItCoreTests",
            dependencies: ["NoteItCore"],
            path: "Tests/NoteItCoreTests"
        ),
        .testTarget(
            name: "NoteItSyncTests",
            dependencies: ["NoteItSync"],
            path: "Tests/NoteItSyncTests"
        ),
        .testTarget(
            name: "NoteItTests",
            dependencies: ["NoteIt", "NoteItCore", "NoteItSync"],
            path: "Tests/NoteItTests"
        ),
        .testTarget(
            name: "NoteItAPITests",
            dependencies: ["NoteItAPI", "NoteItCore", "NoteItSync"],
            path: "Tests/NoteItAPITests"
        )
    ]
)
