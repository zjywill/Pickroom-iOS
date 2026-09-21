// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PickroomCore",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
    ],
    products: [
        .library(name: "PickroomCore", targets: ["PickroomCore"]),
    ],
    targets: [
        .target(name: "PickroomCore"),
        .testTarget(
            name: "PickroomCoreTests",
            dependencies: ["PickroomCore"]
        ),
    ]
)
