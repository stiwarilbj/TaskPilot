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
        .executableTarget(
            name: "OrbitAgent",
            path: "Sources/OrbitAgent",
            linkerSettings: [
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("CoreServices"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("UserNotifications")
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
