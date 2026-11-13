import AppKit

/// A small native preferences page. All preference storage stays in the existing models.
@MainActor
final class SettingsPage: NSViewController {
    /// `fills` stretches the content to the page's full height instead of its natural one.
    init(title: String, content: NSView, fills: Bool = false) {
        super.init(nibName: nil, bundle: nil)
        self.title = title
        let container = NSView()
        container.addSubview(content)
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 32),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -32),
            content.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            fills ? content.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -28)
                : content.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -28)
        ])
        view = container
        preferredContentSize = NSSize(width: 700, height: 590)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        return label
    }

    static func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.textColor = .secondaryLabelColor
        return label
    }
}
