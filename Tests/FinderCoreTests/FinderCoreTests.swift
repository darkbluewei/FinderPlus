import XCTest
@testable import FinderCore

final class FinderCoreTests: XCTestCase {
    var root: URL!
    let ops = FileOperations()
    let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("FinderPlusTests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    func makeFile(_ rel: String, bytes: Int = 10) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: bytes).write(to: url)
        return url
    }

    func makeDir(_ rel: String) throws -> URL {
        let url = root.appendingPathComponent(rel)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: 列表 / 条目

    func testListingAndHidden() throws {
        try makeFile("a.txt")
        try makeFile(".hidden")
        _ = try makeDir("folder")
        let shown = try DirectoryLister.list(root, showHidden: false)
        XCTAssertEqual(Set(shown.map { $0.name }), ["a.txt", "folder"])
        let all = try DirectoryLister.list(root, showHidden: true)
        XCTAssertEqual(all.count, 3)
        XCTAssertTrue(shown.first { $0.name == "folder" }!.isFolder)
        XCTAssertEqual(shown.first { $0.name == "a.txt" }!.fileSize, 10)
    }

    // MARK: 唯一命名

    func testUniqueURL() throws {
        let f = try makeFile("report.txt")
        XCTAssertEqual(ops.uniqueURL(f).lastPathComponent, "report 2.txt")
        try makeFile("report 2.txt")
        XCTAssertEqual(ops.uniqueURL(f).lastPathComponent, "report 3.txt")
        let d = try makeDir("v1.2")
        XCTAssertEqual(ops.uniqueURL(d).lastPathComponent, "v1.2 2")
    }

    // MARK: 复制 / 移动

    func testCopyPolicies() throws {
        let src = try makeFile("src/a.txt", bytes: 5)
        let dst = try makeDir("dst")
        try makeFile("dst/a.txt", bytes: 99)

        XCTAssertEqual(ops.conflicts(sources: [src], in: dst), ["a.txt"])

        var out = ops.copy([src], to: dst, policy: .skip)
        XCTAssertEqual(out.done.count, 0)
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("a.txt")).count, 99)

        out = ops.copy([src], to: dst, policy: .keepBoth)
        XCTAssertEqual(out.done.first?.to.lastPathComponent, "a 2.txt")

