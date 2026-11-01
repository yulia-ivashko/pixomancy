import AppKit
import SwiftUI

@MainActor
final class ZoomController: ObservableObject {
    // 1 means one photo pixel per screen pixel.
    @Published private(set) var magnification: CGFloat = 1
    @Published private(set) var isFit = true
    // The photo is no bigger than the window, so "fit" already shows it at real size.
    @Published private(set) var isSmall = false
    fileprivate weak var scrollView: ImageScrollView?

    static let range: ClosedRange<CGFloat> = 0.03...32

    func zoom(by factor: CGFloat) { scrollView?.zoom(to: magnification * factor) }
    func set(_ value: CGFloat) { scrollView?.zoom(to: value) }
    func fit() { scrollView?.fit() }
    func actualSize() { scrollView?.zoom(to: 1) }
    func fill() {
        guard let scrollView, let value = scrollView.fillMagnification else { return }
        scrollView.zoom(to: value)
    }

    var isActualSize: Bool { abs(magnification - 1) < 0.005 }

    // The "1" button: any zoom other than real size goes to real size; from real size, back to the window
    // (small photos, which already fit at real size, stretch to fill it).
    func toggleSize() {
        guard let scrollView else { return }
        if !isActualSize {
            scrollView.zoom(to: 1)
        } else if isFit, isSmall, let fill = scrollView.fillMagnification {
            scrollView.zoom(to: fill)
        } else {
            scrollView.fit()
        }
    }

    fileprivate func report(_ value: CGFloat, fit: Bool, small: Bool) {
        DispatchQueue.main.async {
            self.magnification = value
            self.isFit = fit
            self.isSmall = small
        }
    }
}

struct ZoomableImage: NSViewRepresentable {
    let image: CGImage?
    let zoom: ZoomController
    let bottomInset: CGFloat
    let contextMenu: () -> NSMenu?

    func makeNSView(context: Context) -> ImageScrollView {
        let view = ImageScrollView()
        view.contextMenu = contextMenu
        view.clip.bottomInset = bottomInset
        view.controller = zoom
        zoom.scrollView = view
        view.setImage(image)
        return view
    }

    func updateNSView(_ view: ImageScrollView, context: Context) {
        if view.shownImage !== image { view.setImage(image) }
    }
}

final class ImageScrollView: NSScrollView {
    let clip = CenteringClipView()
    private let imageView = PanImageView()
    private(set) var shownImage: CGImage?
    private var fitMode = true
    weak var controller: ZoomController?
    var contextMenu: (() -> NSMenu?)?

    override func menu(for event: NSEvent) -> NSMenu? {
        contextMenu?()
    }

    init() {
        super.init(frame: .zero)
        contentView = clip
        documentView = imageView
        drawsBackground = false
        clip.drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        allowsMagnification = true
        minMagnification = ZoomController.range.lowerBound
        maxMagnification = ZoomController.range.upperBound
        NotificationCenter.default.addObserver(
            self, selector: #selector(userMagnified), name: NSScrollView.didEndLiveMagnifyNotification, object: self
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    func setImage(_ image: CGImage?) {
        shownImage = image
        guard let image else {
            imageView.image = nil
            imageView.frame = .zero
            return
        }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let size = NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale)
        imageView.image = NSImage(cgImage: image, size: size)
        imageView.frame = NSRect(origin: .zero, size: size)
        fit()
    }

    // Shrink big photos to the window; never blow small ones up.
    private var fitMagnification: CGFloat? {
        fillMagnification.map { min($0, 1) }
    }

    static let sideMargin: CGFloat = 16

    // Scale at which the photo fills the window, small photos stretched.
    var fillMagnification: CGFloat? {
        let size = imageView.frame.size
        // A fitted photo keeps some air from the side panels and the window edges.
        let width = clip.frame.width - 2 * Self.sideMargin
        let height = clip.frame.height - clip.bottomInset - Self.sideMargin
        guard size.width > 0, size.height > 0, width > 0, height > 0 else { return nil }
        return min(width / size.width, height / size.height)
    }

    private func report() {
        controller?.report(magnification, fit: fitMode, small: (fillMagnification ?? 0) >= 1)
    }

    func fit() {
        fitMode = true
        guard let value = fitMagnification else { return }
        apply(value, around: nil)
    }

    func zoom(to value: CGFloat, around point: NSPoint? = nil) {
        fitMode = false
        let clamped = min(max(value, ZoomController.range.lowerBound), ZoomController.range.upperBound)
        apply(clamped, around: point)
    }

    private func apply(_ value: CGFloat, around point: NSPoint?) {
        let center = point ?? NSPoint(x: clip.bounds.midX, y: clip.bounds.midY)
        setMagnification(value, centeredAt: center)
        clip.setBoundsOrigin(clip.constrainBoundsRect(clip.bounds).origin)
        reflectScrolledClipView(clip)
        report()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if fitMode { fit() } else { report() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let shownImage { setImage(shownImage) }
    }

    @objc private func userMagnified() {
        fitMode = false
        report()
    }

    // Mice have no pinch: ⌘ + wheel zooms around the pointer.
    override func scrollWheel(with event: NSEvent) {
        guard event.modifierFlags.contains(.command) else {
            super.scrollWheel(with: event)
            return
        }
        let step = event.hasPreciseScrollingDeltas ? 0.01 : 0.1
        let point = imageView.convert(event.locationInWindow, from: nil)
        zoom(to: magnification * exp(event.scrollingDeltaY * step), around: point)
    }
}

// Keeps a smaller-than-window photo centred above the control bar.
final class CenteringClipView: NSClipView {
    var bottomInset: CGFloat = 0

    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView?.frame, frame.height > 0 else { return rect }
        let inset = bottomInset * rect.height / frame.height
        let visibleHeight = rect.height - inset

        if document.width < rect.width {
            rect.origin.x = (document.width - rect.width) / 2
        }
        if document.height < visibleHeight {
            rect.origin.y = document.height / 2 - inset - visibleHeight / 2
        } else {
            rect.origin.y = min(max(proposed.origin.y, -inset), document.height - rect.height)
        }
        return rect
    }
}

// Drag the photo with the mouse when it is bigger than the window.
final class PanImageView: NSImageView {
    private var lastPoint = NSPoint.zero

    override init(frame: NSRect) {
        super.init(frame: frame)
        imageScaling = .scaleAxesIndependently
        isEditable = false
        animates = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control), let menu = menu(for: event) {
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return
        }
        lastPoint = event.locationInWindow
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let point = event.locationInWindow
        var origin = clip.bounds.origin
        origin.x -= (point.x - lastPoint.x) / scrollView.magnification
        origin.y -= (point.y - lastPoint.y) / scrollView.magnification
        lastPoint = point
        clip.setBoundsOrigin(clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        NSCursor.pop()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        enclosingScrollView?.menu(for: event)
    }
}
