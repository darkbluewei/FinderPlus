import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FinderCore

func sizeText(_ item: FileItem) -> String {
    if let b = item.sizeBytes { return Format.bytes(b) }
    return item.needsFolderSize ? "—" : ""
}

// MARK: - 内容区域入口

struct FileAreaView: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        ZStack {
            if let err = tab.errorText {
                ErrorView(tab: tab, text: err)
            } else if tab.analysisMode {
                SpaceAnalysisView(tab: tab)
            } else {
                switch app.viewMode {
                case .details:
                    DetailsTable(tab: tab)
                case .icons:
                    ItemGrid(tab: tab, minWidth: CGFloat(app.iconSize) + 32, spacing: 8) { item in
                        IconCell(item: item, size: app.iconSize, tab: tab)
                    }
                case .list:
                    ItemGrid(tab: tab, minWidth: 220, spacing: 2) { item in
                        ListCell(item: item, tab: tab)
                    }
                case .tiles:
                    ItemGrid(tab: tab, minWidth: 280, spacing: 6) { item in
                        TileCell(item: item, tab: tab)
                    }
                }
                if tab.sortedItems.isEmpty && !tab.isLoading && !tab.isSearching {
                    Text(tab.searchCriteria != nil ? "没有找到匹配的项目" : "此文件夹为空")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .allowsHitTesting(false)
                }
                if tab.isLoading {
                    ProgressView().controlSize(.large)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ErrorView: View {
    @ObservedObject var tab: TabModel
    let text: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: tab.permissionIssue ? "lock.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.headline)
            if tab.permissionIssue {
                Text("请在“系统设置 → 隐私与安全性 → 完全磁盘访问权限”里添加 FinderPlus，然后重新打开本软件。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
                HStack {
                    Button("打开系统设置") {
                        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                            NSWorkspace.shared.open(u)
                        }
                    }
                    Button("重试") { tab.reload() }
                }
            } else {
                Text(tab.url.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                Button("返回上一级") { tab.goUp() }
            }
        }
        .padding()
    }
}

// MARK: - 详细信息（表格）

struct DetailsTable: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        Table(tab.sortedItems, selection: $tab.selection, sortOrder: $tab.sortOrder) {
            TableColumn("名称", value: \FileItem.nameKey) { item in
                NameCell(item: item, tab: tab)
            }
            .width(min: 200, ideal: 340)
            TableColumn("大小", value: \FileItem.sortSize) { item in
                Text(sizeText(item))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn("种类", value: \FileItem.kind) { item in
                Text(item.kind)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 120)
            TableColumn("修改日期", value: \FileItem.modifiedSort) { item in
                Text(Format.date(item.modified))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
            TableColumn("创建日期", value: \FileItem.createdSort) { item in
                Text(Format.date(item.created))
                    .foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 150)
        }
        .contextMenu(forSelectionType: URL.self) { ids in
            FileContextMenu(app: app, tab: tab, targets: ids)
        } primaryAction: { ids in
            app.open(Array(ids), in: tab)
        }
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            return app.handleDrop(providers, into: tab.url)
        }
        .onKeyPress(phases: [.down, .repeat]) { press in
            return app.handleKey(press, tab: tab, columns: nil)
        }
    }
}

struct NameCell: View {
    let item: FileItem
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel
    @State private var targeted = false