        out = ops.copy([src], to: dst, policy: .replace)
        XCTAssertEqual(out.done.count, 1)
        XCTAssertEqual(try Data(contentsOf: dst.appendingPathComponent("a.txt")).count, 5)
        XCTAssertTrue(fm.fileExists(atPath: src.path))
    }

    func testDuplicateInSameFolder() throws {
        let f = try makeFile("x.txt")
        let out = ops.copy([f], to: root, policy: .keepBoth)
        XCTAssertEqual(out.done.first?.to.lastPathComponent, "x 2.txt")
    }

    func testMoveAndUndo() throws {
        let src = try makeFile("src/m.txt")
        let dst = try makeDir("dst")
        let history = OperationHistory()
        let out = ops.move([src], to: dst, policy: .keepBoth)
        XCTAssertEqual(out.done.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: src.path))
        XCTAssertTrue(fm.fileExists(atPath: dst.appendingPathComponent("m.txt").path))
        history.push("移动", .moved(out.done))
        let undone = history.undo(using: ops)
        XCTAssertNotNil(undone)
        XCTAssertTrue(fm.fileExists(atPath: src.path))
        XCTAssertFalse(history.canUndo)
    }

    func testCannotMoveFolderIntoItself() throws {
        let parent = try makeDir("parent")
        let child = try makeDir("parent/child")
        let out = ops.move([parent], to: child, policy: .keepBoth)
        XCTAssertEqual(out.done.count, 0)
        XCTAssertEqual(out.failures.count, 1)
        let out2 = ops.copy([parent], to: child, policy: .keepBoth)
        XCTAssertEqual(out2.done.count, 0)
        XCTAssertEqual(out2.failures.count, 1)
    }

    // MARK: 废纸篓

    func testTrashAndUndo() throws {
        let f = try makeFile("gone.txt")
        let out = ops.trash([f])
        XCTAssertEqual(out.done.count, 1, "failures: \(out.failures)")
        XCTAssertFalse(fm.fileExists(atPath: f.path))
        let history = OperationHistory()
        history.push("删除", .trashed(out.done))
        let undone = history.undo(using: ops)
        XCTAssertEqual(undone?.outcome.done.count, 1, "failures: \(undone?.outcome.failures ?? [])")
        XCTAssertTrue(fm.fileExists(atPath: f.path))
    }

    // MARK: 重命名 / 新建

    func testRename() throws {
        let f = try makeFile("old.txt")
        let n = try ops.rename(f, to: "new.txt")
        XCTAssertEqual(n.lastPathComponent, "new.txt")
        XCTAssertTrue(fm.fileExists(atPath: n.path))
        try makeFile("other.txt")
        XCTAssertThrowsError(try ops.rename(n, to: "other.txt"))
        XCTAssertThrowsError(try ops.rename(n, to: "a/b"))
        XCTAssertThrowsError(try ops.rename(n, to: "  "))
        let c = try ops.rename(n, to: "New.txt")   // 仅大小写变化
        XCTAssertEqual(c.lastPathComponent, "New.txt")
        let names = try fm.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains("New.txt"))
    }

    func testNewFolderAndFile() throws {
        let a = try ops.newFolder(in: root)
        let b = try ops.newFolder(in: root)
        XCTAssertEqual(a.lastPathComponent, "未命名文件夹")
        XCTAssertEqual(b.lastPathComponent, "未命名文件夹 2")
        let f = try ops.newFile(in: root, name: "未命名.txt")
        XCTAssertTrue(fm.fileExists(atPath: f.path))
    }

    func testCompress() throws {
        let a = try makeFile("a.txt")
        let b = try makeFile("b.txt")
        let z = try ops.compress([a, b], in: root)
        XCTAssertEqual(z.lastPathComponent, "归档.zip")
        XCTAssertTrue(fm.fileExists(atPath: z.path))
    }

    // MARK: 文件夹大小

    func testFolderSize() throws {
        try makeFile("d/a.bin", bytes: 1000)
        try makeFile("d/sub/b.bin", bytes: 500)
        try makeFile("d/sub/deeper/c.bin", bytes: 250)
        let size = SizeCalculator.compute(root.appendingPathComponent("d"))
        XCTAssertEqual(size?.bytes, 1750)
        XCTAssertEqual(size?.files, 3)
        XCTAssertEqual(size?.folders, 2)
        XCTAssertNil(SizeCalculator.compute(root, isCancelled: { true }))
    }

    func testFolderSizeService() throws {
        try makeFile("s/a.bin", bytes: 300)
        let svc = FolderSizeService()
        let exp = expectation(description: "size")
        var got: DirSize?
        let lock = NSLock()
        svc.request(root.appendingPathComponent("s")) { _, info in
            lock.lock(); got = info; lock.unlock()
            exp.fulfill()
        }
        wait(for: [exp], timeout: 10)
        lock.lock(); defer { lock.unlock() }
        XCTAssertEqual(got?.bytes, 300)
        XCTAssertEqual(svc.cached(root.appendingPathComponent("s"))?.bytes, 300)
    }

    // MARK: 搜索

    func testSearchCriteria() throws {
        let a = FileItem(url: try makeFile("Holiday Photo.JPG", bytes: 2000))
        let b = FileItem(url: try makeFile("notes.txt", bytes: 10))
        let d = FileItem(url: try makeDir("photos"))

        var c = SearchCriteria()
        c.text = "photo"
        XCTAssertTrue(c.matches(a))
        XCTAssertTrue(c.matches(d))
        XCTAssertFalse(c.matches(b))

        c = SearchCriteria()
        c.extensions = ["jpg", "png"]
        XCTAssertTrue(c.matches(a))
        XCTAssertFalse(c.matches(b))
        XCTAssertFalse(c.matches(d))

        c = SearchCriteria()
        c.minSize = 1000
        XCTAssertTrue(c.matches(a))
        XCTAssertFalse(c.matches(b))

        c = SearchCriteria()
        c.scope = .foldersOnly
        XCTAssertTrue(c.matches(d))
        XCTAssertFalse(c.matches(a))

        c = SearchCriteria()
        c.modifiedAfter = Date().addingTimeInterval(3600)
        XCTAssertFalse(c.matches(a))
        c.modifiedAfter = Date().addingTimeInterval(-3600)
        XCTAssertTrue(c.matches(a))
    }

    func testRecursiveSearch() throws {
        try makeFile("x/one.txt")
        try makeFile("x/y/two.txt")
        try makeFile("x/y/three.md")
        var c = SearchCriteria()
        c.extensions = ["txt"]
        var found: [FileItem] = []
        let total = Searcher.search(root: root, criteria: c) { found.append(contentsOf: $0) }
        XCTAssertEqual(total, 2)
        XCTAssertEqual(Set(found.map { $0.name }), ["one.txt", "two.txt"])
    }

    // MARK: 批量重命名

    func testBatchRenameRules() {
        let rules = [
            RenameRule(.replace(find: "IMG", with: "照片", regex: false, caseSensitive: true)),
            RenameRule(.prefix("2026_")),
            RenameRule(.numbering(start: 1, step: 1, digits: 3, atStart: false, separator: "_"))
        ]
        let r = BatchRenamer.transform("IMG_0042.jpg", index: 4, rules: rules)
        XCTAssertEqual(r.name, "2026_照片_0042_005.jpg")
        let c = BatchRenamer.transform("Hello World.TXT", index: 0, rules: [RenameRule(.changeCase(.lower))])
        XCTAssertEqual(c.name, "hello world.TXT")
        let bad = BatchRenamer.transform("a.txt", index: 0, rules: [RenameRule(.replace(find: "(", with: "", regex: true, caseSensitive: true))])
        XCTAssertNotNil(bad.error)
        let re = BatchRenamer.transform("file123.txt", index: 0, rules: [RenameRule(.replace(find: "[0-9]+", with: "N", regex: true, caseSensitive: true))])
        XCTAssertEqual(re.name, "fileN.txt")
    }

    func testBatchRenameConflictsAndExecute() throws {
        let a = try makeFile("a.txt")
        let b = try makeFile("b.txt")
        // 两个文件都改成同一个名字 → 冲突
        let dup = BatchRenamer.plan(urls: [a, b], rules: [RenameRule(.replace(find: "a", with: "z", regex: false, caseSensitive: true)),
                                                           RenameRule(.replace(find: "b", with: "z", regex: false, caseSensitive: true))])
        XCTAssertTrue(dup.contains { $0.problem != nil })

        // 加前缀，正常执行
        let plans = BatchRenamer.plan(urls: [a, b], rules: [RenameRule(.prefix("x_"))])
        XCTAssertTrue(plans.allSatisfy { $0.problem == nil })
        let out = BatchRenamer.execute(plans)
        XCTAssertEqual(out.done.count, 2)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("x_a.txt").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("x_b.txt").path))
    }

    func testBatchRenameSwap() throws {
        let one = try makeFile("1.txt", bytes: 1)
        let two = try makeFile("2.txt", bytes: 2)
        let plans = [
            RenamePlan(url: one, oldName: "1.txt", newName: "2.txt"),
            RenamePlan(url: two, oldName: "2.txt", newName: "1.txt")
        ]
        let out = BatchRenamer.execute(plans)
        XCTAssertEqual(out.done.count, 2)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("2.txt")).count, 1)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("1.txt")).count, 2)
    }

    // MARK: 路径

    func testPathParser() {
        XCTAssertEqual(PathParser.resolve("~/Documents")?.path, NSHomeDirectory() + "/Documents")
        XCTAssertEqual(PathParser.resolve("  \"/tmp/a b\"  ")?.path, "/tmp/a b")
        XCTAssertEqual(PathParser.resolve("/tmp/a\\ b")?.path, "/tmp/a b")
        XCTAssertEqual(PathParser.resolve("file:///tmp/x")?.path, "/tmp/x")
        XCTAssertNil(PathParser.resolve(""))
        XCTAssertNil(PathParser.resolve("relative/path"))
        XCTAssertEqual(PathParser.resolve("sub", relativeTo: URL(fileURLWithPath: "/tmp"))?.path, "/tmp/sub")
    }

    func testPathCompleter() throws {
        _ = try makeDir("alpha")
        _ = try makeDir("alps")
        try makeFile("alpaca.txt")
        let s = PathCompleter.suggestions(for: root.path + "/al")
        XCTAssertEqual(s.count, 2)
        XCTAssertTrue(s.allSatisfy { $0.hasSuffix("/") })
        XCTAssertEqual(PathCompleter.commonPrefix(["/a/alpha/", "/a/alps/"]), "/a/alp")
    }

    // MARK: 选中汇总

    func testSelectionSummary() throws {
        let f1 = FileItem(url: try makeFile("a.txt", bytes: 100))
        let f2 = FileItem(url: try makeFile("b.txt", bytes: 50))
        var d = FileItem(url: try makeDir("dir"))
        var s = SelectionSummary.make(from: [f1, f2, d])
        XCTAssertEqual(s.count, 3)
        XCTAssertEqual(s.fileCount, 2)
        XCTAssertEqual(s.folderCount, 1)
        XCTAssertEqual(s.totalBytes, 150)
        XCTAssertEqual(s.pendingFolders, 1)
        d.folderInfo = DirSize(bytes: 1000, allocated: 4096, files: 7, folders: 2)
        s = SelectionSummary.make(from: [f1, f2, d])
        XCTAssertEqual(s.totalBytes, 1150)
        XCTAssertEqual(s.pendingFolders, 0)
        XCTAssertEqual(s.innerFiles, 7)
    }

    func testFormat() {
        XCTAssertEqual(Format.permissions(0o755), "rwxr-xr-x")
        XCTAssertEqual(Format.permissions(0o600), "rw-------")
        XCTAssertFalse(Format.bytes(1_500_000).isEmpty)
    }
}
