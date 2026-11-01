import AppKit
import SwiftUI

@MainActor
final class SlideshowController {
    static private(set) var active: SlideshowController?
    static let interval: TimeInterval = 4

    var onEnd: (() -> Void)?
    private let model: ViewerModel
    private let window: NSWindow
    private var timer: Timer?

    init(model: ViewerModel) {
        self.model = model
        let screen = model.window?.screen ?? NSScreen.main!
        window = KeyWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.setFrame(screen.frame, display: false)
        window.contentView = NSHostingView(rootView: SlideshowView(model: model) { [weak self] in self?.stop() })
    }

    func start() {
        Self.active = self
        NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        window.makeKeyAndOrderFront(nil)
        NSCursor.setHiddenUntilMouseMoves(true)
        restartTimer()
    }

    func stop() {
        guard Self.active === self else { return }
        Self.active = nil
        timer?.invalidate()
        window.orderOut(nil)
        NSApp.presentationOptions = []
        model.window?.makeKeyAndOrderFront(nil)
        onEnd?()
    }

    func handle(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command) { return false }
        switch event.keyCode {
        case 123: model.step(-1); restartTimer()
        case 124, 49: model.step(1); restartTimer()
        default: stop()
        }
        return true
    }

    private func restartTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.step(1) }
        }
    }
}

private final class KeyWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

private struct SlideshowView: View {
    @ObservedObject var model: ViewerModel
    let onClick: () -> Void

    var body: some View {
        ZStack {
            Color.black
            if let image = model.image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .id(ObjectIdentifier(image))
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.6), value: model.image.map(ObjectIdentifier.init))
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onClick)
    }
}