    var body: some View {
        HStack(spacing: 6) {
            FileIconView(item: item, size: 18, thumbnail: false)
            if tab.renamingURL == item.url {
                RenameField(item: item, tab: tab)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if tab.searchCriteria != nil {
                        Text(item.parentPath)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(app.cutURLs.contains(item.url) ? 0.45 : (item.isHidden ? 0.65 : 1))
        .background(targeted ? Color.accentColor.opacity(0.2) : Color.clear)
        .onDrag { app.dragProvider(for: item, selection: tab.selection) }
        .folderDropTarget(item: item, app: app, targeted: $targeted)
    }
}

// MARK: - 重命名输入框

struct RenameField: View {
    let item: FileItem
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel
    @State private var text: String
    @FocusState private var focused: Bool

    init(item: FileItem, tab: TabModel) {
        self.item = item
        self.tab = tab
        _text = State(initialValue: item.name)
    }

    var body: some View {
        TextField("", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($focused)
            .onSubmit { commit() }
            .onExitCommand { tab.renamingURL = nil }
            .onChange(of: focused) { _, isFocused in
                if !isFocused && tab.renamingURL == item.url { commit() }
            }
            .onAppear {
                focused = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                        let full = item.name as NSString
                        let length = item.isFolder ? full.length : (full.deletingPathExtension as NSString).length
                        editor.setSelectedRange(NSRange(location: 0, length: length))
                    }
                }
            }
    }

    func commit() {
        app.commitRename(tab: tab, url: item.url, newName: text)
    }
}

// MARK: - 文件夹作为拖放目标

struct FolderDropModifier: ViewModifier {
    let item: FileItem
    let app: AppModel
    @Binding var targeted: Bool

    func body(content: Content) -> some View {
        if item.isFolder {
            content.onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
                return app.handleDrop(providers, into: item.url)
            }
        } else {
            content
        }
    }
}

extension View {
    func folderDropTarget(item: FileItem, app: AppModel, targeted: Binding<Bool>) -> some View {
        modifier(FolderDropModifier(item: item, app: app, targeted: targeted))
    }
}

// MARK: - 通用网格（图标 / 列表 / 平铺）

struct ItemGrid<Cell: View>: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel
    let minWidth: CGFloat
    let spacing: CGFloat
    let cell: (FileItem) -> Cell

    @FocusState private var focused: Bool
    @State private var columns = 1
    @State private var dropTarget: URL?

    init(tab: TabModel, minWidth: CGFloat, spacing: CGFloat, @ViewBuilder cell: @escaping (FileItem) -> Cell) {
        self.tab = tab
        self.minWidth = minWidth
        self.spacing = spacing
        self.cell = cell
    }

    var body: some View {
        GeometryReader { geo in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: spacing, alignment: .top)],
                                  spacing: spacing) {
                            ForEach(tab.sortedItems) { item in
                                cellView(item)
                            }
                        }
                        .padding(12)
                        Color.clear
                            .frame(height: 300)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                tab.selection = []
                                focused = true
                            }
                    }
                    .frame(minHeight: geo.size.height, alignment: .top)
                }
                .onChange(of: tab.scrollTarget) { _, target in
                    if let t = target { proxy.scrollTo(t) }
                }
                .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                    return app.handleDrop(providers, into: tab.url)
                }
            }
            .onAppear { columns = columnCount(width: geo.size.width) }
            .onChange(of: geo.size.width) { _, w in columns = columnCount(width: w) }
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(phases: [.down, .repeat]) { press in
            return app.handleKey(press, tab: tab, columns: columns)
        }
        .contextMenu {
            FileContextMenu(app: app, tab: tab, targets: [])
        }
    }

    func columnCount(width: CGFloat) -> Int {
        let usable = width - 24 + spacing
        return max(1, Int(usable / (minWidth + spacing)))
    }

    func menuTargets(_ item: FileItem) -> Set<URL> {
        return tab.selection.contains(item.url) ? tab.selection : [item.url]
    }

    @ViewBuilder
    func cellView(_ item: FileItem) -> some View {
        let selected = tab.selection.contains(item.url)
        let isDropTarget = dropTarget == item.url
        cell(item)
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(selected ? Color.accentColor.opacity(0.28) : (isDropTarget ? Color.accentColor.opacity(0.14) : Color.clear))
            )
            .opacity(app.cutURLs.contains(item.url) ? 0.45 : 1)
            .contentShape(Rectangle())
            .id(item.url)
            .onTapGesture(count: 2) { app.open([item.url], in: tab) }
            .onTapGesture { click(item) }
            .onDrag { app.dragProvider(for: item, selection: tab.selection) }
            .folderDropTarget(item: item, app: app, targeted: Binding(
                get: { dropTarget == item.url },
                set: { isOn in
                    if isOn { dropTarget = item.url } else if dropTarget == item.url { dropTarget = nil }
                }
            ))
            .contextMenu {
                FileContextMenu(app: app, tab: tab, targets: menuTargets(item))
            }
    }

    func click(_ item: FileItem) {
        focused = true
        let mods = NSEvent.modifierFlags
        let list = tab.sortedItems
        if mods.contains(.command) {
            if tab.selection.contains(item.url) {
                tab.selection.remove(item.url)
            } else {
                tab.selection.insert(item.url)
            }
            tab.anchor = item.url
        } else if mods.contains(.shift),
                  let a = tab.anchor,
                  let i = list.firstIndex(where: { $0.url == a }),
                  let j = list.firstIndex(where: { $0.url == item.url }) {
            tab.selection = Set(list[min(i, j)...max(i, j)].map { $0.url })
        } else {
            tab.selection = [item.url]
            tab.anchor = item.url
        }
        tab.cursor = item.url
    }
}

