import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FinderCore

enum ViewMode: String, CaseIterable, Identifiable {
    case icons, list, details, tiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icons: return "图标"
        case .list: return "列表"
        case .details: return "详细信息"
        case .tiles: return "平铺"
        }
    }

    var symbol: String {
        switch self {
        case .icons: return "square.grid.2x2"
        case .list: return "list.bullet"
        case .details: return "tablecells"
        case .tiles: return "rectangle.grid.1x2"
        }
    }
}

struct ConflictRequest: Identifiable {
    let id = UUID()
    let names: [String]
    let urls: [URL]
    let dir: URL
    let move: Bool
}

enum AppAlert: Identifiable {
    case message(title: String, text: String)
    case conflict(ConflictRequest)

    var id: String {
        switch self {
        case .message(let t, let x): return "m:" + t + x
        case .conflict(let r): return "c:" + r.id.uuidString
        }
    }
}

struct BatchRenameRequest: Identifiable {
    let id = UUID()
    let items: [FileItem]
}

/// 线程安全的小盒子，用来在后台回调里收集结果
final class URLBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URL] = []

    func add(_ u: URL) {
        lock.lock()
        storage.append(u)
        lock.unlock()
    }

    var urls: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class AppModel: ObservableObject {
    let ops = FileOperations()
    let history = OperationHistory()
    let sizes = FolderSizeService()

    @Published var tabs: [TabModel] = []
    @Published var activeTabID: UUID?
    @Published var favorites: [String] {
        didSet { UserDefaults.standard.set(favorites, forKey: "favorites.v1") }
    }
    @Published var showHidden: Bool {
        didSet {
            UserDefaults.standard.set(showHidden, forKey: "showHidden")
            for t in tabs { t.reload() }
        }
    }
    @Published var showFolderSizes: Bool {
        didSet {
            UserDefaults.standard.set(showFolderSizes, forKey: "showFolderSizes")
            activeTab?.requestSizes()
        }
    }
    @Published var folderFirst: Bool {
        didSet {
            UserDefaults.standard.set(folderFirst, forKey: "folderFirst")
            for t in tabs { t.resort() }
        }
    }
    @Published var viewMode: ViewMode {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    @Published var iconSize: Double {
        didSet { UserDefaults.standard.set(iconSize, forKey: "iconSize") }
    }
    @Published var showInfoPanel: Bool {
        didSet { UserDefaults.standard.set(showInfoPanel, forKey: "showInfoPanel") }
    }
    @Published var showSearchBar = false
    @Published var addressEditing = false
    @Published var alert: AppAlert?
    @Published var batchRename: BatchRenameRequest?
    @Published var cutURLs: Set<URL> = []
    @Published var busyText: String?
    @Published var statusFlash: String?
    @Published var volumes: [URL] = []
    @Published var undoTitle: String?

    // 剪贴板历史
    let clipboard = ClipboardHistory(limit: 60, maxImages: 8)
    @Published var clipboardEntries: [ClipboardEntry] = []
    @Published var clipboardRecording: Bool {
        didSet { UserDefaults.standard.set(clipboardRecording, forKey: "clipboardRecording") }
    }
    @Published var clipboardPanelOpen: Bool {
        didSet { UserDefaults.standard.set(clipboardPanelOpen, forKey: "clipboardPanelOpen") }
    }
    var clipboardImages: [UUID: NSImage] = [:]
    private var lastPasteboardChange = NSPasteboard.general.changeCount

    var clipboardIsCut = false
    var clipboardChangeCount = -1
    var draggingURLs: [URL] = []
    var draggingTabID: UUID?
    private var cancelFlag: CancelFlag?
    private var flashToken = 0

    init() {
        let d = UserDefaults.standard
        favorites = d.stringArray(forKey: "favorites.v1") ?? AppModel.defaultFavorites()
        showHidden = d.bool(forKey: "showHidden")
        showFolderSizes = d.bool(forKey: "showFolderSizes")
        folderFirst = (d.object(forKey: "folderFirst") as? Bool) ?? true
        viewMode = ViewMode(rawValue: d.string(forKey: "viewMode") ?? "") ?? .details
        iconSize = (d.object(forKey: "iconSize") as? Double) ?? 100
        showInfoPanel = (d.object(forKey: "showInfoPanel") as? Bool) ?? true
        clipboardRecording = (d.object(forKey: "clipboardRecording") as? Bool) ?? true
        clipboardPanelOpen = (d.object(forKey: "clipboardPanelOpen") as? Bool) ?? true

        let fm = FileManager.default
        var paths = (d.stringArray(forKey: "tabs.v1") ?? []).filter { p in
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: p, isDirectory: &isDir) && isDir.boolValue
        }
        if paths.isEmpty { paths = [fm.homeDirectoryForCurrentUser.path] }
        for p in paths {
            tabs.append(TabModel(app: self, url: URL(fileURLWithPath: p)))
        }
        let idx = min(max(d.integer(forKey: "activeTab.v1"), 0), tabs.count - 1)
        activeTabID = tabs[idx].id
        for t in tabs { t.reload() }

        refreshVolumes()
        clipboard.load(from: AppModel.clipboardFileURL)
        clipboardEntries = clipboard.ordered
        startClipboardMonitor()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshVolumes()
        }
        nc.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshVolumes()
        }
    }

    static func defaultFavorites() -> [String] {
        let fm = FileManager.default
        var list: [String] = [fm.homeDirectoryForCurrentUser.path]
        let dirs: [FileManager.SearchPathDirectory] = [.desktopDirectory, .documentDirectory, .downloadsDirectory]
        for dir in dirs {
            if let p = fm.urls(for: dir, in: .userDomainMask).first?.path { list.append(p) }
        }
        list.append("/Applications")
        return list.filter { fm.fileExists(atPath: $0) }
    }

    func refreshVolumes() {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeNameKey],
                                                         options: [.skipHiddenVolumes]) ?? []
        volumes = urls
    }

    // MARK: - 剪贴板历史

    static var clipboardFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("FinderPlus/clipboard-history.json")
    }

    private func startClipboardMonitor() {
        Task { @MainActor [weak self] in
            while let model = self {
                model.pollClipboard()
                try? await Task.sleep(nanoseconds: 600_000_000)
            }
        }
    }

    func pollClipboard() {
        let pb = NSPasteboard.general
        let change = pb.changeCount
        if change == lastPasteboardChange { return }
        lastPasteboardChange = change
        if !clipboardRecording { return }

        // 密码管理器等会把内容标记为“机密/临时”，这类内容不记录
        let secretTypes = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                           "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]
        let types = pb.types ?? []
        if types.contains(where: { secretTypes.contains($0.rawValue) }) { return }

        var recorded = false
        let fileObjs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        if let urls = fileObjs, !urls.isEmpty {
            recorded = clipboard.addFiles(urls.map { $0.path }) != nil
        } else if let text = pb.string(forType: .string) {
            recorded = clipboard.addText(text) != nil
        } else if let img = NSImage(pasteboard: pb), let tiff = img.tiffRepresentation {
            let key = "\(Int(img.size.width))x\(Int(img.size.height))-\(tiff.count)"
            if let entry = clipboard.addImage(key: key) {
                if clipboardImages[entry.id] == nil { clipboardImages[entry.id] = img }
                recorded = true
            }
        }
        if recorded { syncClipboard() }
    }

    private func syncClipboard() {
        let ids = Set(clipboard.entries.map { $0.id })
        clipboardImages = clipboardImages.filter { ids.contains($0.key) }
        clipboardEntries = clipboard.ordered
        try? clipboard.save(to: AppModel.clipboardFileURL)
    }

    func restoreClipboard(_ e: ClipboardEntry) {
        let pb = NSPasteboard.general
        switch e.kind {
        case .text:
            pb.clearContents()
            pb.setString(e.text ?? "", forType: .string)
        case .files:
            let urls = e.paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
            if urls.isEmpty {
                flash("这些文件已经不存在了")
                return
            }
            pb.clearContents()
            pb.writeObjects(urls.map { $0 as NSURL })
            clipboardIsCut = false
            cutURLs = []
        case .image:
            guard let img = clipboardImages[e.id] else { return }
            pb.clearContents()
            pb.writeObjects([img])
        }
        flash("已放回剪贴板")
    }

    func pasteClipboardFiles(_ e: ClipboardEntry) {
        guard let tab = activeTab else { return }
        let urls = e.paths.filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
        if urls.isEmpty {
            flash("这些文件已经不存在了")
            return
        }
        transfer(urls, to: tab.url, move: false)
    }

    func saveClipboardText(_ e: ClipboardEntry) {
        guard let tab = activeTab, tab.searchCriteria == nil, let text = e.text else { return }
        do {
            let url = try ops.newFile(in: tab.url, name: "剪贴板文本.txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            history.push("保存剪贴板文本", .created([url]))
            syncUndo()
            tab.reload(select: [url])
        } catch {
            showError("无法保存文本", error.localizedDescription)
        }
    }

    func toggleClipboardPin(_ e: ClipboardEntry) {
        clipboard.togglePin(id: e.id)
        syncClipboard()
    }

    func removeClipboardEntry(_ e: ClipboardEntry) {
        clipboard.remove(id: e.id)
        syncClipboard()
    }

    func clearClipboardHistory() {
        clipboard.clear(keepPinned: true)
        syncClipboard()
        flash("已清空剪贴板历史（已固定的保留）")
    }

    // MARK: - 标签页

    var activeTab: TabModel? {
        return tabs.first { $0.id == activeTabID }
    }

    var activeSelectedURLs: [URL] {
        guard let t = activeTab else { return [] }
        return t.sortedItems.filter { t.selection.contains($0.url) }.map { $0.url }
    }

    func persistTabs() {
        let d = UserDefaults.standard
        d.set(tabs.map { $0.url.path }, forKey: "tabs.v1")
        d.set(tabs.firstIndex { $0.id == activeTabID } ?? 0, forKey: "activeTab.v1")
    }

    func newTab(url: URL? = nil, activate: Bool = true) {
        let target = url ?? activeTab?.url ?? FileManager.default.homeDirectoryForCurrentUser
        let t = TabModel(app: self, url: target)
        if let current = activeTabID, let i = tabs.firstIndex(where: { $0.id == current }) {
            tabs.insert(t, at: i + 1)
        } else {
            tabs.append(t)
        }
        t.reload()
        if activate { selectTab(t.id) }
        persistTabs()
    }

    func selectTab(_ id: UUID) {
        activeTabID = id
        showSearchBar = activeTab?.searchCriteria != nil
        addressEditing = false
        activeTab?.requestSizes()
        persistTabs()
    }

    func selectNextTab(offset: Int) {
        guard tabs.count > 1, let i = tabs.firstIndex(where: { $0.id == activeTabID }) else { return }
        let n = (i + offset + tabs.count) % tabs.count
        selectTab(tabs[n].id)
    }

    func closeTab(_ id: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        if tabs.count == 1 {
            NSApp.keyWindow?.close()
            return
        }
        tabs[i].shutdown()
        tabs.remove(at: i)
        if activeTabID == id {
            activeTabID = tabs[min(i, tabs.count - 1)].id
            activeTab?.requestSizes()
        }
        persistTabs()
    }

    func closeActiveTab() {
        if let id = activeTabID { closeTab(id) }
    }

    func closeOtherTabs(keeping id: UUID) {
        for t in tabs where t.id != id { t.shutdown() }
        tabs.removeAll { $0.id != id }
        activeTabID = id
        persistTabs()
    }

    func moveTab(_ id: UUID, before target: UUID) {
        guard id != target,
              let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target }) else { return }
        let t = tabs.remove(at: from)
        let dest = tabs.firstIndex(where: { $0.id == target }) ?? to
        tabs.insert(t, at: dest)
        persistTabs()
    }

    // MARK: - 界面开关

    func setView(_ mode: ViewMode, size: Double? = nil) {
        viewMode = mode
        if let s = size { iconSize = s }
    }

    func toggleSearch() {
        showSearchBar.toggle()
    }

    func toggleAnalysis() {
        guard let t = activeTab else { return }
        t.analysisMode.toggle()
        t.requestSizes()
    }

    func focusAddressBar() {
        addressEditing = true
    }

    func reloadActive() {
        if let t = activeTab {
            sizes.invalidate(containing: t.url)
            t.reload()
        }
    }

    func flash(_ text: String) {
        statusFlash = text
        flashToken += 1
        let token = flashToken
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self = self, self.flashToken == token else { return }
            self.statusFlash = nil
        }
    }

    func showError(_ title: String, _ text: String) {
        alert = .message(title: title, text: text)
    }

    // MARK: - 选择

    func selectAll() {
        guard let t = activeTab else { return }
        t.selection = Set(t.sortedItems.map { $0.url })
    }

    // MARK: - 打开

    func open(_ urls: [URL], in tab: TabModel) {
        let fm = FileManager.default
        var folders: [URL] = []
        var files: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: u.path, isDirectory: &isDir)
            let isPkg = (try? u.resourceValues(forKeys: [.isPackageKey]).isPackage) ?? false
            if exists && isDir.boolValue && !isPkg { folders.append(u) } else { files.append(u) }
        }
        if folders.count == 1 && files.isEmpty {
            tab.navigate(to: folders[0])
            return
        }
        for f in folders { newTab(url: f, activate: false) }
        for f in files { NSWorkspace.shared.open(f) }
    }

    func openSelection() {
        guard let t = activeTab else { return }
        let urls = activeSelectedURLs
        if !urls.isEmpty { open(urls, in: t) }
    }

    func openWith(_ appURL: URL, _ urls: [URL]) {
        NSWorkspace.shared.open(urls, withApplicationAt: appURL,
                                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    func showInFinder(_ urls: [URL]? = nil) {
        let list = urls ?? activeSelectedURLs
        if list.isEmpty, let t = activeTab {
            NSWorkspace.shared.activateFileViewerSelecting([t.url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(list)
        }
    }

    func openTerminal(_ url: URL? = nil) {
        var target = url ?? activeTab?.url ?? FileManager.default.homeDirectoryForCurrentUser
        if url == nil, activeSelectedURLs.count == 1, let s = activeSelectedURLs.first {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: s.path, isDirectory: &isDir), isDir.boolValue { target = s }
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir), !isDir.boolValue {
            target = target.deletingLastPathComponent()
        }
        let term = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        NSWorkspace.shared.open([target], withApplicationAt: term,
                                configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
    }

    func copyPaths(_ urls: [URL]? = nil) {
        let list = urls ?? activeSelectedURLs
        let paths: [String]
        if list.isEmpty, let t = activeTab { paths = [t.url.path] } else { paths = list.map { $0.path } }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
        flash("已拷贝路径")
    }

    func copyNames(_ urls: [URL]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(urls.map { $0.lastPathComponent }.joined(separator: "\n"), forType: .string)
        flash("已拷贝名称")
    }

    // MARK: - 收藏夹

    func addFavorite(_ url: URL) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return }
        let p = url.standardizedFileURL.path
        if !favorites.contains(p) {
            favorites.append(p)
            flash("已添加到收藏夹")
        }
    }

    func addCurrentToFavorites() {
        if let t = activeTab { addFavorite(t.url) }
    }

    func removeFavorite(_ path: String) {
        favorites.removeAll { $0 == path }
    }

    func addFavoritesFromDrop(_ providers: [NSItemProvider]) -> Bool {
        return loadFileURLs(providers) { [weak self] urls in
            for u in urls { self?.addFavorite(u) }
        }
    }

    // MARK: - 剪贴板

    var canPaste: Bool {
        return NSPasteboard.general.canReadObject(forClasses: [NSURL.self],
                                                  options: [.urlReadingFileURLsOnly: true])
    }

    func copy(_ urls: [URL]? = nil) {
        putOnPasteboard(urls ?? activeSelectedURLs, cut: false)
    }

    func cut(_ urls: [URL]? = nil) {
        putOnPasteboard(urls ?? activeSelectedURLs, cut: true)
    }

    private func putOnPasteboard(_ urls: [URL], cut: Bool) {
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls.map { $0 as NSURL })
        clipboardIsCut = cut
        clipboardChangeCount = pb.changeCount
        cutURLs = cut ? Set(urls) : []
        flash(cut ? "已剪切 \(urls.count) 项，到目标位置粘贴即可移动" : "已拷贝 \(urls.count) 项")
    }

    func paste(into dir: URL? = nil) {
        guard let tab = activeTab else { return }
        let dest = dir ?? tab.url
        let pb = NSPasteboard.general
        let objs = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        let urls = objs ?? []
        guard !urls.isEmpty else { return }
        let isCut = clipboardIsCut && pb.changeCount == clipboardChangeCount
        transfer(urls, to: dest, move: isCut)
    }

    // MARK: - 复制 / 移动（含冲突处理、进度、取消）

    func transfer(_ urls: [URL], to dir: URL, move: Bool) {
        guard !urls.isEmpty else { return }
        let names = ops.conflicts(sources: urls, in: dir)
        if names.isEmpty {
            runTransfer(urls, dir, move, .keepBoth)
        } else {
            alert = .conflict(ConflictRequest(names: names, urls: urls, dir: dir, move: move))
        }
    }

    func resolveConflict(_ req: ConflictRequest, _ policy: ConflictPolicy) {
        alert = nil
        runTransfer(req.urls, req.dir, req.move, policy)
    }

    func cancelBusy() {
        cancelFlag?.value = true
    }

    private func runTransfer(_ urls: [URL], _ dir: URL, _ move: Bool, _ policy: ConflictPolicy) {
        let flag = CancelFlag()
        cancelFlag = flag
        let verb = move ? "移动" : "复制"
        busyText = "正在\(verb)…"
        let ops = self.ops
        Task { @MainActor in
            let outcome: OpOutcome = await Task.detached(priority: .userInitiated) { () -> OpOutcome in
                let progress: (Int, Int) -> Void = { done, total in
                    Task { @MainActor in
                        if self.busyText != nil { self.busyText = "正在\(verb)… \(done)/\(total)" }
                    }
                }
                if move {
                    return ops.move(urls, to: dir, policy: policy, progress: progress, isCancelled: { flag.value })
                }
                return ops.copy(urls, to: dir, policy: policy, progress: progress, isCancelled: { flag.value })
            }.value
            self.busyText = nil
            self.cancelFlag = nil
            self.cutURLs = []
            if move { self.clipboardIsCut = false }
            if !outcome.done.isEmpty {
                let action: UndoAction = move ? .moved(outcome.done) : .copied(outcome.done.map { $0.to })
                self.history.push("\(verb) \(outcome.done.count) 项", action)
                self.syncUndo()
            }
            self.finishOperation(outcome, affected: urls + [dir], select: outcome.done.map { $0.to }, dir: dir)
        }
    }

    func syncUndo() {
        undoTitle = history.canUndo ? history.lastTitle : nil
    }

    func finishOperation(_ outcome: OpOutcome, affected: [URL], select: [URL], dir: URL?) {
        for u in affected { sizes.invalidate(containing: u) }
        for t in tabs {
            let sel: Set<URL>? = (t.id == activeTabID && t.url == dir && !select.isEmpty) ? Set(select) : nil
            t.reload(select: sel)
        }
        if !outcome.failures.isEmpty {
            alert = .message(title: "部分操作未完成", text: outcome.failures.prefix(6).joined(separator: "\n"))
        } else if outcome.cancelled {
            flash("已取消")
        }
    }

    // MARK: - 删除 / 撤销 / 副本 / 压缩

    func trash(_ urls: [URL]? = nil) {
        let list = urls ?? activeSelectedURLs
        guard !list.isEmpty else { return }
        let ops = self.ops
        Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) { () -> OpOutcome in
                return ops.trash(list)
            }.value
            if !outcome.done.isEmpty {
                self.history.push("移到废纸篓 \(outcome.done.count) 项", .trashed(outcome.done))
                self.syncUndo()
                self.flash("已移到废纸篓 \(outcome.done.count) 项（⌘Z 可撤销）")
            }
            self.finishOperation(outcome, affected: list, select: [], dir: nil)
        }
    }

    func undo() {
        guard let result = history.undo(using: ops) else {
            flash("没有可撤销的操作")
            return
        }
        syncUndo()
        let affected = result.outcome.done.flatMap { [$0.from, $0.to] }
        finishOperation(result.outcome, affected: affected, select: [], dir: nil)
        if result.outcome.failures.isEmpty { flash("已撤销：\(result.title)") }
    }

    func duplicate(_ urls: [URL]? = nil) {
        let list = urls ?? activeSelectedURLs
        guard let tab = activeTab, !list.isEmpty else { return }
        let dir = tab.url
        let ops = self.ops
        Task { @MainActor in
            let outcome = await Task.detached(priority: .userInitiated) { () -> OpOutcome in
                var all = OpOutcome()
                for u in list {
                    let o = ops.copy([u], to: u.deletingLastPathComponent(), policy: .keepBoth)
                    all.done.append(contentsOf: o.done)
                    all.failures.append(contentsOf: o.failures)
                }
                return all
            }.value
            if !outcome.done.isEmpty {
                self.history.push("创建副本", .copied(outcome.done.map { $0.to }))
                self.syncUndo()
            }
            self.finishOperation(outcome, affected: list, select: outcome.done.map { $0.to }, dir: dir)
        }
    }

    func compress(_ urls: [URL]? = nil) {
        let list = urls ?? activeSelectedURLs
        guard let tab = activeTab, !list.isEmpty else { return }
        let dir = list[0].deletingLastPathComponent()
        let ops = self.ops
        busyText = "正在压缩…"
        Task { @MainActor in
            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) { () -> Result<URL, Error> in
                return Result(catching: { try ops.compress(list, in: dir) })
            }.value
            self.busyText = nil
            switch result {
            case .success(let zip):
                self.history.push("压缩", .created([zip]))
                self.syncUndo()
                var out = OpOutcome()
                out.done = [MovedPair(from: zip, to: zip)]
                self.finishOperation(out, affected: [zip], select: tab.url == dir ? [zip] : [], dir: dir)
                self.flash("已压缩为 \(zip.lastPathComponent)")
            case .failure(let error):
                self.showError("压缩失败", error.localizedDescription)
            }
        }
    }

    // MARK: - 新建 / 重命名

    func newFolder() {
        guard let tab = activeTab, tab.searchCriteria == nil else { return }
        do {
            let url = try ops.newFolder(in: tab.url)
            history.push("新建文件夹", .created([url]))
            syncUndo()
            tab.reload(select: [url], rename: url)
        } catch {
            showError("无法新建文件夹", error.localizedDescription)
        }
    }

    func newFile(name: String) {
        guard let tab = activeTab, tab.searchCriteria == nil else { return }
        do {
            let url = try ops.newFile(in: tab.url, name: name)
            history.push("新建文件", .created([url]))
            syncUndo()
            tab.reload(select: [url], rename: url)
        } catch {
            showError("无法新建文件", error.localizedDescription)
        }
    }

    func beginRename(_ url: URL? = nil) {
        guard let tab = activeTab else { return }
        if let u = url {
            tab.selection = [u]
            tab.renamingURL = u
        } else if activeSelectedURLs.count == 1 {
            tab.renamingURL = activeSelectedURLs[0]
        }
    }

    func commitRename(tab: TabModel, url: URL, newName: String) {
        tab.renamingURL = nil
        if newName == url.lastPathComponent { return }
        do {
            let dest = try ops.rename(url, to: newName)
            history.push("重命名", .moved([MovedPair(from: url, to: dest)]))
            syncUndo()
            sizes.invalidate(containing: url)
            for t in tabs { t.reload(select: t.id == tab.id ? [dest] : nil) }
        } catch {
            showError("无法重命名", error.localizedDescription)
        }
    }

    func startBatchRename(_ urls: [URL]? = nil) {
        guard let tab = activeTab else { return }
        let list = urls ?? activeSelectedURLs
        let items = tab.sortedItems.filter { list.contains($0.url) }
        guard items.count >= 1 else { return }
        batchRename = BatchRenameRequest(items: items)
    }

    func runBatchRename(_ plans: [RenamePlan]) {
        let outcome = BatchRenamer.execute(plans)
        if !outcome.done.isEmpty {
            history.push("批量重命名 \(outcome.done.count) 项", .moved(outcome.done))
            syncUndo()
        }
        let dir = activeTab?.url
        finishOperation(outcome, affected: plans.map { $0.url }, select: outcome.done.map { $0.to }, dir: dir)
        if outcome.failures.isEmpty { flash("已重命名 \(outcome.done.count) 项") }
    }

    // MARK: - 排序

    func setSort(_ tab: TabModel, key: SortKey, ascending: Bool? = nil) {
        let asc = ascending ?? tab.sortAscending
        tab.sortOrder = [key.comparator(ascending: asc)]
    }

    // MARK: - 拖拽

    func dragProvider(for item: FileItem, selection: Set<URL>) -> NSItemProvider {
        draggingTabID = nil
        if selection.contains(item.url) && selection.count > 1 {
            draggingURLs = Array(selection)
        } else {
            draggingURLs = [item.url]
        }
        return NSItemProvider(object: item.url as NSURL)
    }

    /// 从 NSItemProvider 里异步取出文件 URL
    func loadFileURLs(_ providers: [NSItemProvider], completion: @escaping ([URL]) -> Void) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        let box = URLBox()
        let group = DispatchGroup()
        for p in fileProviders {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var found: URL?
                if let data = item as? Data {
                    found = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    found = u
                } else if let ns = item as? NSURL {
                    found = ns as URL
                }
                if let u = found { box.add(u) }
                group.leave()
            }
        }
        group.notify(queue: DispatchQueue.main) {
            completion(box.urls)
        }
        return true
    }

    /// 拖放到某个文件夹：默认移动（同磁盘）/复制（跨磁盘），按住 ⌥ 强制复制
    func handleDrop(_ providers: [NSItemProvider], into dir: URL) -> Bool {
        let internalURLs = draggingURLs
        return loadFileURLs(providers) { [weak self] loaded in
            guard let self = self else { return }
            var urls = loaded
            if let first = urls.first, internalURLs.contains(first) { urls = internalURLs }
            self.draggingURLs = []
            guard !urls.isEmpty else { return }
            let optionDown = NSEvent.modifierFlags.contains(.option)
            let allSameVolume = urls.allSatisfy { self.ops.sameVolume($0, dir) }
            let move = !optionDown && allSameVolume
            self.transfer(urls, to: dir, move: move)
        }
    }

    // MARK: - 键盘

    func handleKey(_ press: KeyPress, tab: TabModel, columns: Int?) -> KeyPress.Result {
        if tab.renamingURL != nil || addressEditing { return .ignored }
        let mods = press.modifiers
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) { return .ignored }

        if let first = press.characters.unicodeScalars.first, first.value == UInt32(NSF2FunctionKey) {
            beginRename()
            return .handled
        }

        switch press.key {
        case .return:
            if tab.selection.count == 1 {
                beginRename()
                return .handled
            }
            return .ignored
        case .space:
            showInfoPanel.toggle()
            return .handled
        case .deleteForward:
            trash()
            return .handled
        case .escape:
            if tab.searchCriteria != nil {
                tab.clearSearch()
            } else {
                tab.selection = []
            }
            return .handled
        case .leftArrow, .rightArrow, .upArrow, .downArrow:
            guard let cols = columns else { return .ignored }   // 详细信息表格自己处理方向键
            moveCursor(tab: tab, key: press.key, columns: cols, extend: mods.contains(.shift))
            return .handled
        default:
            return .ignored
        }
    }

    private func moveCursor(tab: TabModel, key: KeyEquivalent, columns: Int, extend: Bool) {
        let list = tab.sortedItems
        guard !list.isEmpty else { return }
        var idx = -1
        if let c = tab.cursor, let i = list.firstIndex(where: { $0.url == c }) {
            idx = i
        } else if let i = list.firstIndex(where: { tab.selection.contains($0.url) }) {
            idx = i
        }
        var next = idx
        if idx < 0 {
            next = 0
        } else if key == .leftArrow {
            next = idx - 1
        } else if key == .rightArrow {
            next = idx + 1
        } else if key == .upArrow {
            next = idx - max(columns, 1)
        } else if key == .downArrow {
            next = idx + max(columns, 1)
        }
        next = min(max(next, 0), list.count - 1)
        let target = list[next].url
        if extend, let a = tab.anchor, let ai = list.firstIndex(where: { $0.url == a }) {
            tab.selection = Set(list[min(ai, next)...max(ai, next)].map { $0.url })
        } else {
            tab.selection = [target]
            tab.anchor = target
        }
        tab.cursor = target
        tab.scrollTarget = target
    }
}
