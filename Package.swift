// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Clanker",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Clanker", targets: ["Clanker"]),
    ],
    targets: [
        .executableTarget(
            name: "Clanker",
            path: "Sources/Clanker"
        ),
        .testTarget(
            name: "ClankerTests",
            dependencies: ["Clanker"],
            path: "Tests/ClankerTests"
        ),
    ]
)
