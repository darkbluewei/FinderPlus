import Foundation

public enum ConflictPolicy {
    case keepBoth
    case replace
    case skip
}

public enum FileOpError: LocalizedError {
    case invalidName(String)
    case exists(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let m): return m
        case .exists(let n): return "“\(n)”已存在，请换一个名称"
        case .failed(let m): return m
        }
    }
}

public struct MovedPair: Equatable {
    public let from: URL
    public let to: URL
    public init(from: URL, to: URL) {
        self.from = from
        self.to = to
    }
}

/// 批量操作结果：成功的、失败的都会记录，单个失败不会中断其他项目
public struct OpOutcome {
    public var done: [MovedPair] = []
    public var failures: [String] = []
    public var cancelled = false
    public init() {}
}

public final class FileOperations {
    private let fm = FileManager.default

    public init() {}

    // MARK: 基础工具

    /// 用 lstat 判断是否存在（悬空符号链接也算存在）
    public func exists(_ url: URL) -> Bool {
        return (try? fm.attributesOfItem(atPath: url.path)) != nil
    }

    public func samePath(_ a: URL, _ b: URL) -> Bool {
        return a.standardizedFileURL.path == b.standardizedFileURL.path
    }

    /// child 是否位于 parent 内部（或就是 parent）
    public func isInside(_ child: URL, of parent: URL) -> Bool {
        let c = child.standardizedFileURL.path
        let p = parent.standardizedFileURL.path
        if c == p { return true }
        return c.hasPrefix(p.hasSuffix("/") ? p : p + "/")
    }

    public func sameVolume(_ a: URL, _ b: URL) -> Bool {
        let va = try? a.resourceValues(forKeys: [.volumeURLKey]).volumeURL
        let vb = try? b.resourceValues(forKeys: [.volumeURLKey]).volumeURL
        guard let x = va, let y = vb else { return false }
        return x == y
    }

