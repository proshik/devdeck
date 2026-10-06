// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DevDeckPrototype",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "DevDeckPrototype", targets: ["DevDeckPrototype"])],
    targets: [.executableTarget(name: "DevDeckPrototype")]
)
