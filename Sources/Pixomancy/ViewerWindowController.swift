import AppKit
import Combine
import SwiftUI

@MainActor
final class ViewerWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation, NSToolbarDelegate, NSToolbarItemValidation {
    let model = ViewerModel()
    var onClose: (() -> Void)?
    private lazy var info = InfoModel(viewer: model)
    private var split: ViewerSplitController!

    init(url: URL?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.title = "Pixomancy"
        window.minSize = NSSize(width: 520, height: 380)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        super.init(window: window)

        window.delegate = self
        split = ViewerSplitController(model: model, info: info)
        // One solid background under the whole window: the photo's reaches under the left panel by itself, not
        // under the right one, and the window's plain white showed round it.
        let backdrop = SolidBackground()
        let container = NSViewController()
        container.view = backdrop
        container.addChild(split)
        split.view.frame = backdrop.bounds
        split.view.autoresizingMask = [.width, .height]
        backdrop.addSubview(split.view)
        window.contentViewController = container
        let toolbar = NSToolbar(identifier: "PixomancyViewer")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        // No "Icon and Text" menu on right-click: it relabels the buttons and changes nothing useful.
        toolbar.allowsDisplayModeCustomization = false
        window.toolbar = toolbar
        window.titleVisibility = .hidden
        window.toolbarStyle = .unified
        model.window = window
        model.sidePanelsWidth = { [weak self] in self?.split.openPanelsWidth ?? 0 }
        model.narrowestWindow = { [weak self] in self?.split.narrowestWindow ?? 0 }
        if !window.setFrameUsingName("PixomancyViewer") { window.center() }
        window.setFrameAutosaveName("PixomancyViewer")
        if let url { model.open(url) }
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    // Plain keys: arrows, Home, End, Backspace and Esc; menu shortcuts handle the rest.
    func handleKey(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        // While a name is being typed, Backspace, arrows and Esc belong to the text.
        guard modifiers.isEmpty, !isEditingText else { return false }
        if event.keyCode == 53, let window {
            // Esc leaves full screen first, then closes the window.
            if window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            } else {
                window.performClose(nil)
            }
            return true
        }
        guard model.currentURL != nil else { return false }
        switch event.keyCode {
        case 123: model.step(-1)
        case 124: model.step(1)
        case 115: model.showFirst()
        case 119: model.showLast()
        case 51, 117: model.confirmTrash()
        default: return false
        }
        return true
    }

    // A text field has the keyboard, here or in the title's popover, which is a window of its own.
    private var isEditingText: Bool { NSApp.keyWindow?.firstResponder is NSText }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // ⌘⌫ and the bare arrows are these items' shortcuts; while typing a name they must reach the text.
        let typingKeys = [#selector(showNext(_:)), #selector(showPrevious(_:)), #selector(moveToTrash(_:)),
                          #selector(rotateLeft(_:)), #selector(rotateRight(_:))]
        if isEditingText, let action = item.action, typingKeys.contains(action) { return false }
        switch item.action {
        case #selector(setThumbnailStyle(_:)):
            let current = ThumbnailStyle(rawValue: UserDefaults.standard.string(forKey: ThumbnailStyle.key) ?? "") ?? .imagesAndNames
            item.state = ThumbnailStyle.allCases.firstIndex(of: current) == item.tag ? .on : .off
            return true
        case #selector(openWith(_:)):
            return true
        case #selector(showNext(_:)), #selector(showPrevious(_:)), #selector(showInFinder(_:)), #selector(moveToTrash(_:)),
             #selector(showInfo(_:)), #selector(copyPath(_:)), #selector(openInPreview(_:)), #selector(renamePhoto(_:)):
            return model.currentURL != nil
        default:
            return model.image != nil
        }
    }

