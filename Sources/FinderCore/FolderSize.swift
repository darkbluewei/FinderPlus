import Foundation

public enum SizeCalculator {
    /// 递归统计一个文件夹（不跟随符号链接）。被取消时返回 nil。
    public static func compute(_ root: URL, isCancelled: () -> Bool = { false }) -> DirSize? {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        let keySet = Set(keys)
        var result = DirSize()
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return result
        }
        var counter = 0
        for case let u as URL in en {
            counter += 1
            if counter % 256 == 0 && isCancelled() { return nil }
            guard let rv = try? u.resourceValues(forKeys: keySet) else { continue }
            let isDir = rv.isDirectory ?? false
            let isLink = rv.isSymbolicLink ?? false
            if isDir && !isLink {
                result.folders += 1
            } else {
                result.files += 1
                result.bytes += Int64(rv.fileSize ?? 0)
                result.allocated += Int64(rv.totalFileAllocatedSize ?? 0)
            }
        }
        if isCancelled() { return nil }
        return result
    }
}

/// 在后台限流（同时最多几个）计算文件夹大小，带缓存，可整体取消。
public final class FolderSizeService: @unchecked Sendable {
    private let queue: OperationQueue
    private let lock = NSLock()
    private var cache: [URL: DirSize] = [:]
    private var inflight: Set<URL> = []
    private var waiters: [URL: [(URL, DirSize) -> Void]] = [:]
    private var generation = 0

    public init(maxConcurrent: Int = 4) {
        queue = OperationQueue()
        queue.maxConcurrentOperationCount = maxConcurrent
        queue.qualityOfService = .utility
    }

    public func cached(_ url: URL) -> DirSize? {
        lock.lock()
        defer { lock.unlock() }
        return cache[url]
    }

    /// 请求计算；结果通过 completion 回调（后台线程）。已缓存则立即回调。
    public func request(_ url: URL, completion: @escaping (URL, DirSize) -> Void) {
        lock.lock()
        if let c = cache[url] {
            lock.unlock()
            completion(url, c)
            return
        }
        if inflight.contains(url) {
            waiters[url, default: []].append(completion)
            lock.unlock()
            return
        }
        inflight.insert(url)
        waiters[url] = [completion]
        let gen = generation
        lock.unlock()

        let op = BlockOperation()
        op.addExecutionBlock { [weak self, weak op] in
            guard let self = self else { return }
            let r = SizeCalculator.compute(url, isCancelled: { op?.isCancelled ?? true })
            var callbacks: [(URL, DirSize) -> Void] = []
            self.lock.lock()
            if gen == self.generation {
                self.inflight.remove(url)
                callbacks = self.waiters.removeValue(forKey: url) ?? []
                if let r = r { self.cache[url] = r }
            }
            self.lock.unlock()
            if let r = r {
                for cb in callbacks { cb(url, r) }
            }
        }
        queue.addOperation(op)
    }

    /// 取消所有未完成的计算（导航离开时调用）
    public func cancelAll() {
        queue.cancelAllOperations()
        lock.lock()
        inflight.removeAll()
        waiters.removeAll()
        generation += 1
        lock.unlock()
    }

    /// 文件变动后，让该路径及其所有上级目录的缓存失效
    public func invalidate(containing url: URL) {
        let p = url.standardizedFileURL.path
        lock.lock()
        for key in Array(cache.keys) {
            let kp = key.standardizedFileURL.path
            if p == kp || p.hasPrefix(kp.hasSuffix("/") ? kp : kp + "/") {
                cache.removeValue(forKey: key)
            }
        }
        lock.unlock()
        cancelAll()
    }

    public func clearCache() {
        lock.lock()
        cache.removeAll()
        lock.unlock()
        cancelAll()
    }
}
