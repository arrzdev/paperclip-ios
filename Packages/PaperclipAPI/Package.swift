// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PaperclipAPI",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PaperclipAPI", targets: ["PaperclipAPI"]),
    ],
    targets: [
        .target(name: "PaperclipAPI"),
        .testTarget(
            name: "PaperclipAPITests",
            dependencies: ["PaperclipAPI"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
