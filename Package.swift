// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "FinderPlus",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FinderPlus", targets: ["FinderPlus"])
    ],
    targets: [
        .target(name: "FinderCore", path: "Sources/FinderCore"),
        .executableTarget(name: "FinderPlus", dependencies: ["FinderCore"], path: "Sources/FinderPlus"),
        .testTarget(name: "FinderCoreTests", dependencies: ["FinderCore"], path: "Tests/FinderCoreTests")
    ]
)
