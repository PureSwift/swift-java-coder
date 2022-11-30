// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "JavaCoder",
    products:[
        .library(
            name: "JavaCoder", 
            targets:["JavaCoder"]
        )
    ],
    dependencies: [
        .package(
            url: "https://github.com/PureSwift/java_swift.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/PureSwift/AnyCodable.git",
            branch: "master"
        )
    ],
    targets: [
        .target(
            name: "JavaCoder",
            dependencies: [
                "java_swift",
                "AnyCodable"
            ],
            path: "Sources"
        )
    ]
)
