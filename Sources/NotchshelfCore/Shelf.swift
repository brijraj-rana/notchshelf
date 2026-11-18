import Combine
import Foundation

/// One file parked on the shelf. The shelf holds a reference to the file, not a copy.
public struct ShelfItem: Identifiable, Codable, Equatable {
    public let id: UUID
    public var url: URL
    /// Lets the shelf follow the file if it is renamed or moved while parked.
    public var bookmark: Data?
    public var addedAt: Date
    /// True when the shelf wrote the file into its own folder: a promised photo or web image, or text,
    /// a link or an image that arrived with no file behind it.
    public var owned: Bool
    /// Kept on the shelf: dragging it out leaves it here, and Clear passes it by.
    public var pinned: Bool

    public var name: String { url.lastPathComponent }

    public init(id: UUID = UUID(), url: URL, bookmark: Data? = nil, addedAt: Date = Date(), owned: Bool = false, pinned: Bool = false) {
        self.id = id
        self.url = url
        self.bookmark = bookmark
        self.addedAt = addedAt
        self.owned = owned
        self.pinned = pinned
    }

    // Written out so a shelf saved before `pinned` existed still loads.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        url = try values.decode(URL.self, forKey: .url)
        bookmark = try values.decodeIfPresent(Data.self, forKey: .bookmark)
        addedAt = try values.decode(Date.self, forKey: .addedAt)
        owned = try values.decodeIfPresent(Bool.self, forKey: .owned) ?? false
        pinned = try values.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }
}

public final class ShelfStore: ObservableObject {
    @Published public private(set) var items: [ShelfItem] = []

    public let directory: URL
    private let fm = FileManager.default

    /// Where the shelf writes its own files. Only files in here are ever deleted by the shelf.
    public var dropsDirectory: URL { directory.appendingPathComponent("Drops", isDirectory: true) }
    private var indexURL: URL { directory.appendingPathComponent("shelf.json") }

    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Notchshelf", isDirectory: true)
    }

    public init(directory: URL = ShelfStore.defaultDirectory) {
        self.directory = directory
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    // MARK: Mutations

    /// Parks files, newest first. Skips anything missing or already on the shelf. Returns how many were added.
    @discardableResult
    public func add(_ urls: [URL], owned: Bool = false) -> Int {
        var known = Set(items.map { Self.key($0.url) })
        var added: [ShelfItem] = []
        for url in urls where url.isFileURL {
            guard fm.fileExists(atPath: url.path), known.insert(Self.key(url)).inserted else { continue }
            added.append(ShelfItem(url: url.standardizedFileURL, bookmark: try? url.bookmarkData(), owned: owned))
        }
        guard !added.isEmpty else { return 0 }
        items.insert(contentsOf: added, at: 0)
        save()
        return added.count
    }

    public func remove(_ ids: Set<UUID>) {
        let gone = items.filter { ids.contains($0.id) }
        guard !gone.isEmpty else { return }
        items.removeAll { ids.contains($0.id) }
        gone.forEach(discard)
        save()
    }

    /// Empties the shelf, leaving pinned items unless told to take those too.
    public func clear(includingPinned: Bool = false) {
        remove(Set(items.filter { includingPinned || !$0.pinned }.map(\.id)))
    }

    public func setPinned(_ pinned: Bool, for ids: Set<UUID>) {
        var changed = false
        for index in items.indices where ids.contains(items[index].id) && items[index].pinned != pinned {
            items[index].pinned = pinned
            changed = true
        }
        if changed { save() }
    }

    /// Writes text, a link or an image into the shelf's own folder and parks the file. Nil if it could not be written.
    @discardableResult
    public func add(_ clipping: Clipping) -> ShelfItem? {
        guard let data = clipping.contents else { return nil }
        let folder = makeDropDirectory()
        let url = folder.appendingPathComponent(clipping.fileName)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            try? fm.removeItem(at: folder)
            return nil
        }
        guard add([url], owned: true) == 1 else { return nil }
        return items.first
    }

    /// Follows files that moved and drops the ones that were deleted or trashed.
    public func refresh() {
        var kept: [ShelfItem] = []
        var changed = false
        for var item in items {
            guard let current = resolve(item) else {
                changed = true
                continue
            }
            if Self.key(current) != Self.key(item.url) {
                item.url = current
                changed = true
            }
            kept.append(item)
        }
        guard changed else { return }
        items = kept
        save()
    }

    /// A fresh folder for one drop, so names from different drops cannot collide.
    public func makeDropDirectory() -> URL {
        let url = dropsDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Internals

    private static func key(_ url: URL) -> String {
        url.resolvingSymlinksInPath().path
    }

    private static func isTrashed(_ url: URL) -> Bool {
        url.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    private func resolve(_ item: ShelfItem) -> URL? {
        if let data = item.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale),
               fm.fileExists(atPath: url.path) {
                return Self.isTrashed(url) ? nil : url.standardizedFileURL
            }
        }
        return fm.fileExists(atPath: item.url.path) && !Self.isTrashed(item.url) ? item.url : nil
    }

    /// Deletes a file the shelf wrote itself. Files the user parked from elsewhere are never touched.
    private func discard(_ item: ShelfItem) {
        guard item.owned else { return }
        let drops = Self.key(dropsDirectory) + "/"
        guard Self.key(item.url).hasPrefix(drops) else { return }
        try? fm.removeItem(at: item.url)
        let parent = item.url.deletingLastPathComponent()
        if Self.key(parent) + "/" != drops, (try? fm.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
            try? fm.removeItem(at: parent)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: indexURL),
              let saved = try? JSONDecoder().decode([ShelfItem].self, from: data) else { return }
        items = saved
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
