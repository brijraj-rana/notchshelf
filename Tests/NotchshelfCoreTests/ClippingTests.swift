import XCTest
@testable import NotchshelfCore

final class ClippingTests: XCTestCase {
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

    private func inDrops(_ url: URL, of store: ShelfStore) -> Bool {
        url.resolvingSymlinksInPath().path.hasPrefix(store.dropsDirectory.resolvingSymlinksInPath().path + "/")
    }

    // MARK: Names

    func testTextIsNamedAfterItsFirstLineThatSaysSomething() {
        XCTAssertEqual(ClippingName.forText("Ship the build on Friday"), "Ship the build on Friday")
        XCTAssertEqual(ClippingName.forText("\n\n   ---\n  Second line wins \nthird"), "Second line wins")
        XCTAssertEqual(ClippingName.forText("   \n\t"), "Text")
        XCTAssertEqual(ClippingName.forText("***"), "Text")
    }

    func testNamesAreSafeAsFileNames() {
        XCTAssertEqual(ClippingName.clean("a/b: c"), "a-b- c")
        XCTAssertEqual(ClippingName.clean("..hidden"), "hidden")
        XCTAssertEqual(ClippingName.clean("tabs\tand\u{0}  spaces"), "tabs and spaces")
        XCTAssertEqual(ClippingName.clean("ends with a stop."), "ends with a stop")
        XCTAssertEqual(ClippingName.clean(" . "), "")
    }

    func testLongNamesStopAtAWord() {
        let name = ClippingName.forText("The quick brown fox jumps over the lazy dog and keeps going for a while")
        XCTAssertEqual(name, "The quick brown fox jumps over the lazy")
        XCTAssertLessThanOrEqual(name.count, ClippingName.limit)

        // One long word has no good place to stop, so it is cut at the limit.
        let word = String(repeating: "a", count: 90)
        XCTAssertEqual(ClippingName.forText(word).count, ClippingName.limit)
    }

    func testALinkIsNamedAfterItsTitleOrItsSite() throws {
        let page = try XCTUnwrap(URL(string: "https://www.example.com/docs/getting-started"))
        XCTAssertEqual(ClippingName.forLink(page, title: "Getting started: the basics"), "Getting started- the basics")
        XCTAssertEqual(ClippingName.forLink(page, title: nil), "example.com getting-started")
        XCTAssertEqual(ClippingName.forLink(page, title: "  "), "example.com getting-started")
        // A title that only repeats an address says nothing the site name does not.
        XCTAssertEqual(ClippingName.forLink(page, title: page.absoluteString), "example.com getting-started")
        XCTAssertEqual(ClippingName.forLink(page, title: "https://example.com/other"), "example.com getting-started")

        let file = try XCTUnwrap(URL(string: "https://example.com/a/pricing.html"))
        XCTAssertEqual(ClippingName.forLink(file, title: nil), "example.com pricing")
        let home = try XCTUnwrap(URL(string: "https://example.com/"))
        XCTAssertEqual(ClippingName.forLink(home, title: nil), "example.com")
        let mail = try XCTUnwrap(URL(string: "mailto:hello@example.com"))
        XCTAssertEqual(ClippingName.forLink(mail, title: nil), "hello@example.com")
    }

    func testAnImageKeepsTheNameItCameWith() {
        XCTAssertEqual(ClippingName.forImage(source: "team%20photo.jpeg"), "team photo")
        XCTAssertEqual(ClippingName.forImage(source: nil), "Image")
        XCTAssertEqual(ClippingName.forImage(source: ""), "Image")
        XCTAssertEqual(ClippingName.forImage(source: "/"), "Image")
    }

    // MARK: Files

