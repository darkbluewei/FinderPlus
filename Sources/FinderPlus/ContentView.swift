import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FinderCore

struct ContentView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView()
                .frame(width: 210)
            Divider()
            VStack(spacing: 0) {
                TabBar()
                Divider()
                if let tab = app.activeTab {
                    TabContentView(tab: tab)
                        .id(tab.id)
                } else {
                    Spacer()
                }
            }
            if app.showInfoPanel, let tab = app.activeTab {
                Divider()
                InfoPanel(tab: tab)
                    .frame(width: 300)
            }
        }
        .alert(alertTitle,
               isPresented: Binding(get: { app.alert != nil }, set: { if !$0 { app.alert = nil } }),
               presenting: app.alert) { a in
            switch a {
            case .message:
                Button("好") {}
            case .conflict(let req):
                Button("替换") { app.resolveConflict(req, .replace) }
                Button("保留两者") { app.resolveConflict(req, .keepBoth) }
                Button("跳过") { app.resolveConflict(req, .skip) }
                Button("取消", role: .cancel) {}
            }
        } message: { a in
            switch a {
            case .message(_, let text):
                Text(text)
            case .conflict(let req):
                Text("目标位置已有 \(req.names.count) 个同名项目：\(req.names.prefix(3).joined(separator: "、"))\(req.names.count > 3 ? " 等" : "")")
            }
        }
        .sheet(item: $app.batchRename) { req in
            BatchRenameSheet(items: req.items)
        }
    }

    var alertTitle: String {
        switch app.alert {
        case .message(let t, _): return t
        case .conflict: return "存在同名项目"
        case .none: return ""
        }
    }
}

// MARK: - 标签栏

struct TabBar: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(app.tabs) { tab in
                        TabButton(tab: tab)
                    }
                }
                .padding(.horizontal, 6)
            }
            Button {
                app.newTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .help("新建标签页 (⌘T)")
            .padding(.trailing, 8)
        }
        .frame(height: 34)
        .background(.bar)
    }
}

struct TabButton: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel
    @State private var targeted = false

    var body: some View {
        let active = app.activeTabID == tab.id
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.secondary)
                .font(.caption)
            Text(tab.title)
                .lineLimit(1)
                .frame(maxWidth: 160)
            Button {
                app.closeTab(tab.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.borderless)
            .help("关闭标签页 (⌘W)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7)
                .fill(active ? Color.accentColor.opacity(0.22) : (targeted ? Color.accentColor.opacity(0.12) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture { app.selectTab(tab.id) }
        .onDrag {
            app.draggingTabID = tab.id
            return NSItemProvider(object: tab.id.uuidString as NSString)
        }
        .onDrop(of: [UTType.fileURL, UTType.plainText], isTargeted: $targeted) { providers in
            if let dragID = app.draggingTabID {
                app.moveTab(dragID, before: tab.id)
                app.draggingTabID = nil
                return true
            }
            return app.handleDrop(providers, into: tab.url)
        }
        .contextMenu {
            Button("关闭标签页") { app.closeTab(tab.id) }
            Button("关闭其他标签页") { app.closeOtherTabs(keeping: tab.id) }
            Divider()
            Button("复制标签页") { app.newTab(url: tab.url) }
        }
    }
}

// MARK: - 单个标签页的内容

struct TabContentView: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ToolbarRow(tab: tab)
            if app.showSearchBar {
                Divider()
                SearchBar(tab: tab)
            }
            Divider()
            FileAreaView(tab: tab)
            Divider()
            StatusBar(tab: tab)
        }
    }
}

// MARK: - 工具栏

