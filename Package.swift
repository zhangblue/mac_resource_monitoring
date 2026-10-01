// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacResourceMonitor",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MacResourceMonitor", targets: ["MacResourceMonitor"])],
    targets: [
        .executableTarget(
            name: "MacResourceMonitor",
            path: "Sources/MacResourceMonitor",
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]
        ),
        .testTarget(name: "MacResourceMonitorTests", dependencies: ["MacResourceMonitor"])
    ]
)