    /// 生成不重名的目标地址：name.ext → name 2.ext → name 3.ext
    public func uniqueURL(_ url: URL) -> URL {
        if !exists(url) { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let rv = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let plainFolder = (rv?.isDirectory ?? false) && !(rv?.isPackage ?? false)
        let useExt = !plainFolder && !ext.isEmpty
        let base = useExt ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
        var n = 2
        while true {
            let candidateName = useExt ? "\(base) \(n).\(ext)" : "\(base) \(n)"
            let candidate = dir.appendingPathComponent(candidateName)
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// 粘贴/拖拽前检查：哪些来源在目标目录里已有同名项目
    public func conflicts(sources: [URL], in dir: URL) -> [String] {
        var names: [String] = []
        for src in sources {
            let dest = dir.appendingPathComponent(src.lastPathComponent)
            if samePath(src, dest) { continue }
            if exists(dest) { names.append(src.lastPathComponent) }
        }
        return names
    }

    private func isDirectoryURL(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    // MARK: 复制 / 移动

    public func copy(_ sources: [URL], to dir: URL, policy: ConflictPolicy,
                     progress: ((Int, Int) -> Void)? = nil,
                     isCancelled: () -> Bool = { false }) -> OpOutcome {
        var out = OpOutcome()
        for (i, src) in sources.enumerated() {
            if isCancelled() { out.cancelled = true; break }
            progress?(i, sources.count)
            let name = src.lastPathComponent
            var dest = dir.appendingPathComponent(name)
            if isDirectoryURL(src) && isInside(dir, of: src) {
                out.failures.append("无法把文件夹“\(name)”复制到它自己的内部")
                continue
            }
            if samePath(src, dest) {
                dest = uniqueURL(dest)            // 在原位置复制 = 创建副本
            } else if exists(dest) {
                switch policy {
                case .skip:
                    continue
                case .keepBoth:
                    dest = uniqueURL(dest)
                case .replace:
                    do {
                        try fm.trashItem(at: dest, resultingItemURL: nil)
                    } catch {
                        out.failures.append("\(name)：无法替换已有项目（\(error.localizedDescription)）")
                        continue
                    }
                }
            }
            do {
                try fm.copyItem(at: src, to: dest)
                out.done.append(MovedPair(from: src, to: dest))
            } catch {
                out.failures.append("\(name)：\(error.localizedDescription)")
            }
        }
        progress?(sources.count, sources.count)
        return out
    }

    public func move(_ sources: [URL], to dir: URL, policy: ConflictPolicy,
                     progress: ((Int, Int) -> Void)? = nil,
                     isCancelled: () -> Bool = { false }) -> OpOutcome {
        var out = OpOutcome()
        for (i, src) in sources.enumerated() {
            if isCancelled() { out.cancelled = true; break }
            progress?(i, sources.count)
            let name = src.lastPathComponent
            var dest = dir.appendingPathComponent(name)
            if samePath(src, dest) { continue }   // 已经在这里了
            if isInside(dir, of: src) {
                out.failures.append("无法把“\(name)”移动到它自己的内部")
                continue
            }
            if exists(dest) {
                switch policy {
                case .skip:
                    continue
                case .keepBoth:
                    dest = uniqueURL(dest)
                case .replace:
                    do {
                        try fm.trashItem(at: dest, resultingItemURL: nil)
                    } catch {
                        out.failures.append("\(name)：无法替换已有项目（\(error.localizedDescription)）")
                        continue
                    }
                }
            }
            do {
                try fm.moveItem(at: src, to: dest)
                out.done.append(MovedPair(from: src, to: dest))
            } catch {
                out.failures.append("\(name)：\(error.localizedDescription)")
            }
        }
        progress?(sources.count, sources.count)
        return out
    }

    // MARK: 废纸篓

    /// 移到废纸篓（可在访达里“放回原处”）。pair.to 是废纸篓中的新位置。
    public func trash(_ urls: [URL]) -> OpOutcome {
        var out = OpOutcome()
        for u in urls {
            do {
                var result: NSURL?
                try fm.trashItem(at: u, resultingItemURL: &result)
                let dest: URL = (result as URL?) ?? u
                out.done.append(MovedPair(from: u, to: dest))
            } catch {
                out.failures.append("\(u.lastPathComponent)：\(error.localizedDescription)")
            }
        }
        return out
    }

    // MARK: 重命名 / 新建

    public func validateName(_ name: String) throws {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { throw FileOpError.invalidName("名称不能为空") }
        if name.contains("/") { throw FileOpError.invalidName("名称不能包含“/”") }
        if name.contains("\0") { throw FileOpError.invalidName("名称包含无效字符") }
        if t == "." || t == ".." { throw FileOpError.invalidName("名称无效") }
        if name.utf8.count > 255 { throw FileOpError.invalidName("名称太长") }
    }

    @discardableResult
    public func rename(_ url: URL, to newName: String) throws -> URL {
        try validateName(newName)
        let dir = url.deletingLastPathComponent()
        let dest = dir.appendingPathComponent(newName)
        if dest.path == url.path { return url }
        let caseOnly = dest.path.lowercased() == url.path.lowercased()
        if caseOnly {
            // 大小写不敏感的磁盘上，仅改大小写需要经过临时名
            let tmp = dir.appendingPathComponent(".fp-\(UUID().uuidString).tmp")
            try fm.moveItem(at: url, to: tmp)
            do {
                try fm.moveItem(at: tmp, to: dest)
            } catch {
                try? fm.moveItem(at: tmp, to: url)
                throw error
            }
            return dest
        }
        if exists(dest) { throw FileOpError.exists(newName) }
        try fm.moveItem(at: url, to: dest)
        return dest
    }

    @discardableResult
    public func newFolder(in dir: URL, name: String = "未命名文件夹") throws -> URL {
        let url = uniqueURL(dir.appendingPathComponent(name))
        try fm.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    @discardableResult
    public func newFile(in dir: URL, name: String) throws -> URL {
        let url = uniqueURL(dir.appendingPathComponent(name))
        guard fm.createFile(atPath: url.path, contents: Data()) else {
            throw FileOpError.failed("无法创建文件“\(name)”")
        }
        return url
    }

    // MARK: 压缩

    /// 用系统自带的 /usr/bin/zip 压缩，生成在 dir 下
    public func compress(_ urls: [URL], in dir: URL) throws -> URL {
        guard let first = urls.first else { throw FileOpError.failed("没有选中项目") }
        let baseName: String
        if urls.count == 1 {
            baseName = isDirectoryURL(first) ? first.lastPathComponent : first.deletingPathExtension().lastPathComponent
        } else {
            baseName = "归档"
        }
        let out = uniqueURL(dir.appendingPathComponent(baseName + ".zip"))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.currentDirectoryURL = dir
        var args = ["-r", "-q", "-y", out.lastPathComponent]
        for u in urls {
            if u.deletingLastPathComponent().standardizedFileURL.path == dir.standardizedFileURL.path {
                let n = u.lastPathComponent
                args.append(n.hasPrefix("-") ? "./" + n : n)
            } else {
                args.append(u.path)
            }
        }
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0, exists(out) else {
            throw FileOpError.failed("压缩失败（zip 返回 \(p.terminationStatus)）")
        }
        return out
    }
}

// MARK: - 撤销

public enum UndoAction {
    case moved([MovedPair])     // 移动 / 重命名：撤销 = 搬回 from
    case copied([URL])          // 复制 / 压缩：撤销 = 把新建的移到废纸篓
    case trashed([MovedPair])   // 移到废纸篓：撤销 = 从废纸篓放回
    case created([URL])         // 新建文件夹/文件：撤销 = 移到废纸篓
}

public final class OperationHistory {
    private var stack: [(title: String, action: UndoAction)] = []

    public init() {}

    public var canUndo: Bool { return !stack.isEmpty }
    public var lastTitle: String? { return stack.last?.title }

    public func push(_ title: String, _ action: UndoAction) {
        stack.append((title: title, action: action))
        if stack.count > 50 { stack.removeFirst() }
    }

    public func undo(using ops: FileOperations) -> (title: String, outcome: OpOutcome)? {
        guard let entry = stack.popLast() else { return nil }
        let fm = FileManager.default
        var out = OpOutcome()
        switch entry.action {
        case .moved(let pairs), .trashed(let pairs):
            for p in pairs.reversed() {
                if ops.exists(p.from) {
                    out.failures.append("原位置已存在“\(p.from.lastPathComponent)”，无法撤销")
                    continue
                }
                do {
                    try fm.moveItem(at: p.to, to: p.from)
                    out.done.append(MovedPair(from: p.to, to: p.from))
                } catch {
                    out.failures.append("\(p.from.lastPathComponent)：\(error.localizedDescription)")
                }
            }
        case .copied(let urls), .created(let urls):
            for u in urls {
                do {
                    try fm.trashItem(at: u, resultingItemURL: nil)
                    out.done.append(MovedPair(from: u, to: u))
                } catch {
                    out.failures.append("\(u.lastPathComponent)：\(error.localizedDescription)")
                }
            }
        }
        return (title: entry.title, outcome: out)
    }
}
