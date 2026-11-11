import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import FinderCore

struct InfoPanel: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        let selected = tab.sortedItems.filter { tab.selection.contains($0.url) }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if selected.isEmpty {
                    FolderInfoView(tab: tab)
                } else if selected.count == 1 {
                    SingleInfoView(item: selected[0])
                        .id(selected[0].url)
                } else {
                    MultiInfoView(items: selected)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)
            Text(value)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

// MARK: - 单个项目

enum PreviewContent {
    case image(NSImage, CGSize)
    case pdf(URL)
    case text(String, Bool)
    case thumbnail(NSImage?)
}

struct SingleInfoView: View {
    let item: FileItem
    @State private var preview: PreviewContent?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            previewView
            Text(item.name)
                .font(.headline)
                .textSelection(.enabled)
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "种类", value: item.kind.isEmpty ? "—" : item.kind)
                InfoRow(label: "大小", value: sizeDescription)
                if item.needsFolderSize {
                    if let info = item.folderInfo {
                        InfoRow(label: "内容", value: "\(info.files) 个文件，\(info.folders) 个文件夹")
                        InfoRow(label: "占用", value: Format.bytes(info.allocated))
                    }
                } else {
                    InfoRow(label: "占用", value: Format.bytes(item.allocatedSize))
                }
                if let px = pixelSize, px.width > 0 {
                    InfoRow(label: "尺寸", value: "\(Int(px.width)) × \(Int(px.height)) 像素")
                }
                InfoRow(label: "位置", value: item.parentPath)
                InfoRow(label: "创建", value: Format.date(item.created))
                InfoRow(label: "修改", value: Format.date(item.modified))
                if let perm = permissionText {
                    InfoRow(label: "权限", value: perm)
                }
            }
            if item.needsFolderSize && item.folderInfo == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在计算文件夹大小…").foregroundStyle(.secondary)
                }
            }
        }
        .task(id: item.url) {
            preview = await loadPreview(item)
        }
    }

    var pixelSize: CGSize? {
        if let p = preview, case .image(_, let px) = p { return px }
        return nil
    }

    var sizeDescription: String {
        guard let b = item.sizeBytes else { return "计算中…" }
        return "\(Format.bytes(b))（\(Format.exactBytes(b))）"
    }

    var permissionText: String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: item.url.path),
              let mode = attrs[.posixPermissions] as? Int else { return nil }
        return Format.permissions(mode)
    }

    @ViewBuilder
    var previewView: some View {
        if let p = preview {
            switch p {
            case .image(let img, _):
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            case .pdf(let url):
                PDFPreview(url: url)
                    .frame(height: 340)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            case .text(let s, let truncated):
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.isEmpty ? "（空文件）" : s)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .frame(maxHeight: 260, alignment: .top)
                        .clipped()
                    if truncated {
                        Text("（仅显示开头部分）").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            case .thumbnail(let img):
                Image(nsImage: img ?? IconCache.icon(for: item))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 160)
            }
        } else {
            Image(nsImage: IconCache.icon(for: item))
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 120)
        }
    }
}

func loadPreview(_ item: FileItem) async -> PreviewContent {
    if item.isDirectory {
        return .thumbnail(nil)
    }
    let type = UTType(filenameExtension: item.ext)
    let url = item.url
    if type?.conforms(to: .image) == true {
        let r = await Task.detached(priority: .userInitiated) { () -> (NSImage, CGSize)? in
            return ImageTools.downsample(url, maxPixel: 1200)
        }.value
        if let r = r { return .image(r.0, r.1) }
    }
    if type?.conforms(to: .pdf) == true {
        return .pdf(url)
    }
    let t = await Task.detached(priority: .userInitiated) { () -> (String, Bool)? in
        return TextProbe.read(url, limit: 64 * 1024)
    }.value
    if let t = t { return .text(t.0, t.1) }
    return .thumbnail(await Thumbnails.shared.thumbnail(for: url, size: 256))
}

struct PDFPreview: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> PDFView {
        let v = PDFView()
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.document = PDFDocument(url: url)
        return v
    }

    func updateNSView(_ v: PDFView, context: Context) {
        if v.document?.documentURL != url {
            v.document = PDFDocument(url: url)
        }
    }
}

// MARK: - 多选

struct MultiInfoView: View {
    let items: [FileItem]

    var body: some View {
        let s = SelectionSummary.make(from: items)
        VStack(alignment: .leading, spacing: 12) {
            Text("已选择 \(s.count) 项")
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text("总大小")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(Format.bytes(s.totalBytes))
                    .font(.system(size: 28, weight: .semibold))
                Text(Format.exactBytes(s.totalBytes))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if s.pendingFolders > 0 {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("\(s.pendingFolders) 个文件夹还在计算，总大小会自动更新")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "文件", value: "\(s.fileCount) 个")
                InfoRow(label: "文件夹", value: "\(s.folderCount) 个")
                if s.folderCount > 0 || s.innerFiles > 0 {
                    InfoRow(label: "内含", value: "\(s.innerFiles) 个文件，\(s.innerFolders) 个文件夹")
                }
                InfoRow(label: "占用", value: Format.bytes(s.allocatedBytes))
            }
            if !s.kinds.isEmpty {
                Divider()
                Text("类型分布")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(Array(s.kinds.prefix(8)), id: \.kind) { k in
                    HStack {
                        Text(k.kind).lineLimit(1)
                        Spacer()
                        Text("\(k.count)").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }
}

// MARK: - 未选中：当前文件夹

struct FolderInfoView: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        let files = tab.items.filter { !$0.isFolder }
        let folders = tab.items.filter { $0.isFolder }
        let fileBytes = tab.items.reduce(Int64(0)) { $0 + max($1.sortSize, 0) }
        VStack(alignment: .leading, spacing: 12) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: tab.url.path))
                .resizable()
                .frame(width: 64, height: 64)
                .shadow(color: Color.black.opacity(0.28), radius: 3, x: 0, y: 2)
            Text(tab.title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                InfoRow(label: "位置", value: tab.url.path)
                InfoRow(label: "内容", value: "\(files.count) 个文件，\(folders.count) 个文件夹")
                InfoRow(label: "本层", value: Format.bytes(fileBytes))
                if let info = tab.currentFolderInfo {
                    InfoRow(label: "总大小", value: "\(Format.bytes(info.bytes))（\(Format.exactBytes(info.bytes))）")
                    InfoRow(label: "含有", value: "\(info.files) 个文件，\(info.folders) 个文件夹")
                }
            }
            if tab.computingCurrentFolder {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在统计整个文件夹…").foregroundStyle(.secondary)
                }
            } else if tab.currentFolderInfo == nil {
                Button("计算此文件夹的总大小") { tab.computeCurrentFolderSize() }
            }
            Text("提示：点选文件可查看详细信息与预览；多选可查看总大小。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
