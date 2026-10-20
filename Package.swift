// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NoteIt",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .executable(name: "NoteIt", targets: ["NoteIt"]),
        .library(name: "NoteItCore", targets: ["NoteItCore"]),
        .library(name: "NoteItSync", targets: ["NoteItSync"]),
        .library(name: "NoteItDoc", targets: ["NoteItDoc"])
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
            name: "NoteItDoc",
            dependencies: ["NoteItCore"],
            path: "Sources/NoteItDoc"
        ),
        .target(
            name: "NoteItDocAppKit",
            dependencies: ["NoteItDoc", "NoteItCore"],
            path: "Sources/NoteItDocAppKit"
        ),
        .target(
            name: "NoteItDocTestSupport",
            dependencies: ["NoteItDoc"],
            path: "Tests/Support/NoteItDocTestSupport"
        ),
        .target(
            name: "NoteItSync",
            path: "Sources/NoteItSync"
        ),
        .executableTarget(
            name: "NoteIt",
            dependencies: [
                "NoteItCore",
                "NoteItDoc",
                "NoteItDocAppKit",
                "NoteItSync",
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
            name: "NoteItDocTests",
            dependencies: ["NoteItDoc", "NoteItDocTestSupport"],
            path: "Tests/NoteItDocTests"
        ),
        .testTarget(
            name: "NoteItDocAppKitTests",
            dependencies: ["NoteItDocAppKit", "NoteItDocTestSupport"],
            path: "Tests/NoteItDocAppKitTests"
        ),
        .testTarget(
            name: "NoteItSyncTests",
            dependencies: ["NoteItSync"],
            path: "Tests/NoteItSyncTests"
        ),
        .testTarget(
            name: "NoteItTests",
            dependencies: ["NoteIt", "NoteItCore", "NoteItDoc", "NoteItDocAppKit", "NoteItSync"],
            path: "Tests/NoteItTests"
        )
    ]
)
