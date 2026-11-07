// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "DockGroup",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DockGroup",
            path: "Sources/DockGroup"
        )
    ]
)
