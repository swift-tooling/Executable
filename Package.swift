// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Executable",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "Executable",
            targets: ["Executable"]
        ),
        // Pkl configuration: build-object.pkl and its migration to package.frame (`sbm modernize`),
        // and `.sbm/workflows.pkl` behind `sbm wf` / `sbm pkg`.
        .library(
            name: "ExecutableLegacy",
            targets: ["ExecutableLegacy"]
        ),
    ],
    dependencies: [
        .package(
            url: "https://github.com/leviouwendijk/plate.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/swift-lco/Interfaces.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/swift-lco/Terminal.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/swift-lco/Indentation.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/swift-lco/Path.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/swift-lco/Primitives.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/swift-lco/Version.git",
            branch: "master"
        ),
        .package(url: "https://github.com/swift-langs/Parsers.git", branch: "master"),
        .package(url: "https://github.com/lco-langs/Frame.git", branch: "master"),
        .package(url: "https://github.com/swift-lco/IO.git", branch: "master"),
        .package(url: "https://github.com/swift-lco/Readers.git", branch: "master"),
        .package(url: "https://github.com/swift-lco/Writers.git", branch: "master"),
        .package(
            url: "https://github.com/swift-lco/Arguments.git",
            branch: "master"
        ),
        .package(
            url: "https://github.com/swift-lco/Processes.git",
            branch: "master"
        ),
    ],
    targets: [
        .target(
            name: "Executable",
            dependencies: [
                .product(name: "plate", package: "plate"),
                .product(name: "Interfaces", package: "Interfaces"),
                .product(name: "Processes", package: "Processes"),
                .product(name: "Terminal", package: "Terminal"),
                .product(name: "Indentation", package: "Indentation"),
                .product(name: "Path", package: "Path"),
                .product(name: "Primitives", package: "Primitives"),
                .product(name: "Version", package: "Version"),
                .product(name: "Frame", package: "Frame"),
                .product(name: "Roots", package: "Frame"),
                .product(name: "IO", package: "IO"),
                .product(name: "Readers", package: "Readers"),
                .product(name: "Writers", package: "Writers"),
                .product(name: "Arguments", package: "Arguments"),
            ]
        ),
        .target(
            name: "ExecutableLegacy",
            dependencies: [
                "Executable",
                .product(name: "Path", package: "Path"),
                .product(name: "plate", package: "plate"),
                .product(name: "Interfaces", package: "Interfaces"),
                .product(name: "Version", package: "Version"),
                .product(name: "Parsers", package: "Parsers"),
                .product(name: "Arguments", package: "Arguments"),
                .product(name: "Terminal", package: "Terminal"),
            ]
        ),
    ]
)
