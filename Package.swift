// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EmblaCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "EmblaCore", targets: ["EmblaCore"])],
    targets: [
        .target(name: "EmblaCore", resources: [.copy("Resources/model-manifest.json")]),
        .testTarget(name: "EmblaCoreTests", dependencies: ["EmblaCore"]),
    ]
)