    func testFileNamesAndTypes() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/a"))
        XCTAssertEqual(Clipping.text("Hello there\nmore").fileName, "Hello there.txt")
        XCTAssertEqual(Clipping.link(url, title: "Example").fileName, "Example.webloc")
        XCTAssertEqual(Clipping.image(Data([1]), fileExtension: "png", name: nil).fileName, "Image.png")
        XCTAssertEqual(Clipping.image(Data([1]), fileExtension: "jpg", name: "cat.jpeg").fileName, "cat.jpg")
    }

    func testTextIsWrittenAsItCame() {
        let text = "  two\nlines, and an é  \n"
        XCTAssertEqual(Clipping.text(text).contents, Data(text.utf8))
    }

    func testALinkFileHoldsItsAddress() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/path?q=1&r=2"))
        let data = try XCTUnwrap(Clipping.link(url, title: nil).contents)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: String]
        XCTAssertEqual(plist, ["URL": "https://example.com/path?q=1&r=2"])
    }

    func testImageFormats() {
        XCTAssertEqual(ImageChoice.best(among: ["public.tiff", "public.png"]), ImageChoice(type: "public.png", fileExtension: "png"))
        XCTAssertEqual(ImageChoice.best(among: ["public.jpeg"])?.fileExtension, "jpg")
        XCTAssertEqual(ImageChoice.best(among: ["com.compuserve.gif", "public.tiff"])?.fileExtension, "gif")
        // TIFF is what a bare image usually arrives as. It is saved as a PNG.
        XCTAssertEqual(ImageChoice.best(among: ["public.tiff"]), ImageChoice(type: "public.tiff", fileExtension: "png", convert: true))
        XCTAssertNil(ImageChoice.best(among: ["public.utf8-plain-text", "public.html"]))
    }

    // MARK: What a pasteboard means

    func testFilesComeFirst() {
        let offer = Offer(fileCount: 2, promiseCount: 1, types: ["public.tiff"], url: "https://example.com", text: "name.png")
        XCTAssertEqual(Intake.plan(for: offer), .files)
        XCTAssertEqual(Intake.plan(for: Offer(promiseCount: 1, types: ["public.tiff"], text: "words")), .promises)
    }

    func testPlainTextIsText() {
        XCTAssertEqual(Intake.plan(for: Offer(text: " some words\n")), .text(" some words\n"))
        XCTAssertEqual(Intake.plan(for: Offer(text: "see https://example.com for more")), .text("see https://example.com for more"))
        XCTAssertEqual(Intake.plan(for: Offer(text: "example.com")), .text("example.com"))
    }

    func testNothingToShelve() {
        XCTAssertNil(Intake.plan(for: Offer()))
        XCTAssertNil(Intake.plan(for: Offer(text: "  \n ")))
        XCTAssertNil(Intake.plan(for: Offer(types: ["com.example.private"], url: "file:///tmp/a.txt")))
    }

    func testAnAddressOnItsOwnIsALink() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/page"))
        XCTAssertEqual(Intake.plan(for: Offer(text: " https://example.com/page\n")), .link(url, title: nil))
        XCTAssertEqual(Intake.plan(for: Offer(url: "https://example.com/page", urlTitle: "A page", text: "https://example.com/page")),
                       .link(url, title: "A page"))
        // No title, but the text entry carries the link's words.
        XCTAssertEqual(Intake.plan(for: Offer(url: "https://example.com/page", text: "read this")), .link(url, title: "read this"))
        XCTAssertEqual(Intake.plan(for: Offer(url: "https://example.com/page", urlTitle: " ", text: nil)), .link(url, title: nil))

        let mail = try XCTUnwrap(URL(string: "mailto:hello@example.com"))
        XCTAssertEqual(Intake.plan(for: Offer(url: "mailto:hello@example.com")), .link(mail, title: nil))
        // Not a web address, and nothing on the pasteboard calls it a link.
        XCTAssertEqual(Intake.plan(for: Offer(text: "mailto:hello@example.com")), .text("mailto:hello@example.com"))
    }

    func testAnImageWinsUnlessItComesWithWords() {
        let png = ImageChoice(type: "public.png", fileExtension: "png")
        XCTAssertEqual(Intake.plan(for: Offer(types: ["public.png", "public.tiff"])), .image(png, source: nil))
        // A copied web image brings its address along.
        XCTAssertEqual(Intake.plan(for: Offer(types: ["public.png"], url: "https://example.com/img/cat.jpg", text: "https://example.com/img/cat.jpg")),
                       .image(png, source: "cat.jpg"))
        XCTAssertEqual(Intake.plan(for: Offer(types: ["public.png"], text: "https://example.com/img/dog.png")), .image(png, source: "dog.png"))
        // A copied spreadsheet cell brings a picture of itself along. The words are what was meant.
        XCTAssertEqual(Intake.plan(for: Offer(types: ["public.tiff", "public.utf8-plain-text"], text: "Q3 total\t4200")), .text("Q3 total\t4200"))
    }

    // MARK: On the shelf

    func testAClippingBecomesAFileTheShelfOwns() throws {
        let store = makeStore()
        let item = try XCTUnwrap(store.add(.text("Remember the milk\nand the bread")))

        XCTAssertEqual(item.name, "Remember the milk.txt")
        XCTAssertTrue(item.owned)
        XCTAssertTrue(inDrops(item.url, of: store))
        XCTAssertEqual(try String(contentsOf: item.url, encoding: .utf8), "Remember the milk\nand the bread")
        XCTAssertEqual(store.items.map(\.id), [item.id])
    }

    func testTheSameNameTwiceMakesTwoFiles() throws {
        let store = makeStore()
        let first = try XCTUnwrap(store.add(.text("same")))
        let second = try XCTUnwrap(store.add(.text("same")))
        XCTAssertNotEqual(first.url, second.url)
        XCTAssertEqual(store.items.map(\.name), ["same.txt", "same.txt"])
    }

    func testAClippingsFileGoesWhenItLeavesTheShelf() throws {
        let store = makeStore()
        let url = try XCTUnwrap(URL(string: "https://example.com/"))
        let link = try XCTUnwrap(store.add(.link(url, title: "Example")))
        let image = try XCTUnwrap(store.add(.image(Data([1, 2, 3]), fileExtension: "png", name: nil)))
        XCTAssertEqual(store.items.map(\.name), ["Image.png", "Example.webloc"])

        store.remove([link.id])
        XCTAssertFalse(fm.fileExists(atPath: link.url.path))
        XCTAssertFalse(fm.fileExists(atPath: link.url.deletingLastPathComponent().path))
        XCTAssertTrue(fm.fileExists(atPath: image.url.path))

        store.clear()
        XCTAssertFalse(fm.fileExists(atPath: image.url.path))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: store.dropsDirectory.path), [])
    }

    func testClippingsSurviveARestart() throws {
        let item = try XCTUnwrap(makeStore().add(.text("still here")))
        let reopened = makeStore()
        XCTAssertEqual(reopened.items, [item])
        XCTAssertTrue(fm.fileExists(atPath: item.url.path))
    }

    // MARK: Keeping

    func testPinsPersist() throws {
        let store = makeStore()
        store.add([try makeFile("a.txt"), try makeFile("b.txt")])
        store.setPinned(true, for: [store.items[1].id])
        XCTAssertEqual(store.items.map(\.pinned), [false, true])

        let reopened = makeStore()
        XCTAssertEqual(reopened.items.map(\.pinned), [false, true])
        reopened.setPinned(false, for: [reopened.items[1].id])
        XCTAssertEqual(makeStore().items.map(\.pinned), [false, false])
    }

    func testClearLeavesPinnedItems() throws {
        let store = makeStore()
        let clipping = try XCTUnwrap(store.add(.text("keep me")))
        store.add([try makeFile("a.txt")])
        store.setPinned(true, for: [clipping.id])

        store.clear()
        XCTAssertEqual(store.items.map(\.id), [clipping.id])
        XCTAssertTrue(fm.fileExists(atPath: clipping.url.path))

        store.clear(includingPinned: true)
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(fm.fileExists(atPath: clipping.url.path))
    }

    func testRemovingAPinnedItemStillRemovesIt() throws {
        let store = makeStore()
        store.add([try makeFile("a.txt")])
        store.setPinned(true, for: [store.items[0].id])
        store.remove([store.items[0].id])
        XCTAssertTrue(store.items.isEmpty)
    }

    func testWhatLeavesAfterADragOut() {
        let plain = ShelfItem(url: URL(fileURLWithPath: "/tmp/a.txt"))
        let pinned = ShelfItem(url: URL(fileURLWithPath: "/tmp/b.txt"), pinned: true)

        XCTAssertEqual(DragOut.leaving([plain, pinned], optionHeld: false, keepAll: false), [plain.id])
        XCTAssertEqual(DragOut.leaving([plain, pinned], optionHeld: true, keepAll: false), [])
        XCTAssertEqual(DragOut.leaving([plain, pinned], optionHeld: false, keepAll: true), [])
        XCTAssertEqual(DragOut.leaving([], optionHeld: false, keepAll: false), [])
    }

    func testAKeptFileOfTheShelfsOwnIsOnlyCopied() {
        let file = ShelfItem(url: URL(fileURLWithPath: "/tmp/a.txt"), pinned: true)
        let clipping = ShelfItem(url: URL(fileURLWithPath: "/tmp/b.txt"), owned: true)
        var kept = clipping
        kept.pinned = true

        XCTAssertFalse(DragOut.mustCopy([file, clipping], keepAll: false))
        XCTAssertTrue(DragOut.mustCopy([file, kept], keepAll: false))
        XCTAssertTrue(DragOut.mustCopy([clipping], keepAll: true))
        XCTAssertFalse(DragOut.mustCopy([file], keepAll: true))
    }

    // MARK: Older shelves

    func testAShelfSavedBeforePinsStillLoads() throws {
        let a = try makeFile("a.txt")
        let b = try makeFile("b.txt")
        let directory = root.appendingPathComponent("store")
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // The 0.2.0 format: no `pinned`, and `bookmark` left out when there was none.
        let bookmark = try a.bookmarkData().base64EncodedString()
        let saved = """
        [{"id":"7E0C5A52-3B0F-4D0B-9C39-0C7B6E1B1A01","url":"\(a.absoluteString)","bookmark":"\(bookmark)","addedAt":752000000.5,"owned":false},
         {"id":"7E0C5A52-3B0F-4D0B-9C39-0C7B6E1B1A02","url":"\(b.absoluteString)","addedAt":752000001,"owned":true}]
        """
        try Data(saved.utf8).write(to: directory.appendingPathComponent("shelf.json"))

        let store = makeStore()
        XCTAssertEqual(store.items.map(\.name), ["a.txt", "b.txt"])
        XCTAssertEqual(store.items.map(\.pinned), [false, false])
        XCTAssertEqual(store.items.map(\.owned), [false, true])
        XCTAssertEqual(store.items[0].id.uuidString, "7E0C5A52-3B0F-4D0B-9C39-0C7B6E1B1A01")
        XCTAssertEqual(store.items[0].addedAt.timeIntervalSinceReferenceDate, 752000000.5)
        XCTAssertNotNil(store.items[0].bookmark)

        // And it is written back in a form the same code reads again.
        store.setPinned(true, for: [store.items[0].id])
        XCTAssertEqual(makeStore().items.map(\.pinned), [true, false])
    }
}
