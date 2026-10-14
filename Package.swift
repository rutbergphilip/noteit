// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NoteIt",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NoteIt", targets: ["NoteIt"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .target(
            name: "NoteItSync",
            path: "Sources/NoteItSync"
        ),
        .executableTarget(
            name: "NoteIt",
            dependencies: [
                "NoteItSync",
                .product(name: "Sparkle", package: "Sparkle")
            ],
            path: "Sources/NoteIt",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "NoteItSyncTests",
            dependencies: ["NoteItSync"],
            path: "Tests/NoteItSyncTests"
        ),
        .testTarget(
            name: "NoteItTests",
            dependencies: ["NoteIt", "NoteItSync"],
            path: "Tests/NoteItTests"
        )
    ]
)
