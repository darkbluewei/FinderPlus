import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

@main
struct FinderPlusApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("FinderPlus", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 980, minHeight: 600)
        }
        .defaultSize(width: 1280, height: 780)
        .commands {
            AppCommands(model: model)
        }
    }
}

/// 正在输入文字（地址栏、重命名框、搜索框）时，⌘C/⌘V 等应作用于文字而不是文件
private func isEditingText() -> Bool {
    return NSApp.keyWindow?.firstResponder is NSTextView
}

struct AppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Group {
            Button("新建标签页") { model.newTab() }
                .keyboardShortcut("t")
            Button("新建文件夹") { model.newFolder() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("新建文本文档") { model.newFile(name: "未命名.txt") }
            Button("新建 Markdown 文档") { model.newFile(name: "未命名.md") }
            }
            Divider()
            Group {
            Button("打开") { model.openSelection() }
                .keyboardShortcut(.downArrow, modifiers: .command)
            Button("重命名") { model.beginRename() }
            Button("批量重命名…") { model.startBatchRename() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("复制一份") { model.duplicate() }
                .keyboardShortcut("d", modifiers: [.command, .option])
            Button("压缩") { model.compress() }
            }
            Divider()
            Group {
            Button("拷贝路径") { model.copyPaths() }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Button("在访达中显示") { model.showInFinder() }
            Button("在终端中打开") { model.openTerminal() }
            }
            Divider()
            Button("关闭标签页") { model.closeActiveTab() }
                .keyboardShortcut("w")
        }

        CommandGroup(replacing: .undoRedo) {
            Button("撤销") {
                if isEditingText() {
                    NSApp.sendAction(Selector(("undo:")), to: nil, from: nil)
                } else {
                    model.undo()
                }
            }
            .keyboardShortcut("z")
        }

        CommandGroup(replacing: .pasteboard) {
            Button("剪切") {
                if isEditingText() { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) } else { model.cut() }
            }
            .keyboardShortcut("x")
            Button("拷贝") {
                if isEditingText() { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) } else { model.copy() }
            }
            .keyboardShortcut("c")
            Button("粘贴") {
                if isEditingText() { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) } else { model.paste() }
            }
            .keyboardShortcut("v")
            Button("全选") {
                if isEditingText() { NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) } else { model.selectAll() }
            }
            .keyboardShortcut("a")
            Divider()
            Button("移到废纸篓") {
                if !isEditingText() { model.trash() }
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }

        CommandGroup(replacing: .textEditing) {
            Button("搜索") { model.toggleSearch() }
                .keyboardShortcut("f")
        }

        CommandMenu("查看") {
            Group {
            Button("超大图标") { model.setView(.icons, size: 200) }
                .keyboardShortcut("1")
            Button("大图标") { model.setView(.icons, size: 120) }
            Button("中等图标") { model.setView(.icons, size: 72) }
            Button("小图标") { model.setView(.icons, size: 48) }
            Button("列表") { model.setView(.list) }
                .keyboardShortcut("2")
            Button("详细信息") { model.setView(.details) }
                .keyboardShortcut("3")
            Button("平铺") { model.setView(.tiles) }
                .keyboardShortcut("4")
            }
            Divider()
            Group {
            Button(model.showHidden ? "隐藏隐藏文件" : "显示隐藏文件") { model.showHidden.toggle() }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            Button(model.showFolderSizes ? "不计算文件夹大小" : "显示文件夹大小") { model.showFolderSizes.toggle() }
            Button("空间分析") { model.toggleAnalysis() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button(model.showInfoPanel ? "隐藏信息面板" : "显示信息面板") { model.showInfoPanel.toggle() }
                .keyboardShortcut("i")
            }
            Divider()
            Button("刷新") { model.reloadActive() }
                .keyboardShortcut("r")
        }

        CommandMenu("转到") {
            Button("后退") { model.activeTab?.goBack() }
                .keyboardShortcut("[")
            Button("前进") { model.activeTab?.goForward() }
                .keyboardShortcut("]")
            Button("上一级文件夹") { model.activeTab?.goUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
            Button("输入路径…") { model.focusAddressBar() }
                .keyboardShortcut("l")
            Divider()
            Button("添加到收藏夹") { model.addCurrentToFavorites() }
                .keyboardShortcut("d")
            Divider()
            Button("下一个标签页") { model.selectNextTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("上一个标签页") { model.selectNextTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
        }
    }
}
