// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Aletheia",
    platforms: [.macOS("26.0")],
    products: [.executable(name: "Aletheia", targets: ["Aletheia"])],
    dependencies: [.package(url: "https://github.com/CreatureSurvive/SwiftHighlight.git", exact: "1.0.0"), .package(path: "Packages/MarkdownView")],
    targets: [
        .executableTarget(name: "Aletheia", dependencies: [.product(name: "SwiftHighlight", package: "SwiftHighlight"), .product(name: "MarkdownView", package: "MarkdownView")], resources: [.copy("Resources/FileIcons"), .copy("Resources/AppMetadata.plist"), .copy("Resources/Preview"), .copy("Resources/ThemeLicenses.md"), .copy("Resources/SwiftHighlight.LICENSE"), .copy("Resources/swift-cmark.COPYING")]),
        .testTarget(name: "AletheiaTests", dependencies: ["Aletheia"])
    ],
    swiftLanguageModes: [.v6]
)
