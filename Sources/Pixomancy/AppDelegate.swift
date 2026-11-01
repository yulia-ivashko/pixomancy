import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controllers: [ViewerWindowController] = []

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.build()
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if let show = SlideshowController.active {
                return show.handle(event) ? nil : event
            }
            guard let controller = NSApp.keyWindow?.windowController as? ViewerWindowController else {
                return event
            }
            return controller.handleKey(event) ? nil : event
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Files opened from Finder arrive before this; a bare launch brings back the last session.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if self.controllers.isEmpty { self.restoreSession() }
        }
        NSApp.activate()
    }

    // From Finder: the first item replaces what the front window shows, the rest join it.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        openWindow(with: first)
        for url in urls.dropFirst() { frontController?.model.add(url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { restoreSession() }
        return true
    }

    private var frontController: ViewerWindowController? {
        (NSApp.mainWindow?.windowController as? ViewerWindowController) ?? controllers.last
    }

    // Opens in the front window, replacing what it showed; a new window only when there is none.
    func openWindow(with url: URL?) {
        if let url, let front = frontController {
            front.model.open(url)
            front.showWindow(nil)
            return
        }
        newWindow(with: url)
    }

    @discardableResult
    private func newWindow(with url: URL?) -> ViewerWindowController {
        let controller = ViewerWindowController(url: url)
        controller.onClose = { [weak self, weak controller] in
            self?.controllers.removeAll { $0 === controller }
        }
        controllers.append(controller)
        controller.showWindow(nil)
        return controller
    }

    private func restoreSession() {
        let defaults = UserDefaults.standard
        let folders = (defaults.stringArray(forKey: ViewerModel.sessionFoldersKey) ?? []).map { URL(fileURLWithPath: $0) }
        let photo = defaults.string(forKey: ViewerModel.sessionPhotoKey).map { URL(fileURLWithPath: $0) }
        let controller = newWindow(with: nil)
        controller.model.restore(folders: folders, photo: photo)
    }

    // The standard panel, with who made Pixomancy and where it lives; the credit stays in English in every language.
    @objc func showAbout(_ sender: Any?) {
        let credits = NSMutableAttributedString(string: "Made by Iuliia Ivashko\n", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.labelColor,
        ])
        credits.append(NSAttributedString(string: "github.com/yulia-ivashko/pixomancy", attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .link: URL(string: "https://github.com/yulia-ivashko/pixomancy")!,
        ]))
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centred, range: NSRange(location: 0, length: credits.length))
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
        NSApp.activate()
    }

    @objc func openDocument(_ sender: Any?) {
        if let url = Self.runOpenPanel() { openWindow(with: url) }
    }

    @objc func openInNewWindow(_ sender: Any?) {
        if let url = Self.runOpenPanel() { newWindow(with: url) }
    }

    @objc func addFolder(_ sender: Any?) {
        guard let url = Self.runOpenPanel() else { return }
        if let front = frontController { front.model.add(url) } else { newWindow(with: url) }
    }

    static func runOpenPanel() -> URL? {
        let panel = NSOpenPanel()
        // A folder opens at its first photo.
        panel.allowedContentTypes = [.image, .folder]
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
