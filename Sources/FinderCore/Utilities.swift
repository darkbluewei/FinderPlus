import Foundation

// MARK: - 路径解析与补全

public enum PathParser {
    /// 把用户在地址栏输入/粘贴的文本解析成路径。支持 ~、引号、file:// 、终端风格的 "\ " 转义。
    public static func resolve(_ input: String, relativeTo base: URL? = nil) -> URL? {
        var s = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2 {
            if (s.hasPrefix("\"") && s.hasSuffix("\"")) || (s.hasPrefix("'") && s.hasSuffix("'")) {
                s = String(s.dropFirst().dropLast())
            }
        }
        if s.isEmpty { return nil }
        if s.hasPrefix("file://") {
            if let u = URL(string: s), u.isFileURL { return u.standardizedFileURL }
            return nil
        }
        s = s.replacingOccurrences(of: "\\ ", with: " ")
        s = (s as NSString).expandingTildeInPath
        if s.hasPrefix("/") {
            return URL(fileURLWithPath: s).standardizedFileURL
        }
        if let b = base {
            return b.appendingPathComponent(s).standardizedFileURL
        }
        return nil
    }
}

public enum PathCompleter {
    /// 返回以输入前缀开头的文件夹（完整路径，末尾带 /）
    public static func suggestions(for input: String, limit: Int = 8) -> [String] {
        let expanded = (input as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return [] }
        let dir: String
        let prefix: String
        if expanded.hasSuffix("/") {
            dir = expanded
            prefix = ""
        } else {
            dir = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent
        }
        let fm = FileManager.default
        let dirURL = URL(fileURLWithPath: dir.isEmpty ? "/" : dir)
        guard let items = try? fm.contentsOfDirectory(
            at: dirURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: prefix.hasPrefix(".") ? [] : [.skipsHiddenFiles]
        ) else { return [] }

        var result: [String] = []
        for u in items {
            let rv = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard (rv?.isDirectory ?? false) && !(rv?.isPackage ?? false) else { continue }
            let name = u.lastPathComponent
            if prefix.isEmpty || name.lowercased().hasPrefix(prefix.lowercased()) {
                result.append(u.path + "/")
            }
        }
        result.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return Array(result.prefix(limit))
    }

    /// 一组候选的最长公共前缀（用于 Tab 补全）
    public static func commonPrefix(_ items: [String]) -> String {
        guard var prefix = items.first else { return "" }
        for s in items.dropFirst() {
            while !s.lowercased().hasPrefix(prefix.lowercased()) && !prefix.isEmpty {
                prefix.removeLast()
            }
        }
        return prefix
    }
}

// MARK: - 格式化

public enum Format {
    public static func bytes(_ n: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useAll]
        return f.string(fromByteCount: n)
    }

    public static func exactBytes(_ n: Int64) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return (f.string(from: NSNumber(value: n)) ?? String(n)) + " 字节"
    }

    public static func date(_ d: Date?) -> String {
        guard let d = d else { return "—" }
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: d)
    }

    /// 0o755 → rwxr-xr-x
    public static func permissions(_ mode: Int) -> String {
        let t = ["---", "--x", "-w-", "-wx", "r--", "r-x", "rw-", "rwx"]
        return t[(mode >> 6) & 7] + t[(mode >> 3) & 7] + t[mode & 7]
    }
}

// MARK: - 选中项汇总

public struct SelectionSummary: Equatable {
    public struct KindCount: Equatable {
        public let kind: String
        public let count: Int
    }

    public var count = 0
    public var fileCount = 0
    public var folderCount = 0
    /// 选中项总大小；文件夹按递归大小计入（已算出的部分）
    public var totalBytes: Int64 = 0
    public var allocatedBytes: Int64 = 0
    /// 还没算出大小的文件夹个数
    public var pendingFolders = 0
    /// 选中的文件夹内部包含的文件/文件夹总数（已算出的部分）
    public var innerFiles = 0
    public var innerFolders = 0
    public var kinds: [KindCount] = []

    public init() {}

    public static func make(from items: [FileItem]) -> SelectionSummary {
        var s = SelectionSummary()
        var kindMap: [String: Int] = [:]
        for it in items {
            s.count += 1
            if it.isFolder { s.folderCount += 1 } else { s.fileCount += 1 }
            let k = it.kind.isEmpty ? (it.isFolder ? "文件夹" : "文件") : it.kind
            kindMap[k, default: 0] += 1
            if it.needsFolderSize {
                if let info = it.folderInfo {
                    s.totalBytes += info.bytes
                    s.allocatedBytes += info.allocated
                    s.innerFiles += info.files
                    s.innerFolders += info.folders
                } else {
                    s.pendingFolders += 1
                }
            } else {
                s.totalBytes += it.fileSize
                s.allocatedBytes += it.allocatedSize
            }
        }
        s.kinds = kindMap.map { KindCount(kind: $0.key, count: $0.value) }
            .sorted { a, b in
                if a.count != b.count { return a.count > b.count }
                return a.kind < b.kind
            }
        return s
    }
}

// MARK: - 目录监视

/// 监视一个目录的变化（新增/删除/重命名），变化时在主线程回调
public final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?

    public init?(url: URL, onChange: @escaping () -> Void) {
        let fd = open(url.path, O_EVTONLY)
        if fd < 0 { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: DispatchQueue.main
        )
        src.setEventHandler(handler: { onChange() })
        src.setCancelHandler(handler: { close(fd) })
        src.resume()
        self.source = src
    }

    public func stop() {
        source?.cancel()
        source = nil
    }

    deinit {
        source?.cancel()
    }
}
