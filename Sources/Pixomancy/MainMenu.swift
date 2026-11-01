import AppKit

@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()

        submenu(in: main, "Pixomancy", [
            NSMenuItem("About Pixomancy", #selector(AppDelegate.showAbout(_:))),
            .separator(),
            NSMenuItem("Hide Pixomancy", #selector(NSApplication.hide(_:)), key: "h"),
            NSMenuItem("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), key: "h", modifiers: [.command, .option]),
            NSMenuItem("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            NSMenuItem("Quit Pixomancy", #selector(NSApplication.terminate(_:)), key: "q"),
        ])

        submenu(in: main, "File", [
            NSMenuItem("Open…", #selector(AppDelegate.openDocument(_:)), symbol: "folder", key: "o"),
            NSMenuItem("Open in New Window…", #selector(AppDelegate.openInNewWindow(_:)), symbol: "macwindow.badge.plus", key: "o").alternate(),
            NSMenuItem("Add Folder…", #selector(AppDelegate.addFolder(_:)), symbol: "folder.badge.plus", key: "o", modifiers: [.command, .shift]),
            NSMenuItem("Rename…", #selector(ViewerWindowController.renamePhoto(_:)), symbol: "pencil"),
            NSMenuItem("Open in Preview", #selector(ViewerWindowController.openInPreview(_:)), symbol: "pencil.tip.crop.circle"),
            NSMenuItem("Show in Finder", #selector(ViewerWindowController.showInFinder(_:)), symbol: "finder", key: "r", modifiers: [.command, .shift]),
            NSMenuItem("Get Info", #selector(ViewerWindowController.showInfo(_:)), symbol: "info.circle", key: "i"),
            .separator(),
            NSMenuItem("Print…", #selector(ViewerWindowController.printPhoto(_:)), symbol: "printer", key: "p"),
            .separator(),
            NSMenuItem("Close", #selector(NSWindow.performClose(_:)), symbol: "xmark", key: "w"),
        ])

        submenu(in: main, "Edit", [
            NSMenuItem("Copy", #selector(ViewerWindowController.copy(_:)), symbol: "doc.on.doc", key: "c"),
            NSMenuItem("Copy Path", #selector(ViewerWindowController.copyPath(_:)), symbol: "document.on.clipboard", key: "c").alternate(),
            NSMenuItem("Move to Trash", #selector(ViewerWindowController.moveToTrash(_:)), symbol: "trash", key: "\u{8}"),
        ])

        submenu(in: main, "View", [
            NSMenuItem("Zoom In", #selector(ViewerWindowController.zoomIn(_:)), symbol: "plus.magnifyingglass", key: "+"),
            NSMenuItem("Zoom Out", #selector(ViewerWindowController.zoomOut(_:)), symbol: "minus.magnifyingglass", key: "-"),
            NSMenuItem("Actual Size", #selector(ViewerWindowController.actualSize(_:)), symbol: "1.magnifyingglass", key: "0"),
            NSMenuItem("Fit to Window", #selector(ViewerWindowController.fitToWindow(_:)), symbol: "arrow.down.right.and.arrow.up.left", key: "9"),
            NSMenuItem("Fit to Screen", #selector(ViewerWindowController.fitToScreen(_:)), symbol: "arrow.up.left.and.arrow.down.right", key: "8"),
            .separator(),
            NSMenuItem("Thumbnails", #selector(ViewerWindowController.setThumbnailStyle(_:))).tagged(0),
            NSMenuItem("Thumbnails and Names", #selector(ViewerWindowController.setThumbnailStyle(_:))).tagged(1),
            NSMenuItem("List", #selector(ViewerWindowController.setThumbnailStyle(_:))).tagged(2),
            .separator(),
            NSMenuItem("Slideshow", #selector(ViewerWindowController.startSlideshow(_:)), symbol: "play", key: key(NSF5FunctionKey), modifiers: []),
            NSMenuItem("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), key: "f", modifiers: [.command, .control]),
        ])

        submenu(in: main, "Photo", [
            NSMenuItem("Previous", #selector(ViewerWindowController.showPrevious(_:)), symbol: "chevron.backward", key: key(NSLeftArrowFunctionKey), modifiers: []),
            NSMenuItem("Next", #selector(ViewerWindowController.showNext(_:)), symbol: "chevron.forward", key: key(NSRightArrowFunctionKey), modifiers: []),
            .separator(),
            NSMenuItem("Rotate Left", #selector(ViewerWindowController.rotateLeft(_:)), symbol: "rotate.left", key: "l"),
            NSMenuItem("Rotate Right", #selector(ViewerWindowController.rotateRight(_:)), symbol: "rotate.right", key: "r"),
            .separator(),
            NSMenuItem("Set as Wallpaper", #selector(ViewerWindowController.setAsWallpaper(_:)), symbol: "photo.on.rectangle"),
        ])

        let window = submenu(in: main, "Window", [
            NSMenuItem("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"),
            NSMenuItem("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        NSApp.windowsMenu = window

        return main
    }

    @discardableResult
    private static func submenu(in main: NSMenu, _ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: L(title))
        items.forEach(menu.addItem)
        let holder = NSMenuItem()
        holder.submenu = menu
        main.addItem(holder)
        return menu
    }

    private static func key(_ code: Int) -> String {
        String(Character(UnicodeScalar(UInt16(code))!))
    }
}
