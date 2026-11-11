import Foundation

/// 文件夹递归统计结果
public struct DirSize: Hashable {
    public var bytes: Int64
    public var allocated: Int64
    public var files: Int
    public var folders: Int

    public init(bytes: Int64 = 0, allocated: Int64 = 0, files: Int = 0, folders: Int = 0) {
        self.bytes = bytes
        self.allocated = allocated
        self.files = files
        self.folders = folders
    }
}

/// 一个文件或文件夹的快照信息
public struct FileItem: Identifiable, Hashable {
    public let url: URL
    public let name: String
    public let nameKey: String
    public let isDirectory: Bool
    public let isPackage: Bool
    public let isSymlink: Bool
    public let isHidden: Bool
    public let fileSize: Int64
    public let allocatedSize: Int64
    public let modified: Date?
    public let created: Date?
    public let kind: String
    public var folderInfo: DirSize?

    public var id: URL { url }
    /// 普通文件夹（可进入）。.app 等包按文件处理。
    public var isFolder: Bool { isDirectory && !isPackage }
    /// 需要递归统计大小（文件夹和包，符号链接除外）
    public var needsFolderSize: Bool { isDirectory && !isSymlink }
    public var sizeBytes: Int64? { needsFolderSize ? folderInfo?.bytes : fileSize }
    public var sortSize: Int64 { sizeBytes ?? -1 }
    public var modifiedSort: Date { modified ?? Date.distantPast }
    public var createdSort: Date { created ?? Date.distantPast }
    public var ext: String { url.pathExtension.lowercased() }
    public var parentPath: String { url.deletingLastPathComponent().path }

    public static let resourceKeys: [URLResourceKey] = [
        .nameKey, .isDirectoryKey, .isPackageKey, .isSymbolicLinkKey, .isHiddenKey,
        .fileSizeKey, .fileAllocatedSizeKey, .contentModificationDateKey,
        .creationDateKey, .localizedTypeDescriptionKey
    ]

    public init(url: URL) {
        self.url = url
        let rv = try? url.resourceValues(forKeys: Set(FileItem.resourceKeys))
        let n = rv?.name ?? url.lastPathComponent
        self.name = n
        self.nameKey = n.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        self.isDirectory = rv?.isDirectory ?? false
        self.isPackage = rv?.isPackage ?? false
        self.isSymlink = rv?.isSymbolicLink ?? false
        self.isHidden = rv?.isHidden ?? n.hasPrefix(".")
        self.fileSize = Int64(rv?.fileSize ?? 0)
        self.allocatedSize = Int64(rv?.fileAllocatedSize ?? 0)
        self.modified = rv?.contentModificationDate
        self.created = rv?.creationDate
        self.kind = rv?.localizedTypeDescription ?? ""
        self.folderInfo = nil
    }
}

public enum DirectoryLister {
    public static func list(_ dir: URL, showHidden: Bool) throws -> [FileItem] {
        let fm = FileManager.default
        let opts: FileManager.DirectoryEnumerationOptions = showHidden ? [] : [.skipsHiddenFiles]
        let urls = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: FileItem.resourceKeys, options: opts)
        return urls.map { FileItem(url: $0) }
    }
}
