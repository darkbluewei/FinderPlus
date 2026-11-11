import XCTest
@testable import FinderCore

final class ClipboardHistoryTests: XCTestCase {
    func testAddTextAndDedupe() {
        let h = ClipboardHistory(limit: 10)
        let t0 = Date(timeIntervalSince1970: 1000)
        XCTAssertNotNil(h.addText("hello", now: t0))
        XCTAssertNotNil(h.addText("world", now: t0.addingTimeInterval(1)))
        XCTAssertEqual(h.entries.map { $0.text }, ["world", "hello"])
        // 重复内容：移到最前，不新增
        let again = h.addText("hello", now: t0.addingTimeInterval(2))
        XCTAssertEqual(h.entries.count, 2)
        XCTAssertEqual(h.entries.first?.text, "hello")
        XCTAssertEqual(again?.date, t0.addingTimeInterval(2))
    }

    func testIgnoresEmpty() {
        let h = ClipboardHistory()
        XCTAssertNil(h.addText("   \n  "))
        XCTAssertNil(h.addFiles([]))
        XCTAssertNil(h.addImage(key: ""))
        XCTAssertEqual(h.entries.count, 0)
    }

    func testLimitKeepsPinned() {
        let h = ClipboardHistory(limit: 3)
        let base = Date(timeIntervalSince1970: 0)
        let first = h.addText("one", now: base)!
        h.togglePin(id: first.id)
        for i in 2...6 { h.addText("item \(i)", now: base.addingTimeInterval(Double(i))) }
        XCTAssertEqual(h.entries.count, 3)
        XCTAssertTrue(h.entries.contains { $0.text == "one" && $0.pinned })
        XCTAssertEqual(h.ordered.first?.text, "one")
    }

    func testImageLimit() {
        let h = ClipboardHistory(limit: 50, maxImages: 2)
        for i in 1...4 { h.addImage(key: "img-\(i)", now: Date(timeIntervalSince1970: Double(i))) }
        XCTAssertEqual(h.entries.filter { $0.kind == .image }.count, 2)
        XCTAssertEqual(h.entries.first?.imageKey, "img-4")
    }

    func testTitles() {
        let h = ClipboardHistory()
        let a = h.addText("\n  第一行内容  \n第二行")!
        XCTAssertEqual(a.title, "第一行内容")
        let long = String(repeating: "a", count: 200)
        XCTAssertTrue(h.addText(long)!.title.hasSuffix("…"))
        XCTAssertEqual(h.addFiles(["/tmp/a.txt"])!.title, "a.txt")
        XCTAssertEqual(h.addFiles(["/tmp/a.txt", "/tmp/b.txt", "/tmp/c.txt"])!.title, "a.txt 等 3 项")
        XCTAssertEqual(h.addImage(key: "k")!.title, "图片")
    }

    func testRemoveAndClear() {
        let h = ClipboardHistory()
        let a = h.addText("a")!
        let b = h.addText("b")!
        h.addText("c")
        h.togglePin(id: b.id)
        h.remove(id: a.id)
        XCTAssertEqual(h.entries.count, 2)
        h.clear(keepPinned: true)
        XCTAssertEqual(h.entries.map { $0.text }, ["b"])
        h.clear(keepPinned: false)
        XCTAssertTrue(h.entries.isEmpty)
    }

    func testPersistenceSkipsImages() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip-\(UUID().uuidString)/history.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let h = ClipboardHistory()
        let t = Date(timeIntervalSince1970: 100)
        h.addText("persist me", now: t)
        h.addFiles(["/tmp/x.txt"], now: t.addingTimeInterval(1))
        h.addImage(key: "secret-image", now: t.addingTimeInterval(2))
        try h.save(to: url)

        let h2 = ClipboardHistory()
        XCTAssertTrue(h2.load(from: url))
        XCTAssertEqual(h2.entries.count, 2)
        XCTAssertFalse(h2.entries.contains { $0.kind == .image })
        XCTAssertEqual(h2.entries.first?.kind, .files)
        XCTAssertFalse(ClipboardHistory().load(from: url.appendingPathExtension("missing")))
    }
}
