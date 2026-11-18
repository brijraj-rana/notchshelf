<p align="center">
  <img src="docs/icon.png" width="128" alt="Notchshelf icon">
</p>

<h1 align="center">Notchshelf</h1>

<p align="center">
  A shelf for files that lives in the MacBook notch.<br>
  Drag something up to park it. Drag it back out wherever you need it.
</p>

<p align="center">
  <a href="https://github.com/BRIJRAJ-02/notchshelf/actions/workflows/ci.yml"><img src="https://github.com/BRIJRAJ-02/notchshelf/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-black" alt="macOS 14+">
  <img src="https://img.shields.io/badge/SwiftUI-native-black" alt="SwiftUI">
  <img src="https://img.shields.io/badge/license-MIT-black" alt="MIT">
</p>

<p align="center">
  <img src="docs/open.png" width="520" alt="The open shelf under the notch holding a folder, a text file, two images and a PDF">
</p>

## What it does

Moving a file between two apps usually means lining up two windows first. Notchshelf gives you somewhere to put the file down in between.

- **Appears when you pick something up.** Start dragging a file anywhere and a lip drops out of the notch. Carry the file to it and the shelf opens.
- **Holds references, not copies.** Parked files stay where they are on disk. Rename or move one and the shelf follows it; delete it and it leaves the shelf.
- **Takes things that are not files yet.** A photo from Photos or an image from a browser arrives as a promise; the shelf asks for the file and keeps it until you drag it out.
- **Takes things that are not files at all.** Drag selected text, a link or a copied image to the notch and the shelf writes it out as a real file, a `.txt`, a `.webloc` or a `.png`, named after what is in it. That file is the shelf's own and goes when the item does.
- **Takes the clipboard.** With the shelf open, Command-V shelves whatever you last copied: files, text, a link or an image.
- **Lets go when you are done.** Drag a file out to Finder, Mail, Slack, a browser upload field or anywhere else, and it leaves the shelf. *Drag all* takes everything at once.
- **Keeps what you still need.** Hold Option as you drop and the item stays on the shelf. *Keep on Shelf* pins it there, so every drag leaves it behind and *Clear* passes it by.
- **Hands things on.** Right-click an item to share it, with AirDrop one step away, show it in Finder or copy its path.
- **Shows you what you parked.** Press Space on a file and Quick Look opens from its tile. The arrow keys step through the rest of the shelf.
- **Works without the mouse.** Control-Option-S opens the shelf from anywhere. Arrows to choose, Return to open, Command-C to copy, Delete to take it off the shelf.
- **Stays out of the way.** An empty shelf shows nothing. A shelf with files shows a small count beside the notch.
- **Remembers.** The shelf survives a restart.

<p align="center">
  <img src="docs/clippings.png" width="520" alt="The open shelf holding a piece of text, a link, a pasted image, a PDF and an image with a small pin on its corner">
</p>

<p align="center">
  <img src="docs/drop.png" width="520" alt="The lip under the notch that appears while a file is being dragged, reading Drop to shelve">
</p>

<p align="center">
  <img src="docs/collapsed.png" width="520" alt="The count beside the notch while the shelf is holding five files">
</p>

## Install

### Download

