import SwiftUI
import AppKit
import FinderCore

/// 跨线程取消标记
final class CancelFlag: @unchecked Sendable {
    var value = false
}

enum SortKey: String, CaseIterable, Identifiable {
    case name, size, kind, modified, created

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "名称"
        case .size: return "大小"
        case .kind: return "种类"
        case .modified: return "修改日期"
        case .created: return "创建日期"
        }
    }

    func comparator(ascending: Bool) -> KeyPathComparator<FileItem> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch self {
        case .name: return KeyPathComparator(\FileItem.nameKey, order: order)
        case .size: return KeyPathComparator(\FileItem.sortSize, order: order)
        case .kind: return KeyPathComparator(\FileItem.kind, order: order)
        case .modified: return KeyPathComparator(\FileItem.modifiedSort, order: order)
        case .created: return KeyPathComparator(\FileItem.createdSort, order: order)
        }
    }

    static func from(_ c: KeyPathComparator<FileItem>) -> SortKey? {
        let kp: AnyKeyPath = c.keyPath
        if kp == (\FileItem.nameKey as AnyKeyPath) { return .name }
        if kp == (\FileItem.sortSize as AnyKeyPath) { return .size }
        if kp == (\FileItem.kind as AnyKeyPath) { return .kind }
        if kp == (\FileItem.modifiedSort as AnyKeyPath) { return .modified }
        if kp == (\FileItem.createdSort as AnyKeyPath) { return .created }
        return nil
    }
}

final class TabModel: ObservableObject, Identifiable {
    let id = UUID()
    weak var app: AppModel?

    @Published var url: URL
    @Published var items: [FileItem] = [] {
        didSet { resort() }
    }
    @Published private(set) var sortedItems: [FileItem] = []
    @Published var sortOrder: [KeyPathComparator<FileItem>] = [KeyPathComparator(\FileItem.nameKey)] {
        didSet { resort() }
    }
    @Published var selection: Set<URL> = [] {
        didSet {
            if selection != oldValue { requestSizes() }
        }
    }
    @Published var errorText: String?
    @Published var permissionIssue = false
    @Published var isLoading = false
    @Published var renamingURL: URL?
    @Published var analysisMode = false
    @Published var backStack: [URL] = []
    @Published var forwardStack: [URL] = []
    @Published var scrollTarget: URL?
    @Published var currentFolderInfo: DirSize?
    @Published var computingCurrentFolder = false
    @Published var addressDraft = ""

    // 搜索
    @Published var searchCriteria: SearchCriteria?
    @Published var isSearching = false

    var anchor: URL?
    var cursor: URL?

    private var pendingSelect: Set<URL>?
    private var pendingRename: URL?
    private var loadToken = 0
    private var searchToken = 0
    private var watchToken = 0
    private var searchCancel: CancelFlag?
    private var watcher: DirectoryWatcher?
    private var pendingSizes: [URL: DirSize] = [:]
    private var flushScheduled = false

    init(app: AppModel, url: URL) {
        self.app = app
        self.url = url
    }

    deinit {
        watcher?.stop()
    }

    var title: String {
        let n = url.lastPathComponent
        return n.isEmpty ? "/" : n
    }

    var sortKey: SortKey {
        if let first = sortOrder.first, let k = SortKey.from(first) { return k }
        return .name
    }

    var sortAscending: Bool {
        return sortOrder.first?.order != .reverse
    }

    func shutdown() {
        watcher?.stop()
        watcher = nil
        searchCancel?.value = true
        loadToken += 1
    }

    func resort() {
        let s = items.sorted(using: sortOrder)
        if app?.folderFirst ?? true {
            sortedItems = s.filter { $0.isFolder } + s.filter { !$0.isFolder }
        } else {
            sortedItems = s
        }
    }

    // MARK: 导航

    func navigate(to newURL: URL, pushHistory: Bool = true, select: Set<URL>? = nil) {
        let target = newURL.standardizedFileURL
        if pushHistory && target != url {
            backStack.append(url)
            forwardStack.removeAll()
        }
        cancelSearchState()
        url = target
        selection = []
        anchor = nil
        cursor = nil
        renamingURL = nil
        currentFolderInfo = nil
        app?.sizes.cancelAll()
        reload(select: select)
        app?.persistTabs()
    }

