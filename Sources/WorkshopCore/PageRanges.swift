import Foundation

public enum PageRangeError: LocalizedError {
    case empty, invalid(String), outOfBounds(Int, Int), reversed(Int, Int), overlap(Int)
    public var errorDescription: String? {
        switch self {
        case .empty: return "请输入页码范围，例如 1-3, 4-6, 7。每组导出一份 PDF。"
        case .invalid(let group): return "无法识别「\(group)」。请用 1-3 表示连续页面，用逗号分隔文件。"
        case .outOfBounds(let page, let total): return "页码 \(page) 超出范围，请输入 1–\(total) 之间的页码。"
        case .reversed(let first, let last): return "范围 \(first)-\(last) 的起始页大于结束页，请调整顺序。"
        case .overlap(let page): return "第 \(page) 页被重复选择，请检查各组是否重叠。"
        }
    }
}

public enum PageRanges {
    /// Commas (including Chinese commas), semicolons and newlines separate output files.
    /// Each file contains one inclusive range. File order follows the user's input.
    public static func parse(_ expression: String, pageCount: Int) throws -> [ClosedRange<Int>] {
        let input = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { throw PageRangeError.empty }
        let normalized = input.replacingOccurrences(of: "，", with: ",")
            .replacingOccurrences(of: "；", with: ",").replacingOccurrences(of: ";", with: ",")
            .replacingOccurrences(of: "\r\n", with: ",").replacingOccurrences(of: "\n", with: ",")
            .replacingOccurrences(of: "\r", with: ",")
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
            .replacingOccurrences(of: "－", with: "-")
        let ranges = try normalized.components(separatedBy: ",").map { group -> ClosedRange<Int> in
            let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
            let ends = trimmed.components(separatedBy: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            guard ends.count == 1 || ends.count == 2,
                  ends.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { $0 >= 48 && $0 <= 57 } }),
                  let first = Int(ends[0]), let last = Int(ends.last!) else {
                throw PageRangeError.invalid(String(trimmed.prefix(40)))
            }
            guard first <= last else { throw PageRangeError.reversed(first, last) }
            guard first >= 1, first <= pageCount else { throw PageRangeError.outOfBounds(first, pageCount) }
            guard last <= pageCount else { throw PageRangeError.outOfBounds(last, pageCount) }
            return first...last
        }
        try validate(ranges, pageCount: pageCount)
        return ranges
    }

    /// Validate again inside the engine so callers cannot bypass UI/parser checks.
    public static func validate(_ ranges: [ClosedRange<Int>], pageCount: Int) throws {
        guard !ranges.isEmpty else { throw PageRangeError.empty }
        for range in ranges {
            guard range.lowerBound >= 1, range.lowerBound <= pageCount else {
                throw PageRangeError.outOfBounds(range.lowerBound, pageCount)
            }
            guard range.upperBound <= pageCount else {
                throw PageRangeError.outOfBounds(range.upperBound, pageCount)
            }
        }
        let sorted = ranges.sorted { $0.lowerBound < $1.lowerBound }
        for index in 1..<sorted.count {
            if sorted[index].lowerBound <= sorted[index - 1].upperBound {
                throw PageRangeError.overlap(sorted[index].lowerBound)
            }
        }
    }
}