Get `Notchshelf-x.y.z.dmg` from the [latest release](https://github.com/BRIJRAJ-02/notchshelf/releases/latest), open it and drag Notchshelf to Applications. It runs on Apple Silicon and Intel, macOS 14 or later.

The app is not notarized, so macOS blocks the first launch. Either allow it under System Settings → Privacy & Security → Open Anyway, or run:

```bash
xattr -dr com.apple.quarantine /Applications/Notchshelf.app
```

### Build from source

Requires Xcode 16 or later (for the Swift toolchain).

```bash
git clone https://github.com/BRIJRAJ-02/notchshelf.git
cd notchshelf
./scripts/build-app.sh --install   # builds, copies Notchshelf.app to /Applications, launches it
```

## Using it

| Do this | To |
|---|---|
| Drag a file to the notch | Park it |
| Drag selected text, a link or an image to the notch | Park it as a `.txt`, `.webloc` or `.png` the shelf keeps for you |
| Hover the count beside the notch | Open the shelf |
| Drag a tile out | Drop the file somewhere and take it off the shelf |
| Hold Option as you drop it | Drop the file somewhere and keep it on the shelf |
| Drag *Drag all* | Take every file at once |
| Double-click a tile | Open the file |
| Hover a tile and press Space | Look at the file in Quick Look |
| Hover a tile and click × | Take it off the shelf, leaving the file alone |
| Right-click a tile | Quick Look, Open, Show in Finder, Copy, Copy Path, Share, Keep on Shelf, Remove from Shelf |
| Click *Clear* | Take everything off the shelf except what you kept |
| Option-click *Clear* | Take everything off, kept items too |
| Click the tray icon in the menu bar | Open Shelf, Clear Shelf, Clear Kept Items Too, Change Shortcut, Turn Off Shortcut, Keep Files After Dragging Out, Launch at Login, Quit |

Dropping on Finder moves or copies exactly as dragging the file itself would: a move on the same disk, a copy across disks, Option to force a copy.

An item you chose *Keep on Shelf* for shows a small pin on its corner. Dragging it out leaves it where it is, and so does *Clear*. The × on the tile and the Delete key still take it off. Choose *Keep on Shelf* again to let it go.

Text, links and images that came without a file are written to the shelf's own folder. Selected text is named after its first line, a link after its page title or its site, and an image after the name it had on the web, or plain *Image*. Text that is nothing but a web address is kept as a link. Taking one of these off the shelf deletes the shelf's file, so drag it out first if you want to keep it. One that is kept on the shelf is copied when you drag it to Finder, never moved.

On a display without a notch (an external monitor, or the lid closed) the shelf hangs from the bottom of the menu bar instead.

### From the keyboard

<p align="center">
  <img src="docs/selected.png" width="520" alt="The open shelf with the second of five files selected">
</p>

| Press | To |
|---|---|
| Control-Option-S | Open the shelf with the first file selected, or close it |
| Left and Right | Move the selection. A press at either end wraps around; a held key stops there |
| Space | Open Quick Look for the selected file, and close it again |
| Left and Right in Quick Look | Look at the previous or next file on the shelf |
| Return | Open the file |
| Command-C | Copy the file, ready to paste into Finder, Mail or a chat |
| Command-V | Shelve what is on the clipboard: files, text, a link or an image |
| Delete | Take it off the shelf, leaving the file alone |
| Esc | Close Quick Look, or the shelf |

The same keys work on a shelf you opened with the pointer. They act on the tile under it, and the first arrow key starts a selection from there.

A shelf opened from the keyboard stays open until you press Esc or the shortcut again, open a file, or click somewhere else.

To use a different shortcut, choose *Change Shortcut* from the menu bar icon and press the new one. It needs Control or Command in it, or a function key alone. Esc keeps the one you had. *Turn Off Shortcut* removes it.

<p align="center">
  <img src="docs/shortcut.png" width="520" alt="The panel under the notch waiting for a new shortcut, showing Control Option S and the words Press the new shortcut">
</p>

The default is Control-Option-S because macOS keeps Control-Option-Space for switching keyboard layouts.

While the shelf is open and the pointer is on it, or while it was opened from the keyboard, your key presses go to the shelf and not to the app behind it. That app stays in front the whole time. Quick Look is the one exception: its window needs Notchshelf in front, so the app you were in comes back when the shelf lets go.

### With Notchload

[Notchload](https://github.com/BRIJRAJ-02/notchload) uses the strip under the notch, so the two share it. With Notchload running, the notch itself still opens Notchload and the count beside it opens the shelf. While the shelf is open or a file is in the air, Notchshelf tells Notchload to stay closed.

## Design notes

- **The notch is the anchor.** Everything is one black path that grows out of the hardware: an ear for the count, a lip for the drop target, a body for the shelf.
- **Nothing until there is something.** No idle chrome. The shelf only draws when it holds files or when a file is in the air.
- **A target you can see.** The lip appears as soon as a drag starts, so there is no guessing where to aim.
- **Patient with the pointer, not with a drag.** Hover waits a beat before opening. A file being carried opens it at once.
- **Click-through.** The window ignores the mouse everywhere outside the visible shape.
- **Careful with your files.** The shelf never deletes or moves a file you parked. The only files it removes are the ones it wrote itself: promised drops, and the text, links and images it turned into files.
- **Keys land at once.** A key press never waits for an animation. The shelf opens, closes and loses a file immediately; only the selection glides, briefly, so you can see where it went.
- **Respectful motion.** One spring, and a plain fade with Reduce Motion.

## How it is built

```
Sources/
  NotchshelfCore/   UI-free shelf: the list, bookmarks, pins, persistence, cleanup of its own files,
                    what a drag or the clipboard turns into and what that file is called,
                    and the keyboard rules: where the selection goes, how a shortcut is stored, which key does what
  Notchshelf/       the panel: window placement, drag detection, drop and drag-out, keys and Quick Look, SwiftUI views
Tests/              the shelf store: duplicates, persistence, moved and deleted files, what may be deleted;
                    names and types for text, links and images, pins, shelves saved by older versions;
                    selection movement, shortcut encoding, the key table
scripts/            build-app.sh bundles the app and the DMG; make-icon.swift draws the icon in code
```

How the parts work:

| Part | How |
|---|---|
| Noticing a drag | A global mouse monitor watches the drag pasteboard's change count; only its types are read, never its contents |
| Receiving drops | An AppKit drag destination under the SwiftUI views, for file URLs, `NSFilePromiseReceiver`, text, URLs and image data |
| Text, links, images | Written into `Drops` in the storage folder as `.txt`, `.webloc` and `.png` (a PNG, JPEG or GIF is kept as it came) |
| Pasting | The same code as a drop, reading the general pasteboard |
| Dragging out | An `NSDraggingSession`, so the shelf learns whether the drop landed |
| Sharing | `NSSharingServicePicker`, shown from the tile |
| Following files | URL bookmarks, resolved each time the shelf opens |
| Thumbnails | `QLThumbnailGenerator` |
| The global shortcut | Carbon's `RegisterEventHotKey`, which needs no accessibility permission |
| Keys on the shelf | An invisible non-activating panel takes keyboard focus while the shelf can use it and is ordered out to give it back; the visible panel never becomes key |
| Quick Look | `QLPreviewPanel`, zooming from the tile's thumbnail and back |
| Storage | `~/Library/Application Support/Notchshelf` |

Nothing leaves your Mac. macOS may ask once for access to Desktop, Documents or Downloads when the shelf checks on files parked from there.

### Developing

```bash
swift build && swift test       # or open Package.swift in Xcode
./scripts/build-app.sh --open   # build and launch the app bundle
./scripts/build-app.sh --dmg    # universal build, packaged as build/Notchshelf-<version>.dmg
.build/debug/Notchshelf --snapshot docs               # re-render the README screenshots with sample files
.build/debug/Notchshelf --store /tmp/shelf --add a.png b.pdf   # run against a throwaway shelf
```

## License

[MIT](LICENSE)
