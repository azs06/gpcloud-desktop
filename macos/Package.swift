// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GPCloud",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GPCloud", targets: ["GPCloud"]),
    ],
    targets: [
        .target(
            name: "GPCloudKit",
            path: "Sources/GPCloudKit"
        ),
        .executableTarget(
            name: "GPCloud",
            dependencies: ["GPCloudKit"],
            path: "Sources/GPCloud"
        ),
        .executableTarget(
            name: "gpcloud-selftest",
            dependencies: ["GPCloudKit"],
            path: "Sources/SelfTest"
        ),
    ]
)
