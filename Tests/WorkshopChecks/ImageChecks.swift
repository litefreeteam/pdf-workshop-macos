import AppKit
import WorkshopCore
import PDFKit

func runSelfTests() throws {
    func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw WorkshopError.message(message) }
    }
    let explicit = ProcessInfo.processInfo.environment["PDF_WORKSHOP_TEST_DIR"]
    let destination = explicit ?? NSTemporaryDirectory() + "PDFWorkshopChecks-" + UUID().uuidString
    let folder = URL(fileURLWithPath: destination, isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { if explicit == nil { try? FileManager.default.removeItem(at: folder) } }
    let sampleURL = folder.appendingPathComponent("sample.pdf")
    var bounds = CGRect(x: 0, y: 0, width: 360, height: 504)
    guard let consumer = CGDataConsumer(url: sampleURL as CFURL),
          let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw WorkshopError.message("test context") }
    for index in 0..<3 {
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(bounds)
        context.setFillColor(CGColor(red: 0.12, green: 0.35, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 24, y: 420, width: 312, height: 60))
        context.setFillColor(CGColor(red: 0.85, green: 0.12, blue: 0.15, alpha: 1))
        context.fill(CGRect(x: 24, y: 24, width: 80 + index * 30, height: 90))
        context.setStrokeColor(CGColor(gray: 0.3, alpha: 1)); context.setLineWidth(1)
        for y in stride(from: 160, through: 380, by: 22) {
            context.move(to: CGPoint(x: 28, y: y)); context.addLine(to: CGPoint(x: 332, y: y)); context.strokePath()
        }
        context.endPDFPage()
    }
    context.closePDF()
    guard let document = PDFDocument(url: sampleURL), let first = document.page(at: 0) else { throw WorkshopError.message("test read") }
    try expect(document.pageCount == 3, "sample page count")
    let png = try PDFEngine.png(first, dpi: 150)
    let firstURL = folder.appendingPathComponent("page-0001.png")
    try png.write(to: firstURL)
    let bitmap = NSBitmapImageRep(data: png)!
    try expect(bitmap.pixelsWide == 750 && bitmap.pixelsHigh == 1050, "150 dpi dimensions")
    // Verify orientation: the blue band must remain at the top and red block at the bottom.
    let top = bitmap.colorAt(x: 100, y: 100)!.usingColorSpace(.deviceRGB)!
    let bottom = bitmap.colorAt(x: 100, y: 950)!.usingColorSpace(.deviceRGB)!
    try expect(top.blueComponent > 0.6 && top.redComponent < 0.3, "unrotated top blue")
    try expect(bottom.redComponent > 0.7 && bottom.blueComponent < 0.3, "unrotated bottom red")
    first.rotation = 90
    let rotated = try PDFEngine.png(first, dpi: 150)
    try rotated.write(to: folder.appendingPathComponent("rotated.png"))
    let rotatedBitmap = NSBitmapImageRep(data: rotated)!
    try expect(rotatedBitmap.pixelsWide == 1050 && rotatedBitmap.pixelsHigh == 750, "rotation dimensions")
    let right = rotatedBitmap.colorAt(x: 950, y: 100)!.usingColorSpace(.deviceRGB)!
    try expect(right.blueComponent > 0.6 && right.redComponent < 0.3, "clockwise rotation direction")
    let replacement = try PDFEngine.imagePage(from: firstURL, fitting: PDFEngine.displaySize(first))
    try expect(replacement.rotation == 0, "replacement rotation reset")
    try expect(replacement.bounds(for: .mediaBox).width == 504, "replacement physical width")
    document.removePage(at: 0); document.insert(replacement, at: 0)
    let output = folder.appendingPathComponent("roundtrip.pdf")
    try expect(document.write(to: output), "roundtrip save")
    guard let reopened = PDFDocument(url: output), let restored = reopened.page(at: 0) else { throw WorkshopError.message("roundtrip reopen") }
    try expect(reopened.pageCount == 3, "roundtrip count")
    try expect(PDFEngine.displaySize(restored) == CGSize(width: 504, height: 360), "roundtrip physical size")
    try PDFEngine.png(restored, dpi: 150).write(to: folder.appendingPathComponent("roundtrip.png"))
    let batch = try PDFEngine.export(reopened, indexes: [0, 2], dpi: 150, to: folder, stem: "batch") { _, _ in }
    try expect(FileManager.default.fileExists(atPath: batch.appendingPathComponent("page-0003.png").path), "batch original page numbers")
    let secondBatch = try PDFEngine.export(reopened, indexes: [1], dpi: 150, to: folder, stem: "batch") { _, _ in }
    try expect(secondBatch != batch, "export never overwrites folder")
    try expect(PDFEngine.pageNumber(in: URL(fileURLWithPath: "page-0012.png")) == 12, "filename matching")
    try expect(PDFEngine.pageNumber(in: URL(fileURLWithPath: "第3页.png")) == 3, "Chinese filename matching")
    // Split the edited in-memory document, rather than accidentally reopening the source file.
    let originalBytes = try Data(contentsOf: sampleURL)
    guard let lastPage = document.page(at: 2)?.copy() as? PDFPage else { throw WorkshopError.message("copy page") }
    lastPage.rotation = 270
    document.removePage(at: 2); document.insert(lastPage, at: 0)
    let snapshotURL = folder.appendingPathComponent("edited-snapshot.pdf")
    try PDFEngine.snapshot(document).write(to: snapshotURL)
    let split = try SplitEngine.run(SplitRequest(source: snapshotURL, destination: folder, maximumBytes: 5_000_000))
    guard let splitDoc = PDFDocument(url: split.parts[0].url), let splitFirst = splitDoc.page(at: 0),
          let splitSecond = splitDoc.page(at: 1) else { throw WorkshopError.message("split edited output") }
    try expect(splitDoc.pageCount == 3, "split current page count")
    try expect(splitFirst.rotation == 270, "split includes reordered rotated page")
    try expect(PDFEngine.displaySize(splitSecond) == CGSize(width: 504, height: 360), "split includes replacement dimensions")
    let expectedPNG = try PDFEngine.png(document.page(at: 0)!, dpi: 150)
    let actualPNG = try PDFEngine.png(splitFirst, dpi: 150)
    try expect(expectedPNG == actualPNG, "split preserves current edited page image")
    let after = try Data(contentsOf: sampleURL)
    try expect(originalBytes == after, "editing and splitting leave original unchanged")
    do {
        _ = try PDFEngine.imagePage(from: folder.appendingPathComponent("missing.png"), fitting: nil)
        throw WorkshopError.message("bad image accepted")
    } catch let error as WorkshopError {
        try expect(error.localizedDescription.contains("无法读取图片"), "bad image error")
    }
    print("PASS: PNG dimensions, orientation, clockwise rotation, image replacement, page size, PDF roundtrip, batch export, collision protection, filename matching, invalid image handling.")
    if explicit != nil { print("Test artifacts: \(folder.path)") }
}
