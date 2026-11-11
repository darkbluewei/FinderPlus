import Foundation

public struct ClipboardEntry: Identifiable, Codable, Equatable {
    public enum Kind: String, Codable {
        case text
        case files
        case image
    }

    public let id: UUID
    public var date: Date
    public let kind: Kind
    public let text: String?
    public let paths: [String]
    public let imageKey: String?
    public var pinned: Bool

    public init(id: UUID = UUID(), date: Date, kind: Kind, text: String?, paths: [String], imageKey: String?, pinned: Bool = false) {
        self.id = id
        self.date = date
        self.kind = kind
        self.text = text
        self.paths = paths
        self.imageKey = imageKey
        self.pinned = pinned
    }

    /// 列表里显示的第一行
    public var title: String {
        switch kind {
        case .text:
            let lines = (text ?? "").split(whereSeparator: { $0.isNewline })
            let first = lines.first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
            let line = String(first).trimmingCharacters(in: .whitespaces)
            return line.count > 80 ? String(line.prefix(80)) + "…" : line
        case .files:
            guard let first = paths.first else { return "文件" }
            let name = (first as NSString).lastPathComponent
            return paths.count == 1 ? name : "\(name) 等 \(paths.count) 项"
        case .image:
            return "图片"
        }
    }

    /// 第二行的简短说明
    public var detail: String {
        switch kind {
        case .text:
            let n = (text ?? "").count
            return "文字 · \(n) 个字符"
        case .files:
            return "文件 · \(paths.count) 项"
        case .image:
            return "图片"
        }
    }
}

public final class ClipboardHistory {
    /// 内部按时间从新到旧排列
    public private(set) var entries: [ClipboardEntry] = []
    public let limit: Int
    public let maxImages: Int
    public var maxTextLength = 20_000

    public init(limit: Int = 60, maxImages: Int = 8) {
        self.limit = limit
        self.maxImages = maxImages
    }

    /// 显示顺序：已固定的在最上面，其余按时间从新到旧
    public var ordered: [ClipboardEntry] {
        return entries.filter { $0.pinned } + entries.filter { !$0.pinned }
    }

    @discardableResult
    public func addText(_ s: String, now: Date = Date()) -> ClipboardEntry? {
        if s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        let t = s.count > maxTextLength ? String(s.prefix(maxTextLength)) : s
        return upsert(kind: .text, text: t, paths: [], imageKey: nil, now: now)
    }

    @discardableResult
    public func addFiles(_ paths: [String], now: Date = Date()) -> ClipboardEntry? {
        if paths.isEmpty { return nil }
        return upsert(kind: .files, text: nil, paths: paths, imageKey: nil, now: now)
    }

    @discardableResult
    public func addImage(key: String, now: Date = Date()) -> ClipboardEntry? {
        if key.isEmpty { return nil }
        return upsert(kind: .image, text: nil, paths: [], imageKey: key, now: now)
    }

    private func upsert(kind: ClipboardEntry.Kind, text: String?, paths: [String], imageKey: String?, now: Date) -> ClipboardEntry {
        if let i = entries.firstIndex(where: { $0.kind == kind && $0.text == text && $0.paths == paths && $0.imageKey == imageKey }) {
            var e = entries.remove(at: i)
            e.date = now
            entries.insert(e, at: 0)
            return e
        }
        let e = ClipboardEntry(date: now, kind: kind, text: text, paths: paths, imageKey: imageKey)
        entries.insert(e, at: 0)
        prune()
        return e
    }

    private func prune() {
        var imageCount = 0
        var drop = Set<UUID>()
        for e in entries where e.kind == .image {
            imageCount += 1
            if imageCount > maxImages && !e.pinned { drop.insert(e.id) }
        }
        if !drop.isEmpty { entries.removeAll { drop.contains($0.id) } }
        while entries.count > limit {
            if let i = entries.lastIndex(where: { !$0.pinned }) {
                entries.remove(at: i)
            } else {
                break
            }
        }
    }

    public func remove(id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public func clear(keepPinned: Bool = true) {
        if keepPinned {
            entries = entries.filter { $0.pinned }
        } else {
            entries = []
        }
    }

    public func togglePin(id: UUID) {
        if let i = entries.firstIndex(where: { $0.id == id }) {
            entries[i].pinned.toggle()
        }
    }

    // MARK: 保存 / 读取（图片只保留在本次运行中，不写入磁盘）

    public func save(to url: URL) throws {
        let persisted = entries.filter { $0.kind != .image }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(persisted)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    public func load(from url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let list = try? dec.decode([ClipboardEntry].self, from: data) else { return false }
        entries = list.filter { $0.kind != .image }.sorted { $0.date > $1.date }
        prune()
        return true
    }
}
