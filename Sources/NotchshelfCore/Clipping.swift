import Foundation

// Things that arrive without a file behind them: selected text, a link, a copied image.
// The shelf writes each one into its own folder as a real file. What kind of file, and what it is called,
// is decided here, free of AppKit, so it can be tested.

/// Something dragged or pasted that has no file behind it.
public enum Clipping: Equatable {
    case text(String)
    case link(URL, title: String?)
    /// Image data already in the format named by `fileExtension`. `name` is where it came from, when that is known.
    case image(Data, fileExtension: String, name: String?)

    /// The name of the file the shelf writes, extension included.
    public var fileName: String {
        switch self {
        case .text(let text):
            return ClippingName.forText(text) + ".txt"
        case .link(let url, let title):
            return ClippingName.forLink(url, title: title) + ".webloc"
        case .image(_, let fileExtension, let name):
            return ClippingName.forImage(source: name) + "." + fileExtension
        }
    }

    /// The bytes of that file.
    public var contents: Data? {
        switch self {
        case .text(let text):
            return Data(text.utf8)
        case .link(let url, _):
            // A .webloc is a property list with one key. Finder, Safari and Quick Look all read it.
            return try? PropertyListSerialization.data(fromPropertyList: ["URL": url.absoluteString], format: .xml, options: 0)
        case .image(let data, _, _):
            return data
        }
    }
}

public enum ClippingName {
    /// Long enough to recognise, short enough to read under a tile or in a Finder column.
    public static let limit = 40

    /// Makes any string safe and tidy as a file name: one line, no path separators, no leading dot, not too long.
    /// May return an empty string.
    public static func clean(_ raw: String, limit: Int = ClippingName.limit) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar == "/" || scalar == ":" {
                scalars.append("-")
            } else if CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar) {
                scalars.append(" ")
            } else {
                scalars.append(scalar)
            }
        }
        let words = String(scalars).split(separator: " ", omittingEmptySubsequences: true)
        var name = words.joined(separator: " ")
        while name.hasPrefix(".") { name.removeFirst() }
        name = name.trimmingCharacters(in: .whitespaces)

        if name.count > limit {
            let cut = String(name.prefix(limit))
            // Stop at the end of a word when one ends in the second half; otherwise cut where the limit falls.
            if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) >= limit / 2 {
                name = String(cut[..<space])
            } else {
                name = cut
            }
        }
        let trailing = CharacterSet(charactersIn: " .,;-")
        while let last = name.unicodeScalars.last, trailing.contains(last) { name.unicodeScalars.removeLast() }
        return name
    }

    /// The first line that says something.
    public static func forText(_ text: String) -> String {
        for line in text.split(whereSeparator: \.isNewline) {
            guard line.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) else { continue }
            let name = clean(String(line))
            if !name.isEmpty { return name }
        }
        return "Text"
    }

    private static let pageExtensions: Set<String> = ["html", "htm", "php", "asp", "aspx"]

    /// The page title when there is one, otherwise the site and the last part of the path.
    public static func forLink(_ url: URL, title: String?) -> String {
        if let title, title != url.absoluteString, Intake.webURL(in: title) == nil {
            let name = clean(title)
            if !name.isEmpty { return name }
        }
        if var host = url.host, !host.isEmpty {
            if host.hasPrefix("www.") { host.removeFirst(4) }
            var last = url.pathComponents.last { $0 != "/" } ?? ""
            // "pricing", not "pricing.html".
            if pageExtensions.contains((last as NSString).pathExtension.lowercased()) { last = (last as NSString).deletingPathExtension }
            let name = clean(last.isEmpty ? host : host + " " + last)
            if !name.isEmpty { return name }
        }
        // mailto: and the like have no host; what follows the scheme is the useful part.
        let text = url.absoluteString
        if let colon = text.firstIndex(of: ":") {
            let name = clean(String(text[text.index(after: colon)...]))
            if !name.isEmpty { return name }
        }
        return "Link"
    }

    /// The name the image had where it came from, without its extension, or plain "Image".
    public static func forImage(source: String?) -> String {
        if let source {
            let stem = (source as NSString).deletingPathExtension
            let name = clean(stem.removingPercentEncoding ?? stem)
            if !name.isEmpty { return name }
        }
        return "Image"
    }
}

/// Which of the image formats on a pasteboard to read, and what to save it as.
public struct ImageChoice: Equatable, Sendable {
    /// The pasteboard type to read.
    public var type: String
    public var fileExtension: String
    /// True when the data has to be re-encoded as PNG before it is written.
    public var convert: Bool