    @objc func showNext(_ sender: Any?) { model.step(1) }
    @objc func showPrevious(_ sender: Any?) { model.step(-1) }
    @objc func rotateLeft(_ sender: Any?) { model.rotate(clockwise: false) }
    @objc func rotateRight(_ sender: Any?) { model.rotate(clockwise: true) }
    @objc func moveToTrash(_ sender: Any?) { model.confirmTrash() }
    @objc func startSlideshow(_ sender: Any?) { model.startSlideshow() }
    @objc func zoomIn(_ sender: Any?) { model.zoom.zoom(by: 1.25) }
    @objc func zoomOut(_ sender: Any?) { model.zoom.zoom(by: 0.8) }
    @objc func actualSize(_ sender: Any?) { model.zoom.actualSize() }
    @objc func fitToWindow(_ sender: Any?) { model.zoom.fit() }
    @objc func fitToScreen(_ sender: Any?) { model.fitWindowToScreen() }
    @objc func showInFinder(_ sender: Any?) { model.showInFinder() }
    @objc func copy(_ sender: Any?) { model.copyToPasteboard() }
    @objc func printPhoto(_ sender: Any?) { model.printPhoto() }
    @objc func setAsWallpaper(_ sender: Any?) { model.setAsWallpaper() }
    // For what Pixomancy leaves to Preview: signing, marking up, small edits.
    @objc func openInPreview(_ sender: Any?) {
        if let preview = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Preview") { model.open(with: preview) }
    }
    @objc func openWith(_ sender: NSMenuItem) {
        if let app = sender.representedObject as? URL { model.open(with: app) }
    }

