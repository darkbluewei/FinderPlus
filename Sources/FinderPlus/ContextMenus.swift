import SwiftUI
import AppKit
import FinderCore

/// 右键菜单：点在文件/文件夹上显示项目菜单，点在空白处显示“新建/粘贴/查看/排序”菜单
struct FileContextMenu: View {
    let app: AppModel
    @ObservedObject var tab: TabModel
    let targets: Set<URL>

    var body: some View {
        if targets.isEmpty {
            BackgroundMenu(app: app, tab: tab)
        } else {
            ItemMenu(app: app, tab: tab, targets: targets)
        }
    }
}

struct ItemMenu: View {
    let app: AppModel
    @ObservedObject var tab: TabModel
    let targets: Set<URL>

    var body: some View {
        let list: [URL] = tab.sortedItems.filter { targets.contains($0.url) }.map { $0.url }
        let items = tab.sortedItems.filter { targets.contains($0.url) }
        let single: FileItem? = items.count == 1 ? items[0] : nil
        let hasFolder = items.contains { $0.needsFolderSize }

        Group {
            Group {
            Button("打开") { app.open(list, in: tab) }
            if let s = single, s.isFolder {
                Button("在新标签页中打开") { app.newTab(url: s.url) }
            }
            if let s = single, !s.isFolder {
                OpenWithMenu(app: app, url: s.url)
            }
            }

            Group {
            Divider()
            Button("剪切") { app.cut(list) }
            Button("拷贝") { app.copy(list) }
            if let s = single, s.isFolder, app.canPaste {
                Button("粘贴到此文件夹") { app.paste(into: s.url) }
            }
            Button("创建副本") { app.duplicate(list) }
            }

            Group {
            Divider()
            if single != nil {
                Button("重命名") { app.beginRename(list[0]) }
            } else {
                Button("批量重命名…") { app.startBatchRename(list) }
            }
            Button(items.count == 1 ? "压缩" : "压缩 \(items.count) 项") { app.compress(list) }
            }

            Group {
            Divider()
            Button("拷贝路径") { app.copyPaths(list) }
            Button("拷贝名称") { app.copyNames(list) }
            if let s = single, s.isFolder {
                Button("添加到收藏夹") { app.addFavorite(s.url) }
            }
            if hasFolder {
                Button("计算大小") {
                    tab.selection = Set(list)
                    for it in items where it.needsFolderSize {
                        app.sizes.request(it.url) { u, info in
                            Task { @MainActor in tab.receiveSize(u, info) }
                        }
                    }
                }
            }
            }

            Group {
            Divider()
            Button("在终端中打开") {
                if let s = single, s.isFolder {
                    app.openTerminal(s.url)
                } else if let first = list.first {
                    app.openTerminal(first.deletingLastPathComponent())
                }
            }
            Button("在访达中显示") { app.showInFinder(list) }
            Button(app.showInfoPanel ? "隐藏信息面板" : "显示信息面板") {
                tab.selection = Set(list)
                app.showInfoPanel.toggle()
            }
            }

            Group {
            Divider()
            Button("移到废纸篓") { app.trash(list) }
            }
        }
    }
}

struct OpenWithMenu: View {
    let app: AppModel
    let url: URL

    var body: some View {
        let apps = Array(NSWorkspace.shared.urlsForApplications(toOpen: url).prefix(20))
        if !apps.isEmpty {
            Menu("用其他应用打开") {
                ForEach(apps, id: \.self) { appURL in
                    Button(FileManager.default.displayName(atPath: appURL.path)) {
                        app.openWith(appURL, [url])
                    }
                }
            }
        }
    }
}

struct BackgroundMenu: View {
    let app: AppModel
    @ObservedObject var tab: TabModel

    var body: some View {
        Group {
            Group {
            Menu("新建") {
                Button("文件夹") { app.newFolder() }
                Button("文本文档") { app.newFile(name: "未命名.txt") }
                Button("Markdown 文档") { app.newFile(name: "未命名.md") }
            }

            Button("粘贴") { app.paste() }
                .disabled(!app.canPaste)
            }

            Divider()

            Group {
            Menu("查看方式") {
                Button("超大图标") { app.setView(.icons, size: 200) }
                Button("大图标") { app.setView(.icons, size: 120) }
                Button("中等图标") { app.setView(.icons, size: 72) }
                Button("小图标") { app.setView(.icons, size: 48) }
                Divider()
                Button("列表") { app.setView(.list) }
                Button("详细信息") { app.setView(.details) }
                Button("平铺") { app.setView(.tiles) }
            }

            Menu("排序方式") {
                ForEach(SortKey.allCases) { k in
                    Button(k.title) { app.setSort(tab, key: k) }
                }
                Divider()
                Button("升序") { app.setSort(tab, key: tab.sortKey, ascending: true) }
                Button("降序") { app.setSort(tab, key: tab.sortKey, ascending: false) }
            }

            Toggle("显示隐藏文件", isOn: Binding(get: { app.showHidden }, set: { app.showHidden = $0 }))
            Toggle("显示文件夹大小", isOn: Binding(get: { app.showFolderSizes }, set: { app.showFolderSizes = $0 }))
            }

            Divider()

            Group {
            Button("全选") { app.selectAll() }
            Button("刷新") { app.reloadActive() }
            }

            Divider()

            Group {
            Button("在终端中打开") { app.openTerminal(tab.url) }
            Button("添加当前文件夹到收藏夹") { app.addFavorite(tab.url) }
            Button("拷贝当前路径") { app.copyPaths([tab.url]) }
            }
        }
    }
}