    public init(type: String, fileExtension: String, convert: Bool = false) {
        self.type = type
        self.fileExtension = fileExtension
        self.convert = convert
    }

    /// Best first. Formats that are fine as files are kept as they are; TIFF, which is what most apps
    /// put on the pasteboard for a bare image, becomes a PNG.
    static let known: [ImageChoice] = [
        ImageChoice(type: "public.png", fileExtension: "png"),
        ImageChoice(type: "public.jpeg", fileExtension: "jpg"),
        ImageChoice(type: "com.compuserve.gif", fileExtension: "gif"),
        ImageChoice(type: "public.heic", fileExtension: "heic"),
        ImageChoice(type: "org.webmproject.webp", fileExtension: "webp"),
        ImageChoice(type: "public.tiff", fileExtension: "png", convert: true),
    ]

    /// Every pasteboard type the shelf can read an image from.
    public static var types: [String] { known.map(\.type) }

    public static func best(among types: [String]) -> ImageChoice? {
        known.first { types.contains($0.type) }
    }
}

/// What a drag or the clipboard has to offer, read off the pasteboard by the app.
public struct Offer: Equatable, Sendable {
    public var fileCount: Int
    public var promiseCount: Int
    /// Every type on the pasteboard.
    public var types: [String]
    /// The pasteboard's URL entry, if it has one.
    public var url: String?
    public var urlTitle: String?
    public var text: String?

    public init(fileCount: Int = 0, promiseCount: Int = 0, types: [String] = [], url: String? = nil, urlTitle: String? = nil, text: String? = nil) {
        self.fileCount = fileCount
        self.promiseCount = promiseCount
        self.types = types
        self.url = url
        self.urlTitle = urlTitle
        self.text = text
    }
}

/// What the shelf does with an offer.
public enum Intake: Equatable, Sendable {
    /// Park the files themselves.
    case files
    /// Ask the source to write its promised files.
    case promises
    /// Read the image in this format. `source` is the address it came from, when the pasteboard says.
    case image(ImageChoice, source: String?)
    case link(URL, title: String?)
    case text(String)

    /// One pasteboard often says the same thing several ways: a copied image comes with its address,
    /// a link with its own text, a spreadsheet cell with a picture of itself. This picks the one that was meant.
    ///
    /// Real files win, then promised ones. An image wins unless it comes with words of its own.
    /// A link wins over the text that spells it out. Nil means there is nothing here to shelve.
    public static func plan(for offer: Offer) -> Intake? {
        if offer.fileCount > 0 { return .files }
        if offer.promiseCount > 0 { return .promises }

        let text = offer.text ?? ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicit = offer.url.flatMap(link(from:))
        let spelled = webURL(in: trimmed)
        let textIsAddress = spelled != nil || (explicit != nil && trimmed == explicit?.absoluteString)

        if let image = ImageChoice.best(among: offer.types), trimmed.isEmpty || textIsAddress {
            return .image(image, source: (explicit ?? spelled)?.lastPathComponent)
        }
        if let explicit {
            // Some apps put the link's words in the text entry instead of a title.
            let words = !trimmed.isEmpty && !textIsAddress && !trimmed.contains(where: \.isNewline) ? trimmed : nil
            return .link(explicit, title: nonEmpty(offer.urlTitle) ?? words)
        }
        if let spelled { return .link(spelled, title: nonEmpty(offer.urlTitle)) }
        return trimmed.isEmpty ? nil : .text(text)
    }

    /// A pasteboard URL entry worth keeping as a link: anything with a scheme that is not a file.
    static func link(from string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let scheme = url.scheme, !scheme.isEmpty, !url.isFileURL else { return nil }
        return url
    }

    /// The web address a piece of text consists of, if it is nothing but one.
    public static func webURL(in text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    private static func nonEmpty(_ string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// What happens to items once they have been dragged off the shelf and dropped somewhere.
public enum DragOut {
    /// The items that leave. Pinned ones stay, and so does everything while Option is held or the setting says keep.
    public static func leaving(_ items: [ShelfItem], optionHeld: Bool, keepAll: Bool) -> Set<UUID> {
        guard !optionHeld, !keepAll else { return [] }
        return Set(items.filter { !$0.pinned }.map(\.id))
    }

    /// True when the drop must copy and never move: one of the items is the shelf's own file and is staying,
    /// so a move would take it out of the shelf's folder and leave the shelf pointing at someone else's file.
    public static func mustCopy(_ items: [ShelfItem], keepAll: Bool) -> Bool {
        items.contains { $0.owned && ($0.pinned || keepAll) }
    }
}