    func contextMenu() -> NSMenu? {
        guard let url = model.currentURL else { return nil }
        let openWith = NSMenuItem("Open With", nil, symbol: "arrow.up.forward.app")
        let apps = NSMenu()
        let defaultApp = NSWorkspace.shared.urlForApplication(toOpen: url)
        for app in NSWorkspace.shared.urlsForApplications(toOpen: url) where app != Bundle.main.bundleURL {
            var name = FileManager.default.displayName(atPath: app.path)
            if name.hasSuffix(".app") { name.removeLast(4) }
            if app == defaultApp { name += " " + L("(default)") }
            let item = NSMenuItem(title: name, action: #selector(openWith(_:)), keyEquivalent: "")
            item.representedObject = app
            let icon = NSWorkspace.shared.icon(forFile: app.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            apps.addItem(item)
        }
        openWith.submenu = apps

        let menu = NSMenu()
        let items: [NSMenuItem] = [
            openWith,
            NSMenuItem("Open in Preview", #selector(openInPreview(_:)), symbol: "pencil.tip.crop.circle", modifiers: []),
            NSMenuItem("Show in Finder", #selector(showInFinder(_:)), symbol: "finder", modifiers: []),
            NSMenuItem("Get Info", #selector(showInfo(_:)), symbol: "info.circle", modifiers: []),
            NSMenuItem("Rename…", #selector(renamePhoto(_:)), symbol: "pencil", modifiers: []),
            .separator(),
            NSMenuItem("Copy", #selector(copy(_:)), symbol: "doc.on.doc", modifiers: []),
            NSMenuItem("Copy Path", #selector(copyPath(_:)), symbol: "document.on.clipboard", modifiers: []).alternate(),
            NSMenuItem("Rotate Left", #selector(rotateLeft(_:)), symbol: "rotate.left", modifiers: []),
            NSMenuItem("Rotate Right", #selector(rotateRight(_:)), symbol: "rotate.right", modifiers: []),
            .separator(),
            NSMenuItem("Set as Wallpaper", #selector(setAsWallpaper(_:)), symbol: "photo.on.rectangle", modifiers: []),
            NSMenuItem("Print…", #selector(printPhoto(_:)), symbol: "printer", modifiers: []),
            .separator(),
            NSMenuItem("Move to Trash", #selector(moveToTrash(_:)), symbol: "trash", modifiers: []),
        ]
        for item in items {
            if item.action != nil { item.target = self }
            menu.addItem(item)
        }
        return menu
    }

    // MARK: Side panels

    @objc func setThumbnailStyle(_ sender: NSMenuItem) {
        guard ThumbnailStyle.allCases.indices.contains(sender.tag) else { return }
        UserDefaults.standard.set(ThumbnailStyle.allCases[sender.tag].rawValue, forKey: ThumbnailStyle.key)
    }

    @objc func showInfo(_ sender: Any?) {
        split.toggleInfo()
    }

    private static let infoItem = NSToolbarItem.Identifier("info")

    // The left panel's button mirrored, with an "i" where its three lines are: it opens the info panel on the right.
    // Mirroring the left symbol (not using sidebar.right) keeps both frames identical; the cleared box is measured
    // around the lines, clear of the frame and the divider.
    private static let infoSidebarImage: NSImage = {
        // Toolbar buttons draw symbols at the large scale; a plain image has to be made at it.
        let left = NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium, scale: .large))!
        let image = NSImage(size: left.size, flipped: false) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return true }
            ctx.saveGState()
            ctx.translateBy(x: r.width, y: 0)
            ctx.scaleBy(x: -1, y: 1)
            left.draw(in: r)
            ctx.restoreGState()
            ctx.setBlendMode(.clear)
            ctx.fill(CGRect(x: r.width * 0.68, y: r.height * 0.41, width: r.width * 0.16, height: r.height * 0.35))
            ctx.setBlendMode(.normal)
            NSColor.black.set()
            // Centred on the frame's middle; the system's three lines sit higher, which looked off for an "i".
            let mid = r.width * 0.757, line = r.height * 0.078, dot = r.height * 0.095
            NSBezierPath(ovalIn: CGRect(x: mid - dot / 2, y: r.height * 0.675 - dot / 2, width: dot, height: dot)).fill()
            let stem = NSBezierPath()
            stem.move(to: CGPoint(x: mid, y: r.height * 0.32))
            stem.line(to: CGPoint(x: mid, y: r.height * 0.56))
            stem.lineWidth = line
            stem.lineCapStyle = .round
            stem.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = L("Get Info")
        return image
    }()
    private static let titleItem = NSToolbarItem.Identifier("title")

    private static let historyItem = NSToolbarItem.Identifier("history")
    private var titleHost: NSHostingController<TitleView>?
    private weak var titleItemRef: NSToolbarItem?
    private var titleWatch: AnyCancellable?
    // Measured on a fresh copy: the shown one may not have redrawn the new name yet and gave the old width.
    private var idealTitleWidth: CGFloat {
        ceil(NSHostingController(rootView: TitleView(model: model)).sizeThatFits(in: CGSize(width: CGFloat.infinity, height: 30)).width)
    }
    private var historyItem: NSToolbarItem?
    private var historyControl: HistoryControl?
    private var historyWatch: AnyCancellable?

    private func updateHistory(back: [ViewerModel.Place], forward: [ViewerModel.Place], shown: Bool) {
        historyItem?.isHidden = !shown
        guard let control = historyControl else { return }
        control.setEnabled(!back.isEmpty, forSegment: 0)
        control.setEnabled(!forward.isEmpty, forSegment: 1)
        control.setMenu(historyMenu(back, action: #selector(goBackTo(_:))), forSegment: 0)
        control.setMenu(historyMenu(forward, action: #selector(goForwardTo(_:))), forSegment: 1)
    }

    // Nearest place first, as in Finder; the tag is how many steps away it is.
    private func historyMenu(_ places: [ViewerModel.Place], action: Selector) -> NSMenu? {
        guard !places.isEmpty else { return nil }
        let menu = NSMenu()
        for (steps, place) in places.reversed().enumerated() {
            guard let folder = place.folder else { continue }
            let item = NSMenuItem(title: FileManager.default.displayName(atPath: folder.path), action: action, keyEquivalent: "")
            item.tag = steps + 1
            item.target = self
            let icon = NSWorkspace.shared.icon(forFile: folder.path)
            icon.size = NSSize(width: 16, height: 16)
            item.image = icon
            menu.addItem(item)
        }
        return menu
    }

    @objc private func historyClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 { model.goBack() } else { model.goForward() }
    }

    @objc private func goBackTo(_ sender: NSMenuItem) { model.goBack(sender.tag) }
    @objc private func goForwardTo(_ sender: NSMenuItem) { model.goForward(sender.tag) }
    private static let thumbnailsItem = NSToolbarItem.Identifier("thumbnails")
    private var sidebarButton: NSButton?
    private var infoButton: NSButton?
    private var infoWatch: AnyCancellable?
    private var watch: AnyCancellable?

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.thumbnailsItem, .sidebarTrackingSeparator, Self.historyItem, Self.titleItem, .flexibleSpace, Self.infoItem]
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        item.itemIdentifier != Self.infoItem || model.currentURL != nil
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        if id == Self.thumbnailsItem {
            // Right-click on it picks what the panel shows, the same choice as in the View menu.
            let button = NSButton(image: NSImage(systemSymbolName: "sidebar.left", accessibilityDescription: L("Show Sidebar"))!,
                                  target: split, action: #selector(NSSplitViewController.toggleSidebar(_:)))
            button.bezelStyle = .toolbar
            button.toolTip = L("Show Sidebar")
            let menu = NSMenu()
            for (i, style) in ThumbnailStyle.allCases.enumerated() {
                let entry = NSMenuItem(title: style.title, action: #selector(setThumbnailStyle(_:)), keyEquivalent: "")
                entry.tag = i
                entry.target = self
                menu.addItem(entry)
            }
            button.menu = menu
            button.isEnabled = !model.groups.isEmpty
            sidebarButton = button
            watch = model.$groups.sink { [weak self] groups in self?.sidebarButton?.isEnabled = !groups.isEmpty }
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = button
            item.label = L("Show Sidebar")
            return item
        }
        if id == Self.historyItem {
            // Finder's pair: one capsule, back and forward; hidden until the first click on the title's path.
            // Holding or right-clicking an arrow lists the places behind it.
            let control = HistoryControl(images: [
                NSImage(systemSymbolName: "chevron.left", accessibilityDescription: L("Back"))!,
                NSImage(systemSymbolName: "chevron.right", accessibilityDescription: L("Forward"))!,
            ], trackingMode: .momentary, target: self, action: #selector(historyClicked(_:)))
            control.setToolTip(L("Back"), forSegment: 0)
            control.setToolTip(L("Forward"), forSegment: 1)
            control.setShowsMenuIndicator(false, forSegment: 0)
            control.setShowsMenuIndicator(false, forSegment: 1)
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = control
            item.label = L("Back")
            item.isHidden = !model.hasJumped
            historyItem = item
            historyControl = control
            historyWatch = model.$backList.combineLatest(model.$forwardList, model.$hasJumped)
                .sink { [weak self] back, forward, shown in self?.updateHistory(back: back, forward: forward, shown: shown) }
            return item
        }
        if id == Self.titleItem {
            let item = NSToolbarItem(itemIdentifier: id)
            // The title gives way when the toolbar is tight, like a search field; sized by SwiftUI, a long name
            // pushed it and the info button into the toolbar's » menu. minSize/maxSize are deprecated, but the
            // toolbar ignored a low-priority width constraint and still overflowed; these it honours.
            let titleHost = NSHostingController(rootView: TitleView(model: model))
            titleHost.sizingOptions = []
            self.titleHost = titleHost
            item.view = titleHost.view
            item.minSize = NSSize(width: 60, height: 30)
            item.maxSize = NSSize(width: idealTitleWidth, height: 30)
            titleItemRef = item
            titleWatch = model.$currentURL.combineLatest(model.$groups, model.$hasJumped).sink { [weak self] _, _, _ in
                // After the model has published the new name.
                DispatchQueue.main.async {
                    guard let self, let item = self.titleItemRef else { return }
                    // Room for the chevron that appears beside the name on hover.
                    item.maxSize = NSSize(width: max(60, self.idealTitleWidth + 14), height: 30)
                }
            }
            item.isBordered = false
            return item
        }
        guard id == Self.infoItem else { return nil }
        // A button like the left panel's, so both come out the same size.
        let button = NSButton(image: Self.infoSidebarImage, target: self, action: #selector(showInfo(_:)))
        button.bezelStyle = .toolbar
        button.toolTip = L("Get Info") + " (⌘I)"
        button.isEnabled = model.currentURL != nil
        infoButton = button
        infoWatch = model.$currentURL.sink { [weak self] url in self?.infoButton?.isEnabled = url != nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.view = button
        item.label = L("Get Info")
        return item
    }

    @objc func copyPath(_ sender: Any?) { model.copyPath() }
    @objc func renamePhoto(_ sender: Any?) { model.showsFilePopover = true }
}

// Back and forward in one capsule. A long press shows a segment's menu by itself; a right-click does here too,
// for the arrow under the pointer, instead of the toolbar's own menu.
final class HistoryControl: NSSegmentedControl {
    override func menu(for event: NSEvent) -> NSMenu? {
        let x = convert(event.locationInWindow, from: nil).x
        let segment = x < bounds.midX ? 0 : 1
        return isEnabled(forSegment: segment) ? menu(forSegment: segment) : nil
    }
}

// The window's background, redrawn when the Mac switches between light and dark.
final class SolidBackground: NSView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.backdrop.cgColor }
}

extension NSColor {
    // The window's own background, as in System Settings: white in light mode, the floating panels set apart by
    // their shade and shadow. Earlier a warm grey measured through the see-through glass looked dirty.
    static let backdrop = NSColor.windowBackgroundColor
}
