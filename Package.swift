// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GhostRunnerLogic",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "GhostRunnerLogic", targets: ["GhostRunnerLogic"])],
    targets: [
        .target(name: "GhostRunnerLogic", path: "GhostRunner/Logic"),
        .testTarget(
            name: "GhostRunnerLogicTests",
            dependencies: ["GhostRunnerLogic"],
            path: "GhostRunnerTests"
        )
    ]
)
