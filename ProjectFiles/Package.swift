// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OrbitAgent",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "OrbitAgent", targets: ["OrbitAgent"])
    ],
    targets: [
        .target(name: "ProcessSupport", path: "Sources/ProcessSupport"),
        .executableTarget(
            name: "OrbitAgent",
            dependencies: ["ProcessSupport"],
            path: "Sources/OrbitAgent",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("Vision")
            ]
        ),
        .testTarget(
            name: "OrbitAgentTests",
            dependencies: ["OrbitAgent"],
            path: "Tests/OrbitAgentTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
