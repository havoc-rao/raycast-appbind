// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AppBind",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "AppBindCore", targets: ["AppBindCore"]),
        .executable(name: "appbind-helper", targets: ["AppBindHelper"])
    ],
    targets: [
        .target(name: "AppBindCore"),
        .executableTarget(name: "AppBindHelper", dependencies: ["AppBindCore"]),
        .testTarget(name: "AppBindCoreTests", dependencies: ["AppBindCore"])
    ]
)
