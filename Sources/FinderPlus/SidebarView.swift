import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SidebarView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        if let tab = app.activeTab {
            SidebarContent(tab: tab)
        } else {
            Color.clear
        }
    }
}

struct SidebarContent: View {
    @ObservedObject var tab: TabModel
    @EnvironmentObject var app: AppModel

    var body: some View {
        let activePath = tab.url.standardizedFileURL.path
        VStack(spacing: 0) {
        List {
            Section("收藏夹") {
                ForEach(app.favorites, id: \.self) { path in
                    SidebarRow(path: path, title: nil, removable: true, activePath: activePath)
                }
                .onMove { source, destination in
                    app.favorites.move(fromOffsets: source, toOffset: destination)
                }
            }
            Section("位置") {
                ForEach(app.volumes, id: \.self) { vol in
                    SidebarRow(path: vol.path, title: volumeName(vol), removable: false, activePath: activePath)
                }
            }
        }
        .listStyle(.sidebar)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            return app.addFavoritesFromDrop(providers)
        }
        ClipboardPanel()
        }
    }

    func volumeName(_ url: URL) -> String {
        if url.path == "/" {
            let name = try? url.resourceValues(forKeys: [.volumeNameKey]).volumeName
            return name ?? "Macintosh HD"
        }
        return FileManager.default.displayName(atPath: url.path)
    }
}

struct SidebarRow: View {
    let path: String
    let title: String?
    let removable: Bool
    let activePath: String
    @EnvironmentObject var app: AppModel
    @State private var targeted = false

    var body: some View {
        let url = URL(fileURLWithPath: path)
        let isActive = activePath == path
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: path))
                .resizable()
                .frame(width: 18, height: 18)
                .shadow(color: Color.black.opacity(0.28), radius: 1.5, x: 0, y: 1)
            Text(title ?? FileManager.default.displayName(atPath: path))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isActive ? Color.accentColor.opacity(0.22) : (targeted ? Color.accentColor.opacity(0.14) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) {
                app.newTab(url: url)
            } else {
                app.activeTab?.navigate(to: url)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in
            return app.handleDrop(providers, into: url)
        }
        .contextMenu {
            Button("打开") { app.activeTab?.navigate(to: url) }
            Button("在新标签页中打开") { app.newTab(url: url) }
            Button("在终端中打开") { app.openTerminal(url) }
            if removable {
                Divider()
                Button("从收藏夹移除") { app.removeFavorite(path) }
            }
        }
    }
}
