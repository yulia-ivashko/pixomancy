import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ViewerModel: ObservableObject {
    @Published private(set) var currentURL: URL?
    @Published private(set) var image: CGImage?
    @Published private(set) var loadFailed = false

    let zoom = ZoomController()
    weak var window: NSWindow?

    // The folders being browsed, each with its photos in Finder order; the thumbnail sidebar shows them as groups.
    @Published private(set) var groups: [FolderGroup] = []
    // Every photo of every folder, in the order arrows go through them.
    private(set) var files: [URL] = []
    // Where the shown photo sat in files, to carry on from there if it disappears.
    private var lastIndex = 0
    // The info panel floats with a gap before its card; the photo and its controls reach into that gap,
    // so they sit as far from the info panel as from the thumbnails one.
    @Published var infoPanelOpen = false
    // Width taken by open side panels, so a new photo shapes only the part of the window it is shown in.
    var sidePanelsWidth: () -> CGFloat = { 0 }
    var narrowestWindow: () -> CGFloat = { 0 }
    // Bumped when a photo changes on disk, so thumbnails redraw.
    @Published private(set) var revision = 0
    private var cache: [URL: CGImage] = [:]
    private var loadTask: Task<Void, Never>?
    private var slideshow: SlideshowController?
    private var shapesWindowOnLoad = false
    // One watcher per open folder, so files added or removed in Finder show up by themselves.
    private var watchers: [URL: DispatchSourceFileSystemObject] = [:]
    // The shown photo's own watcher: a program writing into the file in place leaves its folder untouched.
    private var photoWatcher: DispatchSourceFileSystemObject?
    // When each photo was last changed, to tell which ones another program has saved over.
    private var stamps: [URL: Date] = [:]
    private var rescanPending = false

    // MARK: Opening and stepping

    // A photo or a folder replaces whatever was open; a folder starts at its first photo.
    func open(_ url: URL) {
        place(url, adding: false)
    }

    // Adds a folder (or a photo's folder) next to the ones already open.
    func add(_ url: URL) {
        place(url, adding: true)
    }

    private func place(_ url: URL, adding: Bool) {
        let url = url.standardizedFileURL
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let folder = isFolder ? url : url.deletingLastPathComponent()
        // An empty folder still joins the panel: photos put there later appear by themselves.
        let target = isFolder ? Self.photos(in: folder).first : url
        var folders = adding ? groups.map(\.folder) : []
        if !folders.contains(folder) { folders.append(folder) }
        setFolders(folders)
        guard let target else {
            if !adding { clear() }
            return
        }
        if adding, currentURL != nil, isFolder { return }
        if !adding || currentURL == nil { shapesWindowOnLoad = true }
        show(target)
    }

    // The title's popover with name, tags and folder; the context menu's Rename… opens it too.
    @Published var showsFilePopover = false

    // Renames the shown photo in place, like Finder. A name typed without an extension keeps the old one.
    func rename(to typed: String) {
        guard let url = currentURL else { return }
        var name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != url.lastPathComponent else { return }
        guard !name.contains("/"), !name.hasPrefix(".") else {
            showError(L("A name can’t contain “/” or start with a dot."))
            return
        }
        if (name as NSString).pathExtension.isEmpty, !url.pathExtension.isEmpty { name += "." + url.pathExtension }
        let target = url.deletingLastPathComponent().appending(path: name).standardizedFileURL
        // Only a case change may land on the same file on a case-insensitive disk.
        if FileManager.default.fileExists(atPath: target.path), target.path.lowercased() != url.path.lowercased() {
            showError(String(format: L("The name “%@” is already taken."), name))
            return
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            showError(String(format: L("Couldn’t rename “%@”"), url.lastPathComponent))
            return
        }
        cache[target] = cache.removeValue(forKey: url)
        stamps[target] = stamps.removeValue(forKey: url)
        ThumbnailCache.forget(url)
        rescan()
        show(target)
    }

    // Writes Finder tags; the info panel reads them again.
    func setTags(_ tags: [String]) {
        guard let url = currentURL else { return }
        do {
            try (url as NSURL).setResourceValue(tags, forKey: .tagNamesKey)
            revision += 1
        } catch {
            showError(String(format: L("Couldn’t change the tags of “%@”"), url.lastPathComponent))
        }
    }

    // Moves the shown photo to another folder and follows it there; Back returns to where it was.
    func move(to folder: URL) {
        guard let url = currentURL, folder.standardizedFileURL != url.deletingLastPathComponent().standardizedFileURL else { return }
        let target = folder.appending(path: url.lastPathComponent).standardizedFileURL
        if FileManager.default.fileExists(atPath: target.path) {
            showError(String(format: L("“%@” already has a file named “%@”."), folder.lastPathComponent, url.lastPathComponent))
            return
        }
        do {
            try FileManager.default.moveItem(at: url, to: target)
        } catch {
            showError(String(format: L("Couldn’t move “%@”"), url.lastPathComponent))
            return
        }
        cache[target] = cache.removeValue(forKey: url)
        ThumbnailCache.forget(url)
        jump(to: target)
    }

    // Takes a folder out of the sidebar; the first one opened can go too.
    func remove(_ folder: URL) {
        let index = currentURL.flatMap(indexOf) ?? lastIndex
        setFolders(groups.map(\.folder).filter { $0 != folder })
        if let current = currentURL, indexOf(current) != nil { return }
        if files.isEmpty { clear() } else { show(files[min(index, files.count - 1)]) }
    }

    // MARK: Back and forward

    // What the window showed: its folders and photo. A click on the title's path leaves one behind, like Finder.
    struct Place: Equatable {
        let folders: [URL]
        let photo: URL?

        // The folder Finder would name in its back menu.
        var folder: URL? { photo?.deletingLastPathComponent() ?? folders.first }
    }

    @Published private(set) var backList: [Place] = []
    @Published private(set) var forwardList: [Place] = []
    // Back and forward appear with the first jump along the path and stay for the window's life.
    @Published private(set) var hasJumped = false

    private var here: Place { Place(folders: groups.map(\.folder), photo: currentURL) }

    // Opens a folder from the title's path in place of the open ones.
    // A folder, or a photo shown in its folder.
    func jump(to folder: URL) {
        backList.append(here)
        forwardList = []
        hasJumped = true
        open(folder)
    }

    // steps > 1 comes from the back and forward menus, which skip straight to an older place.
    func goBack(_ steps: Int = 1) {
        guard steps >= 1, steps <= backList.count else { return }
        forwardList.append(here)
        for _ in 1..<steps { forwardList.append(backList.removeLast()) }
        visit(backList.removeLast())
    }

    func goForward(_ steps: Int = 1) {
        guard steps >= 1, steps <= forwardList.count else { return }
        backList.append(here)
        for _ in 1..<steps { backList.append(forwardList.removeLast()) }
        visit(forwardList.removeLast())
    }

    private func visit(_ place: Place) {
        setFolders(place.folders.filter { FileManager.default.fileExists(atPath: $0.path) })
        guard let target = place.photo.flatMap({ p in files.first { $0.path == p.path } }) ?? files.first else {
            clear()
            return
        }
        shapesWindowOnLoad = true
        show(target)
    }

    // Brings back the folders and photo of the last session.
    func restore(folders: [URL], photo: URL?) {
        setFolders(folders.filter { FileManager.default.fileExists(atPath: $0.path) })
        // The window keeps the size and screen it was left with; only a newly opened photo reshapes it.
        guard let first = files.first else { saveSession(); return }
        show(photo.flatMap { p in files.first { $0.path == p.path } } ?? first)
    }

    func step(_ delta: Int) {
        guard let current = currentURL else { return }
        rescan()
        guard !files.isEmpty else { return }
        let count = files.count
        let target: Int
        if let index = indexOf(current) {
            target = ((index + delta) % count + count) % count
        } else {
            // The current file is gone; continue from where it used to be.
            let next = min(lastIndex, count)
            target = delta > 0 ? next % count : (next - 1 + count) % count
        }
        show(files[target])
    }

    func select(_ url: URL) {
        guard url != currentURL else { return }
        show(url)
    }

    func showFirst() {
        guard currentURL != nil else { return }
        rescan()
        if let first = files.first { show(first) }
    }

    func showLast() {
        guard currentURL != nil else { return }
        rescan()
        if let last = files.last { show(last) }
    }

    private func clear() {
        photoWatcher?.cancel()
        photoWatcher = nil
        loadTask?.cancel()
        currentURL = nil
        image = nil
        window?.title = "Pixomancy"
        window?.representedURL = nil
        saveSession()
    }

    private func show(_ url: URL) {
        if url != currentURL { watchPhoto(url) }
        // Written over in place while not shown, it left no trace in the folder; a stale copy may wait in the cache.
        if let old = stamps[url], let now = Self.stamp(url), old != now {
            stamps[url] = now
            cache[url] = nil
            ThumbnailCache.forget(url)
            revision += 1
        }
        currentURL = url
        if let index = indexOf(url) { lastIndex = index }
        saveSession()
        window?.title = url.lastPathComponent
        window?.representedURL = url
        loadTask?.cancel()
        if let cached = cache[url] {
            image = cached
            loadFailed = false
            shapeWindow(to: cached)
            prefetchNeighbors()
            return
        }
        loadTask = Task {
            let decoded = await ImageLoader.load(url)
            guard !Task.isCancelled, currentURL == url else { return }
            image = decoded
            loadFailed = decoded == nil
            if let decoded {
                cache[url] = decoded
                shapeWindow(to: decoded)
            }
            prefetchNeighbors()
        }
    }

    // Like Preview: a newly opened photo gives the window its proportions, so there is no empty frame around it.
    // Stepping keeps the size, so the window doesn't jump under the pointer.
    private func shapeWindow(to image: CGImage) {
        guard shapesWindowOnLoad else { return }
        shapesWindowOnLoad = false
        resizeWindow(to: image, wholeScreen: false)
    }

    // The window grows or shrinks so the photo is as big as the screen allows, never past its real size.
    // The window grows to the biggest size the screen allows at the photo's proportions, and the photo fills it,
    // small photos enlarged too. Actual Size is the other button: one photo pixel per screen pixel.
    func fitWindowToScreen() {
        guard let image else { return }
        resizeWindow(to: image, wholeScreen: true)
        zoom.fill()
    }

    private func resizeWindow(to image: CGImage, wholeScreen: Bool) {
        // Before the window is on screen window.screen is nil; take the screen its saved frame lies on, not the main one.
        guard let window, !window.styleMask.contains(.fullScreen),
              let screen = window.screen
                ?? NSScreen.screens.max(by: { $0.frame.intersection(window.frame).area < $1.frame.intersection(window.frame).area })
                ?? NSScreen.main else { return }
        let scale = screen.backingScaleFactor
        let photo = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        let margin = ImageScrollView.sideMargin
        let chrome = window.frame.height - window.contentLayoutRect.height + ViewerView.barSpace + margin
        let sides = sidePanelsWidth() + 2 * margin
        let visible = screen.visibleFrame
        let room = wholeScreen ? visible.width : window.frame.width
        // A new photo is never blown up past its real size; the screen fit may enlarge it.
        let fit = min(wholeScreen ? .infinity : 1, (room - sides) / photo.width, (visible.height - chrome) / photo.height)
        var width = max(photo.width * fit + sides, window.minSize.width, narrowestWindow())
        var height = max(photo.height * fit + chrome, window.minSize.height)
        if wholeScreen {
            // Only ever grows: a window already as big as the screen keeps its size, and the photo fills it.
            width = min(max(width, window.frame.width), visible.width)
            height = min(max(height, window.frame.height), visible.height)
        }
        // The top-left corner stays put, as when you drag a window bigger; it moves only to stay on screen.
        var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - height, width: width, height: height)
        frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - width)
        frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - height)
        window.setFrame(frame, display: true, animate: window.isVisible)
    }

    private func prefetchNeighbors() {
        guard let current = currentURL, let index = indexOf(current), !files.isEmpty else { return }
        let count = files.count
        let keep = Set([current, files[(index + 1) % count], files[(index - 1 + count) % count]])
        cache = cache.filter { keep.contains($0.key) }
        for url in keep where cache[url] == nil {
            Task {
                guard let decoded = await ImageLoader.load(url) else { return }
                if self.isNeighbor(url) { self.cache[url] = decoded }
            }
        }
    }

    private func isNeighbor(_ url: URL) -> Bool {
        guard let current = currentURL, let index = indexOf(current), !files.isEmpty else { return false }
        let count = files.count
        return [current, files[(index + 1) % count], files[(index - 1 + count) % count]].contains(url)
    }

    private func setFolders(_ folders: [URL]) {
        let fresh = folders.map { FolderGroup(folder: $0, files: Self.photos(in: $0)) }
        if fresh != groups { groups = fresh }
        files = groups.flatMap(\.files)
        watch(folders)
    }

    private func watch(_ folders: [URL]) {
        for (folder, source) in watchers where !folders.contains(folder) {
            source.cancel()
            watchers[folder] = nil
            stamps = stamps.filter { $0.key.deletingLastPathComponent() != folder }
        }
        for folder in folders where watchers[folder] == nil {
            for file in groups.first(where: { $0.folder == folder })?.files ?? [] { stamps[file] = Self.stamp(file) }
            let fd = Darwin.open(folder.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in self?.folderChanged() }
            source.setCancelHandler { close(fd) }
            source.resume()
            watchers[folder] = source
        }
    }

    private func watchPhoto(_ url: URL) {
        photoWatcher?.cancel()
        photoWatcher = nil
        let fd = Darwin.open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in self?.folderChanged() }
        source.setCancelHandler { close(fd) }
        source.resume()
        photoWatcher = source
    }

    private static func stamp(_ url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    // Photos another program saved over since we last looked: shown again, and their thumbnails redrawn.
    private func reloadChanged() {
        var fresh: [URL: Date] = [:]
        for file in files { fresh[file] = Self.stamp(file) }
        let changed = fresh.filter { file, date in stamps[file].map { $0 != date } ?? false }.map(\.key)
        stamps = fresh
        for url in changed { reloadIfShowing(url) }
        // A save that replaces the file leaves the watcher on the old one.
        if let current = currentURL, changed.contains(current) { watchPhoto(current) }
    }

    // A burst of changes (a copy, a screenshot being written, a program saving) settles into one rescan.
    private func folderChanged() {
        guard !rescanPending else { return }
        rescanPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self else { return }
            rescanPending = false
            rescan()
            reloadChanged()
            if let current = currentURL {
                guard indexOf(current) == nil else { return }
                // The shown photo was deleted or moved away in Finder.
                if files.isEmpty { clear() } else { show(files[min(lastIndex, files.count - 1)]) }
            } else if let first = files.first {
                // The first photo has arrived in a folder that was empty.
                shapesWindowOnLoad = true
                show(first)
            }
        }
    }

    // Folders change on disk behind our back; look again before stepping.
    private func rescan() {
        setFolders(groups.map(\.folder))
    }

    private static func photos(in folder: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .filter { isReadableImage($0) }
            .map(\.standardizedFileURL)
            .sorted { precedes($0, $1) }
    }

    // MARK: Last session

    static let sessionFoldersKey = "SessionFolders", sessionPhotoKey = "SessionPhoto"

    private func saveSession() {
        let defaults = UserDefaults.standard
        defaults.set(groups.map(\.folder.path), forKey: Self.sessionFoldersKey)
        defaults.set(currentURL?.path, forKey: Self.sessionPhotoKey)
    }

    private func indexOf(_ url: URL) -> Int? {
        files.firstIndex { $0.path == url.path }
    }

    private static let readableTypes = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])

    private static func isReadableImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return readableTypes.contains(type.identifier)
    }

    // Finder's order: "photo 2" before "photo 10".
    private static func precedes(_ a: URL, _ b: URL) -> Bool {
        a.lastPathComponent.localizedStandardCompare(b.lastPathComponent) == .orderedAscending
    }

    // MARK: Actions

    func rotate(clockwise: Bool) {
        guard let url = currentURL, image != nil else { return }
        Task {
            let saved = await Task.detached(priority: .userInitiated) {
                (try? ImageRotator.rotate(url, clockwise: clockwise)) != nil
            }.value
            guard saved else {
                showError(L("Couldn’t rotate the photo"))
                return
            }
            reloadIfShowing(url)
        }
    }

    func confirmTrash() {
        guard let url = currentURL, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = String(format: L("Move “%@” to the Trash?"), url.lastPathComponent)
        alert.addButton(withTitle: L("Move to Trash"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { self.trash(url) }
        }
    }

    private func trash(_ url: URL) {
        rescan()
        let index = indexOf(url) ?? 0
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            showError(L("Couldn’t move the photo to the Trash"))
            return
        }
        cache[url] = nil
        rescan()
        if files.isEmpty {
            clear()
        } else {
            show(files[min(index, files.count - 1)])
        }
    }

    func startSlideshow() {
        guard currentURL != nil, slideshow == nil else { return }
        let show = SlideshowController(model: self)
        show.onEnd = { [weak self] in self?.slideshow = nil }
        slideshow = show
        show.start()
    }

    func showInFinder() {
        guard let url = currentURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(with app: URL) {
        guard let url = currentURL else { return }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }

    func setAsWallpaper() {
        guard let url = currentURL else { return }
        do {
            for screen in NSScreen.screens {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
            }
        } catch {
            showError(L("Couldn’t set the wallpaper"))
        }
    }

    // The file changed on disk; drop the cached copy and show it again.
    func reloadIfShowing(_ url: URL) {
        // Our own rotation is not news when the folder reports it a moment later.
        stamps[url] = Self.stamp(url)
        cache[url] = nil
        ThumbnailCache.forget(url)
        revision += 1
        if currentURL == url { show(url) }
    }

    func copyPath() {
        guard let url = currentURL else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
    }

    func copyToPasteboard() {
        guard let url = currentURL, let image else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL, NSImage(cgImage: image, size: .zero)])
    }

    func printPhoto() {
        guard let image, let window else { return }
        let info = NSPrintInfo.shared
        let view = NSImageView(frame: NSRect(origin: .zero, size: info.imageablePageBounds.size))
        view.image = NSImage(cgImage: image, size: .zero)
        view.imageScaling = .scaleProportionallyDown
        NSPrintOperation(view: view, printInfo: info).runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    private func showError(_ text: String) {
        let alert = NSAlert()
        alert.messageText = text
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

enum ImageLoader {
    static func load(_ url: URL) async -> CGImage? {
        await Task.detached(priority: .userInitiated) { decode(url) }.value
    }

    // Full-size decode with the camera's orientation applied.
    nonisolated static func decode(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(width, height, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

struct FolderGroup: Equatable, Identifiable {
    let folder: URL
    let files: [URL]
    var id: URL { folder }
}

private extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}
