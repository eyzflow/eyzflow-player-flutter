// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "eyzflow_player",
    platforms: [
        .iOS("13.0")
    ],
    products: [
        .library(name: "eyzflow-player", targets: ["eyzflow_player"])
    ],
    dependencies: [
        .package(name: "FlutterFramework", path: "../FlutterFramework")
    ],
    targets: [
        .target(
            name: "eyzflow_player",
            dependencies: [
                .product(name: "FlutterFramework", package: "FlutterFramework")
            ],
            resources: [
                .process("Resources")
            ]
        )
    ]
)
