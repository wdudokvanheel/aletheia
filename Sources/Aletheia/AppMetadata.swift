import Foundation

/// Shared by SwiftPM launches and the installed app's Info.plist.
enum AppMetadata {
    private static let values: [String: String] = {
        guard let url = Bundle.module.url(forResource: "AppMetadata", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let values = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        else { preconditionFailure("Missing application metadata") }
        return values
    }()
    static var version: String { values["CFBundleShortVersionString"]! }
    static var build: String { values["CFBundleVersion"]! }
    static var description: String { values["ApplicationDescription"]! }
    static var title: String { "Aletheia \(version)" }
}