// MARK: - 各种单元格

struct IconCell: View {
    let item: FileItem
    let size: Double
    @ObservedObject var tab: TabModel

    var body: some View {
        VStack(spacing: 4) {
            FileIconView(item: item, size: CGFloat(size), thumbnail: true)
            if tab.renamingURL == item.url {
                RenameField(item: item, tab: tab)
            } else {
                Text(item.name)
                    .font(.system(size: size < 60 ? 11 : 12))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity)
            }
        }
        .frame(width: CGFloat(size) + 24)
    }
}

struct ListCell: View {
    let item: FileItem
    @ObservedObject var tab: TabModel

    var body: some View {
        HStack(spacing: 6) {
            FileIconView(item: item, size: 18, thumbnail: false)
            if tab.renamingURL == item.url {
                RenameField(item: item, tab: tab)
            } else {
                Text(item.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TileCell: View {
    let item: FileItem
    @ObservedObject var tab: TabModel

    var body: some View {
        HStack(spacing: 10) {
            FileIconView(item: item, size: 52, thumbnail: true)
            VStack(alignment: .leading, spacing: 2) {
                if tab.renamingURL == item.url {
                    RenameField(item: item, tab: tab)
                } else {
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(item.kind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(sizeText(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 空间分析

struct SpaceAnalysisView: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        let rows = tab.items.sorted { $0.sortSize > $1.sortSize }
        let known = rows.filter { $0.sizeBytes != nil }.count
        let total = rows.reduce(Int64(0)) { $0 + max($1.sortSize, 0) }
        let maxSize = max(rows.first?.sortSize ?? 1, 1)

        VStack(spacing: 0) {
            HStack {
                Text("空间分析：\(tab.title)")
                    .font(.headline)
                Spacer()
                if known < rows.count {
                    ProgressView().controlSize(.small)
                    Text("已统计 \(known)/\(rows.count)")
                        .foregroundStyle(.secondary)
                }
                Text("合计 \(Format.bytes(total))")
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            List(rows) { item in
                HStack(spacing: 10) {
                    FileIconView(item: item, size: 22, thumbnail: false)
                    Text(item.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(width: 220, alignment: .leading)
                    GeometryReader { geo in
                        let ratio = item.sizeBytes == nil ? 0 : CGFloat(max(item.sortSize, 0)) / CGFloat(maxSize)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.12))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(item.isFolder ? Color.accentColor : Color.orange)
                                .frame(width: max(geo.size.width * ratio, ratio > 0 ? 2 : 0))
                        }
                    }
                    .frame(height: 10)
                    Text(item.sizeBytes == nil ? "计算中…" : Format.bytes(item.sortSize))
                        .monospacedDigit()
                        .frame(width: 90, alignment: .trailing)
                    Text(percentText(item, total: total))
                        .foregroundStyle(.secondary)
                        .frame(width: 50, alignment: .trailing)
                }
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { app.open([item.url], in: tab) }
                .contextMenu {
                    FileContextMenu(app: app, tab: tab, targets: [item.url])
                }
            }
        }
        .onAppear { tab.requestSizes() }
    }

    func percentText(_ item: FileItem, total: Int64) -> String {
        guard item.sizeBytes != nil, total > 0 else { return "" }
        let p = Double(max(item.sortSize, 0)) / Double(total) * 100
        return String(format: "%.1f%%", p)
    }
}
