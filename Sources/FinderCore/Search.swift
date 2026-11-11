import Foundation

public struct SearchCriteria {
    public enum Scope {
        case any
        case filesOnly
        case foldersOnly
    }

    public var text: String = ""
    /// 小写、不带点，如 ["jpg", "png"]
    public var extensions: [String] = []
    public var minSize: Int64? = nil
    public var maxSize: Int64? = nil
    public var modifiedAfter: Date? = nil
    public var modifiedBefore: Date? = nil
    public var scope: Scope = .any
    public var includeHidden: Bool = false

    public init() {}

    public var isEmpty: Bool {
        return text.trimmingCharacters(in: .whitespaces).isEmpty
            && extensions.isEmpty
            && minSize == nil && maxSize == nil
            && modifiedAfter == nil && modifiedBefore == nil
            && scope == .any
    }

    /// 纯函数：判断一个文件是否满足条件（方便单元测试）
    public func matches(_ item: FileItem) -> Bool {
        if !includeHidden && item.isHidden { return false }

        switch scope {
        case .any: break
        case .filesOnly: if item.isFolder { return false }
        case .foldersOnly: if !item.isFolder { return false }
        }

        // 名称：空格分隔的多个词需要全部出现（不区分大小写）
        let tokens = text.split(separator: " ").map { String($0) }.filter { !$0.isEmpty }
        for t in tokens {
            if item.name.range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) == nil { return false }
        }

        if !extensions.isEmpty {
            if item.isFolder { return false }
            if !extensions.contains(item.ext) { return false }
        }

        if minSize != nil || maxSize != nil {
            if item.isFolder { return false }
            let s = item.fileSize
            if let mn = minSize, s < mn { return false }
            if let mx = maxSize, s > mx { return false }
        }

        if modifiedAfter != nil || modifiedBefore != nil {
            guard let m = item.modified else { return false }
            if let a = modifiedAfter, m < a { return false }
            if let b = modifiedBefore, m > b { return false }
        }
        return true
    }
}

public enum Searcher {
    /// 递归搜索。结果分批通过 onBatch 回调（在调用线程）。返回命中总数。
    @discardableResult
    public static func search(root: URL,
                              criteria: SearchCriteria,
                              maxResults: Int = 5000,
                              isCancelled: () -> Bool = { false },
                              onBatch: ([FileItem]) -> Void) -> Int {
        let fm = FileManager.default
        var opts: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !criteria.includeHidden { opts.insert(.skipsHiddenFiles) }
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: FileItem.resourceKeys,
                                     options: opts,
                                     errorHandler: { _, _ in true }) else { return 0 }
        var batch: [FileItem] = []
        var total = 0
        var visited = 0
        for case let u as URL in en {
            visited += 1
            if visited % 64 == 0 && isCancelled() { break }
            let item = FileItem(url: u)
            if criteria.matches(item) {
                batch.append(item)
                total += 1
                if batch.count >= 100 {
                    onBatch(batch)
                    batch.removeAll()
                }
                if total >= maxResults { break }
            }
        }
        if !batch.isEmpty { onBatch(batch) }
        return total
    }
}
