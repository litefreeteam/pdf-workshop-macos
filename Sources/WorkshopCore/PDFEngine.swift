import AppKit
import PDFKit

public enum WorkshopError: LocalizedError {
    case message(String)
    public var errorDescription: String? {
        if case .message(let message) = self { return message }
        return nil
    }
}

public enum PDFEngine {
    /// A detached, unencrypted snapshot of the current page order, rotations and replacements.
    /// Call while the document is owned by the UI thread; pass only the returned Data to workers.
    public static func snapshot(_ document: PDFDocument) throws -> Data {
        guard document.allowsCopying && document.allowsDocumentAssembly else {
            throw WorkshopError.message("此 PDF 限制了页面提取或组装。请使用有权限的版本。")
        }
        let copy = PDFDocument()
        copy.documentAttributes = document.documentAttributes
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index)?.copy() as? PDFPage else {
                throw WorkshopError.message("无法读取第 \(index + 1) 页。")
            }
            copy.insert(page, at: copy.pageCount)
        }
        guard copy.pageCount > 0, let data = copy.dataRepresentation() else {
            throw WorkshopError.message("无法生成当前文档的副本。")
        }
        return data
    }

    public static func displaySize(_ page: PDFPage) -> CGSize {
        let bounds = page.bounds(for: .mediaBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        return rotation == 90 || rotation == 270
            ? CGSize(width: bounds.height, height: bounds.width) : bounds.size
    }

    public static func png(_ page: PDFPage, dpi: Int) throws -> Data {
        guard let source = page.pageRef else { throw WorkshopError.message("无法读取这一页。") }
        let size = displaySize(page)
        let width = Int((size.width * Double(dpi) / 72).rounded())
        let height = Int((size.height * Double(dpi) / 72).rounded())
        guard width > 0, height > 0, width <= 20000, height <= 20000,
              Double(width) * Double(height) <= 100_000_000 else {
            throw WorkshopError.message("页面尺寸过大，请选择较低的 DPI 后重试。")
        }
        guard let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw WorkshopError.message("内存不足，无法生成图片。请降低 DPI 后重试。")
        }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(rect)
        context.scaleBy(x: Double(width) / size.width, y: Double(height) / size.height)
        let extraRotation = Int32(page.rotation) - source.rotationAngle
        context.concatenate(source.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: size),
                                                       rotate: extraRotation, preserveAspectRatio: true))
        context.interpolationQuality = .high
        context.drawPDFPage(source)
        guard let cgImage = context.makeImage(),
              let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
            throw WorkshopError.message("图片编码失败。")
        }
        return data
    }

    public static func imagePage(from url: URL, fitting target: CGSize?) throws -> PDFPage {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw WorkshopError.message("无法读取图片：\(url.lastPathComponent)\n支持 PNG、JPG、TIFF 和 HEIC。")
        }
        let size = target ?? CGSize(width: Double(cgImage.width) * 72 / 300,
                                    height: Double(cgImage.height) * 72 / 300)
        var bounds = CGRect(origin: .zero, size: size)
        let data = NSMutableData()
        guard size.width > 0, size.height > 0,
              let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
            throw WorkshopError.message("无法创建图片页面。")
        }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(bounds)
        let scale = min(size.width / Double(cgImage.width), size.height / Double(cgImage.height))
        let drawn = CGSize(width: Double(cgImage.width) * scale, height: Double(cgImage.height) * scale)
        let rect = CGRect(x: (size.width - drawn.width) / 2, y: (size.height - drawn.height) / 2,
                          width: drawn.width, height: drawn.height)
        context.interpolationQuality = .high
        context.draw(cgImage, in: rect)
        context.endPDFPage()
        context.closePDF()
        guard let doc = PDFDocument(data: data as Data), let page = doc.page(at: 0) else {
            throw WorkshopError.message("无法生成 PDF 页面。")
        }
        return page
    }

    public static func pageNumber(in url: URL) -> Int? {
        let name = url.deletingPathExtension().lastPathComponent
        let patterns = ["(?i)(?:^|[_ -])page[-_ ]?(\\d+)$", "第\\s*(\\d+)\\s*页$"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let range = Range(match.range(at: 1), in: name) else { continue }
            return Int(name[range])
        }
        return nil
    }

    public static func export(_ document: PDFDocument, indexes: [Int], dpi: Int, to parent: URL,
                       stem: String, progress: (Int, Int) -> Void) throws -> URL {
        let manager = FileManager.default
        let safeStem = String(stem.prefix(48))
        var folder = parent.appendingPathComponent(safeStem + "_页面图片", isDirectory: true)
        var suffix = 2
        while manager.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent(safeStem + "_页面图片 \(suffix)", isDirectory: true)
            suffix += 1
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        do {
            for (done, index) in indexes.enumerated() {
                try autoreleasepool {
                    guard let page = document.page(at: index) else { throw WorkshopError.message("页面不存在。") }
                    let filename = String(format: "page-%04d.png", index + 1)
                    try png(page, dpi: dpi).write(to: folder.appendingPathComponent(filename), options: .atomic)
                    progress(done + 1, indexes.count)
                }
            }
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
        return folder
    }
}
