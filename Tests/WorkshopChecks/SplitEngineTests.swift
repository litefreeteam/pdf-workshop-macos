import PDFKit
import CoreGraphics
import CoreText
import CryptoKit
import WorkshopCore

final class SplitEngineTests {
    private var folder: URL!
    func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("PDFSplitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    func tearDownWithError() throws { try FileManager.default.removeItem(at: folder) }

    func testActualSizesPageOrderImageFidelityAndOriginalUnchanged() throws {
        let source = try fixture(pages: 9)
        let before = try Data(contentsOf: source)
        let result = try SplitEngine.run(SplitRequest(source: source, destination: folder, maximumBytes: 200_000))
        XCTAssertGreaterThan(result.parts.count, 1)
        XCTAssertEqual(result.sourcePageCount, 9)
        let original = try XCTUnwrap(PDFDocument(url: source))
        var pageNumber = 0
        for part in result.parts {
            let data = try Data(contentsOf: part.url)
            XCTAssertLessThanOrEqual(data.count, 200_000)
            XCTAssertEqual(data.count, part.byteCount)
            XCTAssertEqual(part.firstPage, pageNumber + 1)
            let document = try XCTUnwrap(PDFDocument(data: data))
            XCTAssertEqual(document.pageCount, part.pageCount)
            for index in 0..<document.pageCount {
                let exported = try XCTUnwrap(document.page(at: index))
                let expected = try XCTUnwrap(original.page(at: pageNumber))
                XCTAssertEqual(exported.string, expected.string, "Page order must stay unchanged")
                XCTAssertEqual(render(exported), render(expected), "Page pixels must stay unchanged")
                pageNumber += 1
            }
        }
        XCTAssertEqual(pageNumber, 9)
        XCTAssertEqual(SHA256.hash(data: before), SHA256.hash(data: try Data(contentsOf: source)))
        XCTAssertFalse(try children().contains { $0.hasPrefix(".pdfsplit-") })
    }

    func testOnePartWhenBelowLimitAndRepeatDoesNotOverwrite() throws {
        let source = try fixture(pages: 2)
        let request = SplitRequest(source: source, destination: folder, maximumBytes: 5_000_000)
        let first = try SplitEngine.run(request)
        let second = try SplitEngine.run(request)
        XCTAssertEqual(first.parts.count, 1)
        XCTAssertEqual(first.parts.first?.pageCount, 2)
        XCTAssertNotEqual(first.folder, second.folder)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.parts[0].url.path))
    }

    func testExactByteBoundary() throws {
        let source = try fixture(pages: 1)
        let reference = try SplitEngine.run(SplitRequest(source: source, destination: folder, maximumBytes: 1_000_000))
        let exactSize = reference.parts[0].byteCount
        let exact = try SplitEngine.run(SplitRequest(source: source, destination: folder, maximumBytes: exactSize))
        XCTAssertEqual(exact.parts[0].byteCount, exactSize)
        XCTAssertThrowsError(try SplitEngine.run(SplitRequest(source: source, destination: folder, maximumBytes: exactSize - 1))) { error in
            guard case SplitError.oversizedPage = error else { return XCTFail("Unexpected: \(error)") }
        }
    }

    func testOversizedSinglePageAndLateFailureLeaveNoPartialOutput() throws {
        let source = try fixture(pages: 3, smallFirstPage: true)
        let before = Set(try children())
        XCTAssertThrowsError(try SplitEngine.run(SplitRequest(source: source, destination: folder, maximumBytes: 10_000))) { error in
            guard case SplitError.oversizedPage(let page, _, _) = error else { return XCTFail("Unexpected: \(error)") }
            XCTAssertEqual(page, 2)
        }
        XCTAssertEqual(Set(try children()), before)
    }

    func testCancellationRemovesAlreadyWrittenParts() throws {
        let source = try fixture(pages: 6)
        let before = Set(try children())
        let flag = CancellationFlag()
        XCTAssertThrowsError(try SplitEngine.run(SplitRequest(source: source, destination: folder, maximumBytes: 100_000), cancellation: flag) { progress in
            if progress.completedPages > 0 { flag.cancel() }
        }) { error in
            guard case SplitError.cancelled = error else { return XCTFail("Unexpected: \(error)") }
        }
        XCTAssertEqual(Set(try children()), before)
    }

    func testInvalidFileAndInvalidLimits() throws {
        let source = folder.appendingPathComponent("not-a-pdf.pdf")
        try Data("not a pdf".utf8).write(to: source)
        XCTAssertThrowsError(try SplitEngine.run(SplitRequest(source: source, destination: folder, maximumBytes: 1_000_000)))
        for limit in [0, -1, 9_999, 100_000_000_001] {
            XCTAssertThrowsError(try SplitEngine.run(SplitRequest(source: source, destination: folder, maximumBytes: limit)))
        }
    }

    func testEncryptedPDFNeedsCorrectPasswordAndExportsReadableCopy() throws {
        let source = try fixture(pages: 2)
        let protected = folder.appendingPathComponent("protected.pdf")
        let pdf = try XCTUnwrap(PDFDocument(url: source))
        XCTAssertTrue(pdf.write(to: protected, withOptions: [.ownerPasswordOption: "owner", .userPasswordOption: "secret"]))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(url: protected)).isLocked)
        XCTAssertThrowsError(try SplitEngine.run(SplitRequest(source: protected, destination: folder, maximumBytes: 1_000_000)))
        XCTAssertThrowsError(try SplitEngine.run(SplitRequest(source: protected, destination: folder, maximumBytes: 1_000_000, password: "wrong")))
        let result = try SplitEngine.run(SplitRequest(source: protected, destination: folder, maximumBytes: 1_000_000, password: "secret"))
        let output = try XCTUnwrap(PDFDocument(url: result.parts[0].url))
        XCTAssertFalse(output.isLocked)
        XCTAssertEqual(output.pageCount, 2)
    }

    private func children() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path)
    }

    private func fixture(pages: Int, smallFirstPage: Bool = false) throws -> URL {
        let url = folder.appendingPathComponent("sample.pdf")
        var box = CGRect(x: 0, y: 0, width: 360, height: 480)
        let consumer = try XCTUnwrap(CGDataConsumer(url: url as CFURL))
        let context = try XCTUnwrap(CGContext(consumer: consumer, mediaBox: &box, nil))
        var seed: UInt64 = 0x987654321
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box)
            if !(smallFirstPage && page == 0) {
                let side = 160
                var pixels = [UInt8](repeating: 255, count: side * side * 4)
                for offset in stride(from: 0, to: pixels.count, by: 4) {
                    for channel in 0..<3 {
                        seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                        pixels[offset + channel] = UInt8(truncatingIfNeeded: seed)
                    }
                }
                let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
                let image = try XCTUnwrap(CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32,
                                                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                context.draw(image, in: CGRect(x: 30, y: 100, width: 300, height: 300))
            }
            let string = NSAttributedString(string: String(format: "PAGE %03d", page + 1), attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 24, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
            ])
            context.textPosition = CGPoint(x: 30, y: 435)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private func render(_ page: PDFPage) -> Data {
        let context = CGContext(data: nil, width: 360, height: 480, bitsPerComponent: 8, bytesPerRow: 360 * 4,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 360, height: 480))
        page.draw(with: .mediaBox, to: context)
        return Data(bytes: context.data!, count: 360 * 480 * 4)
    }
}
