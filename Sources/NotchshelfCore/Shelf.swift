import Combine
import Foundation

/// One file parked on the shelf. The shelf holds a reference to the file, not a copy.
public struct ShelfItem: Identifiable, Codable, Equatable {
    public let id: UUID
    public var url: URL
    /// Lets the shelf follow the file if it is renamed or moved while parked.
    public var bookmark: Data?
    public var addedAt: Date
    /// True when the file arrived as a promise (a photo, a web image) and was written into the shelf's own folder.
    public var owned: Bool

    public var name: String { url.lastPathComponent }

    public init(id: UUID = UUID(), url: URL, bookmark: Data? = nil, addedAt: Date = Date(), owned: Bool = false) {
        self.id = id
        self.url = url
        self.bookmark = bookmark
        self.addedAt = addedAt
        self.owned = owned
    }
}

public final class ShelfStore: ObservableObject {
    @Published public private(set) var items: [ShelfItem] = []

    public let directory: URL
    private let fm = FileManager.default

    /// Where promised files are written. Only files in here are ever deleted by the shelf.
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

    public func clear() {
        remove(Set(items.map(\.id)))
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

    /// A fresh folder for one drop of promised files, so names from different drops cannot collide.
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

    /// Deletes the shelf's own copy of a promised file. Files the user parked from elsewhere are never touched.
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