struct ToolbarRow: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Group {
                    Button { tab.goBack() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(RaisedButtonStyle())
                        .disabled(tab.backStack.isEmpty)
                        .help("后退 (⌘[)")
                    Button { tab.goForward() } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(RaisedButtonStyle())
                        .disabled(tab.forwardStack.isEmpty)
                        .help("前进 (⌘])")
                    Button { tab.goUp() } label: { Image(systemName: "chevron.up") }
                        .buttonStyle(RaisedButtonStyle())
                        .help("上一级 (⌘↑)")
                    Button { app.reloadActive() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(RaisedButtonStyle())
                        .help("刷新 (⌘R)")
                }

                AddressBar(tab: tab)

                Group {
                    Button { app.toggleSearch() } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(RaisedButtonStyle(active: app.showSearchBar))
                        .help("搜索 (⌘F)")
                    sortMenu
                    viewMenu
                    Button { app.showFolderSizes.toggle() } label: { Image(systemName: "number.square") }
                        .buttonStyle(RaisedButtonStyle(active: app.showFolderSizes))
                        .help("显示文件夹大小")
                    Button { app.toggleAnalysis() } label: { Image(systemName: "chart.bar.xaxis") }
                        .buttonStyle(RaisedButtonStyle(active: tab.analysisMode))
                        .help("空间分析：找出最占空间的项目 (⌥⌘S)")
                    Button { app.showHidden.toggle() } label: { Image(systemName: app.showHidden ? "eye" : "eye.slash") }
                        .buttonStyle(RaisedButtonStyle(active: app.showHidden))
                        .help("显示/隐藏隐藏文件 (⇧⌘.)")
                    Button { app.showInfoPanel.toggle() } label: { Image(systemName: "sidebar.right") }
                        .buttonStyle(RaisedButtonStyle(active: app.showInfoPanel))
                        .help("信息面板 (⌘I)")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            if app.addressEditing {
                AddressSuggestions(tab: tab)
            }
        }
    }

    var sortMenu: some View {
        Menu {
            ForEach(SortKey.allCases) { k in
                Button {
                    app.setSort(tab, key: k)
                } label: {
                    if tab.sortKey == k {
                        Label(k.title, systemImage: "checkmark")
                    } else {
                        Text(k.title)
                    }
                }
            }
            Divider()
            Button {
                app.setSort(tab, key: tab.sortKey, ascending: true)
            } label: {
                if tab.sortAscending { Label("升序", systemImage: "checkmark") } else { Text("升序") }
            }
            Button {
                app.setSort(tab, key: tab.sortKey, ascending: false)
            } label: {
                if !tab.sortAscending { Label("降序", systemImage: "checkmark") } else { Text("降序") }
            }
            Divider()
            Toggle("文件夹置顶", isOn: $app.folderFirst)
        } label: {
            RaisedLabel(systemName: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("排序方式")
    }

    var viewMenu: some View {
        Menu {
            viewItem("超大图标", .icons, 200)
            viewItem("大图标", .icons, 120)
            viewItem("中等图标", .icons, 72)
            viewItem("小图标", .icons, 48)
            Divider()
            viewItem("列表", .list, nil)
            viewItem("详细信息", .details, nil)
            viewItem("平铺", .tiles, nil)
        } label: {
            RaisedLabel(systemName: app.viewMode.symbol)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("查看方式")
    }

    func viewItem(_ title: String, _ mode: ViewMode, _ size: Double?) -> some View {
        let current: Bool = {
            if app.viewMode != mode { return false }
            if let s = size { return abs(app.iconSize - s) < 20 }
            return true
        }()
        return Button {
            app.setView(mode, size: size)
        } label: {
            if current { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}

// MARK: - 地址栏

struct AddressBar: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel
    @FocusState private var focused: Bool
    @State private var text = ""

    var body: some View {
        ZStack {
            if app.addressEditing {
                TextField("输入或粘贴路径，按回车前往", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { go() }
                    .onKeyPress(.tab) {
                        complete()
                        return .handled
                    }
                    .onExitCommand { app.addressEditing = false }
                    .onChange(of: text) { _, newValue in
                        tab.addressDraft = newValue
                    }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused {
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 250_000_000)
                                if !focused { app.addressEditing = false }
                            }
                        }
                    }
                    .onAppear {
                        text = tab.url.path
                        tab.addressDraft = text
                        Task { @MainActor in
                            focused = true
                            try? await Task.sleep(nanoseconds: 60_000_000)
                            (NSApp.keyWindow?.firstResponder as? NSTextView)?.selectAll(nil)
                        }
                    }
            } else {
                Breadcrumb(tab: tab)
                    .contentShape(Rectangle())
                    .onTapGesture { app.addressEditing = true }
            }
        }
        .frame(maxWidth: .infinity)
    }

    func go() {
        guard let u = PathParser.resolve(text, relativeTo: tab.url) else {
            NSSound.beep()
            return
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir) {
            app.addressEditing = false
            if isDir.boolValue {
                tab.navigate(to: u)
            } else {
                tab.navigate(to: u.deletingLastPathComponent(), select: [u])
            }
        } else {
            app.showError("找不到路径", u.path)
        }
    }

    func complete() {
        let s = PathCompleter.suggestions(for: text, limit: 50)
        guard !s.isEmpty else { return }
        if s.count == 1 {
            text = s[0]
        } else {
            let common = PathCompleter.commonPrefix(s)
            if common.count > text.count { text = common } else { text = s[0] }
        }
        tab.addressDraft = text
    }
}

struct AddressSuggestions: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        let list = PathCompleter.suggestions(for: tab.addressDraft, limit: 8)
        if !list.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    Text("Tab 补全：").font(.caption).foregroundStyle(.secondary)
                    ForEach(list, id: \.self) { p in
                        Button {
                            if let u = PathParser.resolve(p) {
                                app.addressEditing = false
                                tab.navigate(to: u)
                            }
                        } label: {
                            Text(URL(fileURLWithPath: p).lastPathComponent)
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
    }
}

struct Breadcrumb: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel

    var segments: [(name: String, url: URL)] {
        var result: [(name: String, url: URL)] = [(name: "/", url: URL(fileURLWithPath: "/"))]
        var current = URL(fileURLWithPath: "/")
        for c in tab.url.pathComponents where c != "/" {
            current = current.appendingPathComponent(c)
            result.append((name: c, url: current))
        }
        return result
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { index, seg in
                        if index > 1 {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9))
                                .foregroundStyle(.tertiary)
                        }
                        Button(seg.name) {
                            if NSEvent.modifierFlags.contains(.command) {
                                app.newTab(url: seg.url)
                            } else {
                                tab.navigate(to: seg.url)
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 4)
                        .id(index)
                    }
                    if tab.searchCriteria != nil {
                        Text("  ·  搜索结果").foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 20)
                }
                .padding(.horizontal, 6)
            }
            .onAppear { proxy.scrollTo(segments.count - 1, anchor: .trailing) }
            .onChange(of: tab.url) { _, _ in
                proxy.scrollTo(segments.count - 1, anchor: .trailing)
            }
        }
        .frame(height: 24)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 1)
        )
        .contextMenu {
            Button("拷贝路径") { app.copyPaths([tab.url]) }
            Button("编辑路径") { app.addressEditing = true }
        }
    }
}

