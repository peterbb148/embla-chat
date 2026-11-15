// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EmblaCore",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "EmblaCore", targets: ["EmblaCore"]),
        .library(name: "EmblaRuntime", targets: ["EmblaRuntime"]),
        .library(name: "EmblaPresentation", targets: ["EmblaPresentation"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/peterbb148/embla-metal",
            revision: "0c8caaa3616372482d047fa9e953ea656cb34588")
    ],
    targets: [
        .target(name: "EmblaCore", resources: [.copy("Resources/model-manifest.json")]),
        .testTarget(name: "EmblaCoreTests", dependencies: ["EmblaCore"]),
        .target(
            name: "EmblaRuntime",
            dependencies: [
                "EmblaCore", .product(name: "EmblaChat", package: "embla-metal"),
                .product(name: "EmblaMetal", package: "embla-metal"),
            ]),
        .target(name: "EmblaPresentation", dependencies: ["EmblaCore", "EmblaRuntime"]),
        .testTarget(
            name: "EmblaPresentationTests", dependencies: ["EmblaPresentation", "EmblaCore", "EmblaRuntime"]),
    ]
)
