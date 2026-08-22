// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "BirthdayCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "BirthdayCore", targets: ["BirthdayCore"])],
    targets: [
        .target(name: "BirthdayCore"),
        .testTarget(
            name: "BirthdayCoreTests",
            dependencies: ["BirthdayCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
