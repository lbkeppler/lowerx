// swift-tools-version:5.9
import PackageDescription

// LowerX — controle do HyperX Cloud Stinger 2 Wireless na barra de menus.
// `./build-app.sh` gera LowerX.app; `swift run` roda direto do terminal.
let package = Package(
    name: "LowerX",
    platforms: [.macOS("14.2")],
    targets: [
        .executableTarget(name: "LowerX", path: "Sources/LowerX")
    ]
)
