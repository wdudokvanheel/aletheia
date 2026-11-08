import AppKit
import PDFKit

/// Retained by its tab, so switching tabs preserves native PDF navigation and zoom.
@MainActor
final class NativePreview {
    let view: NSView

    init(file: PreviewFile) {
        switch file.kind {
        case .pdf:
            let pdf = PDFDocument(data: file.data)!
            // PDFKit normally permits filling forms. These tabs are viewers only.
            for index in 0..<pdf.pageCount {
                for annotation in pdf.page(at: index)?.annotations ?? [] where annotation.type == "Widget" {
                    annotation.isReadOnly = true
                }
            }
            let pdfView = PDFView()
            pdfView.displayMode = .singlePageContinuous
            pdfView.displayDirection = .vertical
            pdfView.autoScales = true
            pdfView.document = pdf
            view = pdfView
        case .image:
            let image = NSImageView()
            image.image = NSImage(data: file.data)
            image.imageScaling = .scaleProportionallyDown
            image.imageAlignment = .alignCenter
            image.isEditable = false
            image.animates = false
            view = image
        }
        applyTheme()
    }

    func applyTheme() {
        (view as? PDFView)?.backgroundColor = AppSettings.shared.palette.background
    }
}
