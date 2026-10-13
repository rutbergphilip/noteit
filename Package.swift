// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "NoteIt",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "NoteIt", targets: ["NoteIt"])
    ],
    targets: [
        .target(
            name: "NoteItSync",
            path: "Sources/NoteItSync"
        ),
        .executableTarget(
            name: "NoteIt",
            dependencies: ["NoteItSync"],
            path: "Sources/NoteIt"
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
