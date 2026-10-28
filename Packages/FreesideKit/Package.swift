// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FreesideKit",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "FreesideKit", targets: ["FreesideKit"]),
    ],
    targets: [
        .target(name: "FreesideKit"),
        .testTarget(name: "FreesideKitTests", dependencies: ["FreesideKit"]),
    ]
)
