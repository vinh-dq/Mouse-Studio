// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MouseStudio",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "MouseStudio",
            path: "Sources/MouseStudio"
        ),
        .testTarget(
            name: "MouseStudioTests",
            dependencies: ["MouseStudio"],
            path: "Tests/MouseStudioTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
