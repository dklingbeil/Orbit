// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "OrbitKit",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OrbitKit", targets: ["OrbitKit"]),
        .executable(name: "orbit", targets: ["orbit-cli"]),
    ],
    targets: [
        .target(name: "OrbitKit"),
        .executableTarget(name: "orbit-cli", dependencies: ["OrbitKit"]),
        .testTarget(name: "OrbitKitTests", dependencies: ["OrbitKit"]),
    ]
)
