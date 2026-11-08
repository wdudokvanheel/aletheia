import AppKit
import PDFKit
import XCTest
@testable import Aletheia

final class NativePreviewTests: XCTestCase {
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor private func png(width: Int = 16) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width,
            pixelsHigh: 12, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for y in 0..<12 { for x in 0..<width { bitmap.setColor(NSColor(deviceRed: 0.1, green: 0.4, blue: 0.8, alpha: 1), atX: x, y: y) } }
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor private func pdf(locked: Bool = false) throws -> Data {
        let image = try XCTUnwrap(NSImage(data: png()))
        let page = try XCTUnwrap(PDFPage(image: image))
        let widget = PDFAnnotation(bounds: CGRect(x: 1, y: 1, width: 8, height: 8),
                                   forType: .widget, withProperties: nil)
        widget.widgetFieldType = .text
        widget.fieldName = "sample"
        widget.widgetStringValue = "original"
        page.addAnnotation(widget)
        let document = PDFDocument()
        document.insert(page, at: 0)
        return try XCTUnwrap(locked
            ? document.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "secret", PDFDocumentWriteOption.ownerPasswordOption: "owner"])
            : document.dataRepresentation())
    }

    @MainActor private func waitUntil(_ condition: () -> Bool,
                                     file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(8)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "Timed out waiting for preview state", file: file, line: line)
    }

    @MainActor func testNativeViewsAreLazyReadOnlyAndPreserveBinaryBytes() throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, data) in [("form.PDF", try pdf()), ("picture.PNG", try png())] {
            let url = root.appendingPathComponent(name)
            try data.write(to: url)
            let file = try DocumentFile.read(url)
            XCTAssertFalse(file.isText)
            XCTAssertTrue(file.matches(try file.reread()))
            XCTAssertThrowsError(try file.save("replacement text")) {
                guard case PreviewFile.LoadError.readOnly = $0 else { return XCTFail("Unexpected error: \($0)") }
            }
            let document = EditorDocument(file: file)
            XCTAssertFalse(document.isEditable)
            XCTAssertFalse(document.isDirty)
            XCTAssertNil(document.nativePreview)
            if name.hasSuffix("PDF") {
                let view = try XCTUnwrap(document.contentView as? PDFView)
                XCTAssertEqual(view.document?.pageCount, 1)
                let widget = try XCTUnwrap(view.document?.page(at: 0)?.annotations.first { $0.type == "Widget" })
                XCTAssertTrue(widget.isReadOnly)
                XCTAssertEqual(widget.widgetStringValue, "original")
            } else {
                let view = try XCTUnwrap(document.contentView as? NSImageView)
                XCTAssertTrue(try XCTUnwrap(view.image).isValid)
                XCTAssertFalse(view.isEditable)
                XCTAssertEqual(view.imageScaling, .scaleProportionallyDown)
            }
            XCTAssertNotNil(document.nativePreview)
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    @MainActor func testRejectsInvalidImagesCorruptAndLockedPDFs() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["broken.pdf", "broken.png"] {
            let url = root.appendingPathComponent(name)
            try Data("not a preview".utf8).write(to: url)
            XCTAssertThrowsError(try DocumentFile.read(url))
        }
        let url = root.appendingPathComponent("locked.pdf")
        try pdf(locked: true).write(to: url)
        XCTAssertThrowsError(try DocumentFile.read(url)) {
            guard case PreviewFile.LoadError.lockedPDF = $0 else { return XCTFail("Unexpected error: \($0)") }
        }
    }

    @MainActor func testMixedRestoreSelectionSymlinkDedupeAndSourceSearch() async throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let text = root.appendingPathComponent("source.txt")
        let pdfURL = root.appendingPathComponent("form.pdf")
        let image = root.appendingPathComponent("picture.png")
        let alias = root.appendingPathComponent("alias")
        try Data("find me".utf8).write(to: text)
        try pdf().write(to: pdfURL)
        try png().write(to: image)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: pdfURL)
        let aliasFile = try DocumentFile.read(alias)
        XCTAssertEqual(aliasFile.requestedURL, alias)
        XCTAssertEqual(aliasFile.url, pdfURL)
        XCTAssertFalse(aliasFile.isText)
        let controller = EditorWindow()
        defer { controller.window?.close() }
        let paths = [text, pdfURL, image].map(\.path)
        var restored = false
        controller.restore(WindowSession(frame: CGRect(x: 100, y: 100, width: 900, height: 600),
            rootPath: root.path, filePaths: paths, selectedPath: image.path)) { skipped in
            XCTAssertTrue(skipped.isEmpty)
            restored = true
        }
        try await waitUntil { restored }
        XCTAssertEqual(controller.documents.map { $0.file.url.path }, paths)
        XCTAssertEqual(controller.session.filePaths, paths)
        XCTAssertEqual(controller.session.selectedPath, image.path)
        XCTAssertNil(controller.documents[1].nativePreview)
        XCTAssertTrue(controller.documents[2].contentView is NSImageView)
        controller.openFile(text)
        controller.showReplace(nil)
        XCTAssertFalse(controller.findBar.isHidden)
        controller.openFile(alias)
        XCTAssertEqual(controller.documents.count, 3)
        XCTAssertEqual(controller.session.selectedPath, pdfURL.path)
        XCTAssertTrue(controller.documents[1].contentView is PDFView)
        XCTAssertTrue(controller.findBar.isHidden)
        controller.showFind(nil)
        controller.showReplace(nil)
        XCTAssertTrue(controller.findBar.isHidden)
        let before = try Data(contentsOf: pdfURL)
        controller.saveSelected(nil)
        XCTAssertNil(controller.window?.attachedSheet)
        XCTAssertEqual(try Data(contentsOf: pdfURL), before)
    }

    @MainActor func testAtomicReplacementReloadsCleanPreviewAndCloseNeedsNoSaveSheet() async throws {
        _ = NSApplication.shared
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("picture.png")
        try png().write(to: url)
        let controller = EditorWindow()
        defer { controller.window?.close() }
        controller.openFile(url)
        try await waitUntil { controller.documents.count == 1 }
        let document = try XCTUnwrap(controller.documents.first)
        let originalView = document.contentView
        let replacement = try png(width: 32)
        try replacement.write(to: url, options: .atomic)
        controller.checkDiskChanges()
        try await waitUntil {
            guard case .preview(let file) = document.file else { return false }
            return file.data == replacement
        }
        XCTAssertFalse(document.isDirty)
        XCTAssertFalse(document.contentView === originalView)
        let view = try XCTUnwrap(document.contentView as? NSImageView)
        XCTAssertEqual(view.image?.representations.first?.pixelsWide, 32)
        XCTAssertNil(controller.window?.attachedSheet)
        // Close immediately after removal, before a watcher can present a read-error sheet.
        try FileManager.default.removeItem(at: url)
        document.diskUnavailable = true
        XCTAssertFalse(document.isDirty)
        controller.closeSelectedTab(nil)
        XCTAssertTrue(controller.documents.isEmpty)
        XCTAssertNil(controller.window?.attachedSheet)
    }
}
