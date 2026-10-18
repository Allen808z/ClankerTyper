// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClankerTyper",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClankerTyper", targets: ["ClankerTyper"]),
    ],
    targets: [
        .executableTarget(
            name: "ClankerTyper",
            path: "Sources/ClankerTyper"
        ),
        .testTarget(
            name: "ClankerTyperTests",
            dependencies: ["ClankerTyper"],
            path: "Tests/ClankerTyperTests"
        ),
    ]
)
