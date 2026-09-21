// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Restwatt",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Restwatt", targets: ["RestwattApp"]),
    ],
    targets: [
        // Pure logic: power math, the time-to-empty estimator, process ranking, formatting.
        // No AppKit or IOKit import; fully unit-tested without hardware.
        .target(name: "RestwattCore"),
        // The menu bar app: AppKit status item, IOKit battery reader, libproc process reader.
        .executableTarget(name: "RestwattApp", dependencies: ["RestwattCore"]),
        .testTarget(name: "RestwattCoreTests", dependencies: ["RestwattCore"]),
    ]
)
