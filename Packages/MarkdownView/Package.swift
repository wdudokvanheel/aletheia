// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MarkdownView",
    platforms: [.macOS("26.0")],
    products: [.library(name: "MarkdownView", targets: ["MarkdownView"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-cmark", exact: "0.9.0")],
    targets: [
        .target(name: "MarkdownView", dependencies: [.product(name: "cmark-gfm", package: "swift-cmark"), .product(name: "cmark-gfm-extensions", package: "swift-cmark")]),
        .executableTarget(name: "MarkdownViewBench", dependencies: ["MarkdownView"], exclude: ["README.md"]),
        .testTarget(name: "MarkdownViewTests", dependencies: ["MarkdownView"])
    ],
    swiftLanguageModes: [.v6]
)
