// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenExplorer",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "OpenExplorerCore", targets: ["OpenExplorerCore"]),
        .executable(name: "OpenExplorer", targets: ["OpenExplorer"])
    ],
    targets: [
        .target(name: "OpenExplorerCore"),
        .executableTarget(
            name: "OpenExplorer",
            dependencies: ["OpenExplorerCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ImageIO"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(name: "OpenExplorerCoreChecks", dependencies: ["OpenExplorerCore"])
    ]
)
