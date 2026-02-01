// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ShiftSync",
    platforms: [
        .iOS(.v17)
    ],
    products: [
        .library(name: "ShiftSync", targets: ["ShiftSync"])
    ],
    dependencies: [
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(url: "https://github.com/google/GoogleSignIn-iOS.git", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "ShiftSync",
            dependencies: [
                "SwiftSoup",
                .product(name: "GoogleSignIn", package: "GoogleSignIn-iOS"),
            ],
            path: "ShiftSync"
        ),
    ]
)
