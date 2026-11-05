// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aletheia",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Aletheia", targets: ["Aletheia"])],
    targets: [
        .executableTarget(name: "Aletheia"),
        .testTarget(name: "AletheiaTests", dependencies: ["Aletheia"])
    ],
    swiftLanguageModes: [.v6]
)
