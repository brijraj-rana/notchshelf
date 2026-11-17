import XCTest
@testable import NotchshelfCore

final class NotchshelfCoreTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("notchshelf-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root.appendingPathComponent("files"), withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? fm.removeItem(at: root)
    }

    private func makeStore() -> ShelfStore {
        ShelfStore(directory: root.appendingPathComponent("store"))
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = root.appendingPathComponent("files").appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    private func path(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    func testAddsNewestFirstAndSkipsDuplicates() throws {
        let store = makeStore()
        let a = try makeFile("a.txt")
        let b = try makeFile("b.txt")

        XCTAssertEqual(store.add([a]), 1)
        XCTAssertEqual(store.add([a, b]), 1)
        XCTAssertEqual(store.items.map(\.name), ["b.txt", "a.txt"])
    }

    func testSkipsMissingFilesAndNonFileURLs() throws {
        let store = makeStore()
        let missing = root.appendingPathComponent("files/nope.txt")
        XCTAssertEqual(store.add([missing, URL(string: "https://example.com/a.png")!]), 0)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testPersistsAcrossLaunches() throws {
        let a = try makeFile("a.txt")
        makeStore().add([a])

        let reopened = makeStore()
        XCTAssertEqual(reopened.items.map(\.name), ["a.txt"])
    }

    func testRemoveLeavesTheUsersFileAlone() throws {
        let store = makeStore()
        let a = try makeFile("a.txt")
        store.add([a])

        store.remove([store.items[0].id])
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: a.path))
    }

    func testRemoveDeletesOwnedDropsOnly() throws {
        let store = makeStore()
        let dropDir = store.makeDropDirectory()
        let promised = dropDir.appendingPathComponent("photo.jpg")
        try Data("x".utf8).write(to: promised)
        // Marked as owned but living outside the shelf's folder: must survive.
        let outside = try makeFile("outside.txt")

        store.add([promised], owned: true)
        store.add([outside], owned: true)
        store.clear()

        XCTAssertFalse(fm.fileExists(atPath: promised.path))
        XCTAssertFalse(fm.fileExists(atPath: dropDir.path))
        XCTAssertTrue(fm.fileExists(atPath: outside.path))
        XCTAssertTrue(fm.fileExists(atPath: store.dropsDirectory.path))
    }

    func testRefreshDropsDeletedFiles() throws {
        let store = makeStore()
        let a = try makeFile("a.txt")
        let b = try makeFile("b.txt")
        store.add([a, b])

        try fm.removeItem(at: a)
        store.refresh()
        XCTAssertEqual(store.items.map(\.name), ["b.txt"])
    }

    func testRefreshFollowsAMovedFile() throws {
        let store = makeStore()
        let a = try makeFile("a.txt")
        store.add([a])

        let moved = root.appendingPathComponent("files/renamed.txt")
        try fm.moveItem(at: a, to: moved)
        store.refresh()

        XCTAssertEqual(store.items.count, 1)
        XCTAssertEqual(path(store.items[0].url), path(moved))
    }
}
