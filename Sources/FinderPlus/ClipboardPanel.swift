import SwiftUI
import AppKit
import FinderCore

struct ClipboardPanel: View {
    @EnvironmentObject var app: AppModel
    @State private var showAll = false

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            header
            if app.clipboardPanelOpen {
                content
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    var header: some View {
        HStack(spacing: 6) {
            Button {
                app.clipboardPanelOpen.toggle()
            } label: {
                Image(systemName: app.clipboardPanelOpen ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .frame(width: 12)
            }
            .buttonStyle(.plain)
            Image(systemName: "doc.on.clipboard")
                .shadow(color: Color.black.opacity(0.25), radius: 1.5, x: 0, y: 1)
            Text("剪贴板历史")
                .font(.callout.weight(.medium))
            Spacer(minLength: 0)
            Text("\(app.clipboardEntries.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("记录剪贴板", isOn: $app.clipboardRecording)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help(app.clipboardRecording ? "正在记录剪贴板，点击暂停" : "已暂停记录，点击恢复")
            Button {
                app.clearClipboardHistory()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("清空历史（已固定的会保留）")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    var content: some View {
        if app.clipboardEntries.isEmpty {
            Text(app.clipboardRecording ? "复制文字、图片或文件后，会出现在这里。" : "记录已暂停。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 18)
        } else {
            let all = app.clipboardEntries
            let visible = showAll ? all : Array(all.prefix(12))
            ScrollView {
                LazyVStack(spacing: 1) {
                    ForEach(visible) { entry in
                        ClipboardRow(entry: entry)
                    }
                    if all.count > 12 {
                        Button(showAll ? "收起" : "显示全部 \(all.count) 项") {
                            showAll.toggle()
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                        .padding(.vertical, 4)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(height: 210)
        }
    }
}

struct ClipboardRow: View {
    let entry: ClipboardEntry
    @EnvironmentObject var app: AppModel
    @State private var hovering = false

    static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            icon
                .frame(width: 22, height: 22)
                .shadow(color: Color.black.opacity(0.25), radius: 1.5, x: 0, y: 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(entry.detail + " · " + ClipboardRow.relative.localizedString(for: entry.date, relativeTo: Date()))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if entry.pinned {
                Image(systemName: "pin.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(hovering ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { app.restoreClipboard(entry) }
        .help(helpText)
        .contextMenu {
            Button("放回剪贴板") { app.restoreClipboard(entry) }
            if entry.kind == .files {
                Button("粘贴到当前文件夹") { app.pasteClipboardFiles(entry) }
            }
            if entry.kind == .text {
                Button("保存为文本文件到当前文件夹") { app.saveClipboardText(entry) }
            }
            Divider()
            Button(entry.pinned ? "取消固定" : "固定在最上面") { app.toggleClipboardPin(entry) }
            Button("删除这一条") { app.removeClipboardEntry(entry) }
        }
    }

    @ViewBuilder
    var icon: some View {
        switch entry.kind {
        case .text:
            Image(systemName: "text.alignleft")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
        case .files:
            if let first = entry.paths.first {
                Image(nsImage: NSWorkspace.shared.icon(forFile: first))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "doc.on.doc")
            }
        case .image:
            if let img = app.clipboardImages[entry.id] {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
    }

    var helpText: String {
        switch entry.kind {
        case .text:
            return String((entry.text ?? "").prefix(400))
        case .files:
            return entry.paths.prefix(8).joined(separator: "\n")
        case .image:
            return "图片（仅保留在本次运行中）"
        }
    }
}
