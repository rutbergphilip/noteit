// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Inkwell",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Inkwell", targets: ["Inkwell"])
    ],
    targets: [
        .executableTarget(
            name: "Inkwell",
            path: "Sources/Inkwell"
        )
    ]
)
