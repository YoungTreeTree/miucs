// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Miucs",
    platforms: [.macOS(.v14)],
    products: [.library(name: "MiucsCore", type: .static, targets: ["MiucsCore"])],
    targets: [
        .target(
            name: "MiucsCore", path: ".",
            exclude: ["apps", "build", "contracts", "dist", "docs", "hardware", "scripts", "tests",
                      "third_party", "tools", "modules/plugins", "modules/visualizations",
                      "modules/audio/platforms/windows", "modules/keyboard/platforms/windows",
                      "build.sh", "project.yml", "README.md", "CONTRIBUTING.md"],
            sources: ["modules/audio/core", "modules/audio/platforms/macos",
                      "modules/keyboard/core", "modules/keyboard/platforms/macos", "modules/hardware/macos"],
            resources: [.copy("plugins")]
        ),
        .testTarget(name: "MiucsCoreTests", dependencies: ["MiucsCore"], path: "tests/core")
    ]
)