    func goBack() {
        guard let prev = backStack.popLast() else { return }
        forwardStack.append(url)
        navigate(to: prev, pushHistory: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(url)
        navigate(to: next, pushHistory: false)
    }

    func goUp() {
        let parent = url.deletingLastPathComponent()
        if parent.standardizedFileURL.path == url.standardizedFileURL.path { return }
        navigate(to: parent, select: [url])
    }

    // MARK: 加载

    func reload(select: Set<URL>? = nil, rename: URL? = nil) {
        if let s = select { pendingSelect = s }
        if let r = rename { pendingRename = r }
        if let c = searchCriteria {
            runSearch(c)
            return
        }
        loadToken += 1
        let token = loadToken
        let dir = url
        let hidden = app?.showHidden ?? false
        if items.isEmpty { isLoading = true }

        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<[FileItem], Error> in
                return Result(catching: { try DirectoryLister.list(dir, showHidden: hidden) })
            }.value
            guard let self = self, self.loadToken == token else { return }
            self.isLoading = false
            switch result {
            case .success(let loaded):
                var list = loaded
                if let svc = self.app?.sizes {
                    for i in list.indices where list[i].needsFolderSize {
                        if let info = svc.cached(list[i].url) { list[i].folderInfo = info }
                    }
                }
                self.errorText = nil
                self.permissionIssue = false
                self.items = list
                let present = Set(list.map { $0.url })
                if let ps = self.pendingSelect {
                    self.selection = ps.intersection(present)
                    if let first = self.selection.first { self.anchor = first; self.cursor = first }
                    self.pendingSelect = nil
                } else {
                    self.selection = self.selection.intersection(present)
                }
                if let pr = self.pendingRename, present.contains(pr) {
                    self.renamingURL = pr
                }
                self.pendingRename = nil
                self.requestSizes()
                self.startWatching()
            case .failure(let error):
                self.items = []
                self.selection = []
                self.permissionIssue = TabModel.isPermission(error)
                self.errorText = self.permissionIssue
                    ? "没有权限访问这个文件夹。"
                    : error.localizedDescription
            }
        }
    }

    static func isPermission(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain && (ns.code == NSFileReadNoPermissionError || ns.code == 257) { return true }
        if ns.domain == NSPOSIXErrorDomain && (ns.code == 1 || ns.code == 13) { return true }
        if let u = ns.userInfo[NSUnderlyingErrorKey] as? NSError { return isPermission(u) }
        return false
    }

    // MARK: 目录监视

    private func startWatching() {
        watcher?.stop()
        watcher = nil
        guard searchCriteria == nil else { return }
        watcher = DirectoryWatcher(url: url, onChange: { [weak self] in
            self?.scheduleWatchReload()
        })
    }

    private func scheduleWatchReload() {
        watchToken += 1
        let t = watchToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self = self, self.watchToken == t, self.searchCriteria == nil else { return }
            self.reload()
        }
    }

    // MARK: 文件夹大小

    func requestSizes() {
        guard let app = app, !items.isEmpty else { return }
        let all = app.showFolderSizes || analysisMode
        for item in items where item.needsFolderSize && item.folderInfo == nil {
            if all || selection.contains(item.url) {
                app.sizes.request(item.url) { [weak self] u, info in
                    Task { @MainActor in
                        self?.receiveSize(u, info)
                    }
                }
            }
        }
    }

    func receiveSize(_ u: URL, _ info: DirSize) {
        pendingSizes[u] = info
        if !flushScheduled {
            flushScheduled = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                self?.flushSizes()
            }
        }
    }

    private func flushSizes() {
        flushScheduled = false
        guard !pendingSizes.isEmpty else { return }
        var updated = items
        var index: [URL: Int] = [:]
        for (i, it) in updated.enumerated() { index[it.url] = i }
        for (u, info) in pendingSizes {
            if let i = index[u] { updated[i].folderInfo = info }
        }
        pendingSizes.removeAll()
        items = updated
    }

    func computeCurrentFolderSize() {
        guard let app = app else { return }
        computingCurrentFolder = true
        let dir = url
        app.sizes.request(dir) { [weak self] u, info in
            Task { @MainActor in
                guard let self = self, self.url == u else { return }
                self.currentFolderInfo = info
                self.computingCurrentFolder = false
            }
        }
    }

    // MARK: 搜索

    func startSearch(_ criteria: SearchCriteria) {
        searchCriteria = criteria
        selection = []
        runSearch(criteria)
    }

    private func runSearch(_ criteria: SearchCriteria) {
        searchCancel?.value = true
        let flag = CancelFlag()
        searchCancel = flag
        searchToken += 1
        let token = searchToken
        let root = url
        watcher?.stop()
        watcher = nil
        items = []
        isLoading = false
        errorText = nil
        isSearching = true

        Task.detached(priority: .userInitiated) { [weak self] in
            Searcher.search(root: root, criteria: criteria, maxResults: 5000, isCancelled: { flag.value }) { batch in
                Task { @MainActor in
                    self?.appendSearch(batch, token: token)
                }
            }
            await MainActor.run {
                self?.finishSearch(token: token)
            }
        }
    }

    private func appendSearch(_ batch: [FileItem], token: Int) {
        guard token == searchToken else { return }
        var list = batch
        if let svc = app?.sizes {
            for i in list.indices where list[i].needsFolderSize {
                if let info = svc.cached(list[i].url) { list[i].folderInfo = info }
            }
        }
        items.append(contentsOf: list)
    }

    private func finishSearch(token: Int) {
        guard token == searchToken else { return }
        isSearching = false
        requestSizes()
    }

    func clearSearch() {
        cancelSearchState()
        reload()
    }

    private func cancelSearchState() {
        searchCancel?.value = true
        searchCancel = nil
        searchToken += 1
        searchCriteria = nil
        isSearching = false
    }
}
