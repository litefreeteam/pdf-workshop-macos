import Foundation
import PDFKit

public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func cancel() { lock.lock(); value = true; lock.unlock() }
    public func check() throws {
        lock.lock(); let cancelled = value; lock.unlock()
        if cancelled { throw SplitError.cancelled }
    }
}

public struct SplitRequest: Sendable {
    public let source: URL
    public let destination: URL
    public let maximumBytes: Int
    public let password: String?
    public init(source: URL, destination: URL, maximumBytes: Int, password: String? = nil) {
        self.source = source; self.destination = destination
        self.maximumBytes = maximumBytes; self.password = password
    }
}

public struct SplitPart: Identifiable, Sendable {
    public let id: Int
    public let url: URL
    public let firstPage: Int
    public let lastPage: Int
    public let byteCount: Int
    public var pageCount: Int { lastPage - firstPage + 1 }
}

public struct SplitResult: Sendable {
    public let folder: URL
    public let parts: [SplitPart]
    public let sourcePageCount: Int
}

public struct SplitProgress: Sendable {
    public let completedPages: Int
    public let totalPages: Int
    public let partCount: Int
}

public enum SplitError: LocalizedError {
    case invalidLimit, unreadable, locked, restricted, empty, cancelled, serialization(Int), verification
    case oversizedPage(page: Int, bytes: Int, limit: Int)
    public var errorDescription: String? {
        switch self {
        case .invalidLimit: return "请输入有效的大小上限（0.01–100,000 MB）。"
        case .unreadable: return "无法读取这个 PDF。请检查文件是否完整、是否仍在本机。"
        case .locked: return "PDF 密码不正确，请重新解锁。"
        case .restricted: return "此 PDF 限制了页面提取。请使用有权限的版本。"
        case .empty: return "这个 PDF 没有可以拆分的页面。"
        case .cancelled: return "拆分已取消，未保留不完整文件。"
        case .serialization(let page): return "无法导出第 \(page) 页。原文件未作修改。"
        case .verification: return "导出校验未通过，未保留不完整文件。"
        case .oversizedPage(let page, let bytes, let limit):
            return "第 \(page) 页单独导出为 \(Self.size(bytes))，超过 \(Self.size(limit)) 上限。请提高上限，或先压缩该页面。未导出不完整结果。"
        }
    }
    public static func size(_ bytes: Int) -> String {
        if bytes < 1_000_000 { return String(format: "%.1f KB", Double(bytes) / 1_000) }
        return String(format: "%.2f MB", Double(bytes) / 1_000_000)
    }
}

public enum SplitEngine {
    /// Each accepted slice is measured using the exact Data written to disk.
    /// Exponential search followed by binary search avoids serializing every prefix.
    /// PDF sizes need not be monotonic; this may produce extra parts, but cannot exceed the cap.
    public static func run(
        _ request: SplitRequest,
        cancellation: CancellationFlag = CancellationFlag(),
        progress: @Sendable (SplitProgress) -> Void = { _ in }
    ) throws -> SplitResult {
        guard request.maximumBytes >= 10_000, request.maximumBytes <= 100_000_000_000 else {
            throw SplitError.invalidLimit
        }
        try cancellation.check()
        guard let source = PDFDocument(url: request.source) else { throw SplitError.unreadable }
        if source.isLocked {
            guard let password = request.password, source.unlock(withPassword: password) else {
                throw SplitError.locked
            }
        }
        guard source.allowsCopying && source.allowsDocumentAssembly else { throw SplitError.restricted }
        let pageCount = source.pageCount
        guard pageCount > 0 else { throw SplitError.empty }
        let fileManager = FileManager.default
        let staging = request.destination.appendingPathComponent(".pdfsplit-\(UUID().uuidString).partial", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? fileManager.removeItem(at: staging) } }
        let originalStem = request.source.deletingPathExtension().lastPathComponent
        let stem = String(originalStem.prefix(48))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let folderBase = "\(stem)_拆分_\(formatter.string(from: Date()))"
        var finalFolder = request.destination.appendingPathComponent(folderBase, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: finalFolder.path) {
            finalFolder = request.destination.appendingPathComponent("\(folderBase)_\(suffix)", isDirectory: true)
            suffix += 1
        }

        func serialize(from start: Int, count: Int) throws -> Data {
            try cancellation.check()
            return try autoreleasepool {
                let part = PDFDocument()
                if let attributes = source.documentAttributes {
                    part.documentAttributes = attributes
                }
                for index in start..<(start + count) {
                    try cancellation.check()
                    guard let page = source.page(at: index)?.copy() as? PDFPage else {
                        throw SplitError.serialization(index + 1)
                    }
                    part.insert(page, at: part.pageCount)
                }
                guard let data = part.dataRepresentation(), !data.isEmpty else {
                    throw SplitError.serialization(start + 1)
                }
                return data
            }
        }

        var start = 0
        var parts: [SplitPart] = []
        progress(SplitProgress(completedPages: 0, totalPages: pageCount, partCount: 0))
        while start < pageCount {
            try cancellation.check()
            let remaining = pageCount - start
            var acceptedCount = 1
            var acceptedData = try serialize(from: start, count: 1)
            guard acceptedData.count <= request.maximumBytes else {
                throw SplitError.oversizedPage(page: start + 1, bytes: acceptedData.count, limit: request.maximumBytes)
            }
            var rejectedCount: Int?
            var candidateCount = min(2, remaining)
            while candidateCount > acceptedCount {
                let candidateData = try serialize(from: start, count: candidateCount)
                if candidateData.count <= request.maximumBytes {
                    acceptedCount = candidateCount
                    acceptedData = candidateData
                    if acceptedCount == remaining { break }
                    candidateCount = min(acceptedCount * 2, remaining)
                } else {
                    rejectedCount = candidateCount
                    break
                }
            }
            if let rejected = rejectedCount {
                var low = acceptedCount + 1
                var high = rejected - 1
                while low <= high {
                    let middle = low + (high - low) / 2
                    let candidateData = try serialize(from: start, count: middle)
                    if candidateData.count <= request.maximumBytes {
                        acceptedCount = middle; acceptedData = candidateData; low = middle + 1
                    } else { high = middle - 1 }
                }
            }
            try cancellation.check()
            let first = start + 1
            let last = start + acceptedCount
            let filename = String(format: "%@_%03d_p%03d-%03d.pdf", stem, parts.count + 1, first, last)
            let temporaryURL = staging.appendingPathComponent(filename)
            guard acceptedData.count <= request.maximumBytes else { throw SplitError.verification }
            try acceptedData.write(to: temporaryURL, options: .atomic)
            try autoreleasepool {
                guard let verified = PDFDocument(url: temporaryURL), !verified.isLocked,
                      verified.pageCount == acceptedCount,
                      (try temporaryURL.resourceValues(forKeys: [.fileSizeKey])).fileSize == acceptedData.count else {
                    throw SplitError.verification
                }
            }
            parts.append(SplitPart(id: parts.count + 1, url: finalFolder.appendingPathComponent(filename),
                                   firstPage: first, lastPage: last, byteCount: acceptedData.count))
            start += acceptedCount
            progress(SplitProgress(completedPages: start, totalPages: pageCount, partCount: parts.count))
        }
        try cancellation.check()
        // The final folder only becomes visible after every part has passed verification.
        try fileManager.moveItem(at: staging, to: finalFolder)
        committed = true
        return SplitResult(folder: finalFolder, parts: parts, sourcePageCount: pageCount)
    }
}
