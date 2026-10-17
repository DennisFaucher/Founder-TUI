// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Founder",
    products: [
        .executable(
            name: "Founder",
            targets: ["Founder"])
    ],
    dependencies: [
    ],
    targets: [
        .executableTarget(
            name: "Founder",
            dependencies: []),
        .testTarget(
            name: "FounderTests",
            dependencies: ["Founder"])
    ]
)