// MARK: - 状态栏

struct StatusBar: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        let selected = tab.sortedItems.filter { tab.selection.contains($0.url) }
        let summary = SelectionSummary.make(from: selected)
        HStack(spacing: 14) {
            Text(countText)
            if !selected.isEmpty {
                Text(selectionText(summary))
                    .foregroundStyle(.primary)
            }
            Spacer()
            if let b = app.busyText {
                ProgressView().controlSize(.small)
                Text(b)
                Button("取消") { app.cancelBusy() }
                    .buttonStyle(.borderless)
            }
            if let f = app.statusFlash {
                Text(f).foregroundStyle(.secondary)
            }
            if app.viewMode == .icons {
                Image(systemName: "photo").font(.caption2).foregroundStyle(.secondary)
                Slider(value: $app.iconSize, in: 40...260)
                    .frame(width: 120)
                Image(systemName: "photo").font(.body).foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    var countText: String {
        if tab.isSearching { return "正在搜索… 已找到 \(tab.items.count) 项" }
        if tab.searchCriteria != nil { return "搜索结果：\(tab.items.count) 项" }
        return "\(tab.items.count) 个项目"
    }

    func selectionText(_ s: SelectionSummary) -> String {
        var t = "已选择 \(s.count) 项，总大小 \(Format.bytes(s.totalBytes))"
        if s.pendingFolders > 0 { t += "（\(s.pendingFolders) 个文件夹计算中…）" }
        return t
    }
}
