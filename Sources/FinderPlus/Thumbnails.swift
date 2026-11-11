import SwiftUI
import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers
import FinderCore

/// 系统图标缓存（只在主线程使用）
enum IconCache {
    static var cache: [String: NSImage] = [:]

    static func icon(for item: FileItem) -> NSImage {
        let key: String
        if item.isPackage || item.isSymlink {
            key = item.url.path
        } else if item.isFolder {
            key = "folder"
        } else {
            key = "ext:" + item.ext
        }
        if let c = cache[key] { return c }
        let img: NSImage
        if key == "folder" {
            img = NSWorkspace.shared.icon(for: UTType.folder)
        } else if key.hasPrefix("ext:") {
            if item.ext.isEmpty {
                img = NSWorkspace.shared.icon(for: UTType.data)
            } else {
                img = NSWorkspace.shared.icon(for: UTType(filenameExtension: item.ext) ?? UTType.data)
            }
        } else {
            img = NSWorkspace.shared.icon(forFile: item.url.path)
        }
        cache[key] = img
        return img
    }
}

/// 缩略图（图片、视频、PDF 等）通过系统 QuickLook 生成，带缓存
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, NSImage>()

    func thumbnail(for url: URL, size: CGFloat) async -> NSImage? {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(url.path)#\(Int(size))" as NSString
        if let c = cache.object(forKey: key) { return c }
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: CGSize(width: size, height: size),
                                                   scale: scale,
                                                   representationTypes: .thumbnail)
        do {
            let rep = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            let img = NSImage(cgImage: rep.cgImage, size: .zero)
            cache.setObject(img, forKey: key)
            return img
        } catch {
            return nil
        }
    }
}

struct ThumbKey: Hashable {
    let url: URL
    let size: Int
    let modified: Date?
}

/// 文件图标：先显示系统图标，有缩略图时替换
struct FileIconView: View {
    let item: FileItem
    let size: CGFloat
    let thumbnail: Bool
    @State private var thumb: NSImage?

    var body: some View {
        Image(nsImage: thumb ?? IconCache.icon(for: item))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .shadow(color: Color.black.opacity(0.28), radius: max(1, size * 0.04), x: 0, y: max(0.5, size * 0.025))
            .opacity(item.isHidden ? 0.6 : 1)
            .task(id: ThumbKey(url: item.url, size: Int(size), modified: item.modified)) {
                if thumbnail && !item.isDirectory && size >= 32 {
                    thumb = await Thumbnails.shared.thumbnail(for: item.url, size: size)
                } else {
                    thumb = nil
                }
            }
    }
}

enum ImageTools {
    /// 下采样读取图片，避免大图占用大量内存；同时返回像素尺寸
    static func downsample(_ url: URL, maxPixel: Int) -> (NSImage, CGSize)? {
        let opts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithURL(url as CFURL, opts) else { return nil }
        var pixelSize = CGSize.zero
        if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int,
           let h = props[kCGImagePropertyPixelHeight] as? Int {
            pixelSize = CGSize(width: w, height: h)
        }
        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else { return nil }
        return (NSImage(cgImage: cg, size: .zero), pixelSize)
    }
}

enum TextProbe {
    /// 读取文件开头一段作为文本预览；看起来是二进制则返回 nil
    static func read(_ url: URL, limit: Int) -> (String, Bool)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit + 1) else { return nil }
        if data.isEmpty { return ("", false) }
        if data.contains(0) { return nil }
        let truncated = data.count > limit
        let slice = truncated ? data.prefix(limit) : data
        let text = String(decoding: slice, as: UTF8.self)
        let bad = text.unicodeScalars.filter { $0 == "\u{FFFD}" }.count
        if bad > 4 && bad * 20 > text.unicodeScalars.count { return nil }
        return (text, truncated)
    }
}
