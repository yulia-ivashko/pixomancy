import SwiftUI
import UniformTypeIdentifiers

struct ViewerView: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var zoom: ZoomController

    // The strip under the photo that holds the controls.
    static let barSpace: CGFloat = 56

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.currentURL == nil, !model.groups.isEmpty {
                // Folders are open but hold no photos yet.
                Text("No Photos")
                    .font(.title3)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.currentURL == nil {
                emptyState
            } else {
                ZoomableImage(image: model.image, zoom: zoom, bottomInset: Self.barSpace) {
                    (model.window?.windowController as? ViewerWindowController)?.contextMenu()
                }
                if model.loadFailed {
                    Text("Can’t open this photo")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.bottom, Self.barSpace)
                }
                ControlBar(model: model, zoom: zoom)
                    .padding(.bottom, 9)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Measured: the info card starts 8 pt past the end of this pane.
        .padding(.trailing, model.infoPanelOpen ? -8 : 0)
        // Solid, not see-through: the desktop no longer shows round the photo.
        .background { Color(nsColor: .backdrop).ignoresSafeArea() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.open(url) }
            }
            return true
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tertiary)
            Button("Open Photo…") {
                if let url = AppDelegate.runOpenPanel() { model.open(url) }
            }
            .buttonStyle(.glassProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Finder-style toolbar groups: zoom out, size, zoom in, fit to screen | previous, next | rotate | delete.
struct ControlBar: View {
    @ObservedObject var model: ViewerModel
    @ObservedObject var zoom: ZoomController

    var body: some View {
        let hasImage = model.image != nil
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                BarGroup {
                    BarButton(symbol: "minus.magnifyingglass", help: "Zoom Out (⌘−)") { zoom.zoom(by: 0.8) }
                    BarDivider()
                    BarButton(
                        symbol: "1.magnifyingglass",
                        help: zoom.isActualSize
                            ? (zoom.isFit && zoom.isSmall ? "Fill Window" : "Fit to Window (⌘9)")
                            : "Actual Size (⌘0)"
                    ) {
                        zoom.toggleSize()
                    }
                    BarDivider()
                    BarButton(symbol: "plus.magnifyingglass", help: "Zoom In (⌘+)") { zoom.zoom(by: 1.25) }
                    BarDivider()
                    BarButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Fit to Screen (⌘8)") { model.fitWindowToScreen() }
                }
                .disabled(!hasImage)

                // Slideshow lives in the View menu and on F5, as in Preview: the bar keeps only what you reach for often.
                BarGroup {
                    BarButton(symbol: "chevron.backward", help: "Previous (←)") { model.step(-1) }
                    BarDivider()
                    BarButton(symbol: "chevron.forward", help: "Next (→)") { model.step(1) }
                }

                BarGroup {
                    BarButton(symbol: "rotate.left", help: "Rotate Left (⌘L)") { model.rotate(clockwise: false) }
                    BarDivider()
                    BarButton(symbol: "rotate.right", help: "Rotate Right (⌘R)") { model.rotate(clockwise: true) }
                }
                .disabled(!hasImage)

                BarGroup {
                    BarButton(symbol: "trash", help: "Move to Trash (Delete)") { model.confirmTrash() }
                }
            }
        }
    }
}

private let cellSize: CGFloat = 34

private struct BarGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .padding(2)
            .glassEffect(.regular, in: Capsule())
    }
}

private struct BarDivider: View {
    var body: some View {
        Rectangle()
            .fill(.primary.opacity(0.18))
            .frame(width: 1, height: 18)
    }
}

private struct BarButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15))
        }
        .buttonStyle(CellStyle())
        .overlay(ToolTip(text: L(help)))
    }
}

// SwiftUI's .help showed nothing on buttons inside the glass groups; AppKit's own tooltip does.
private struct ToolTip: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> PassThroughView { PassThroughView() }
    func updateNSView(_ view: PassThroughView, context: Context) { view.text = text }

    // Asked for its text each time the tip is about to show, so a button whose action changed
    // after a click never shows the old wording.
    final class PassThroughView: NSView {
        var text = ""
        private var tipTag: NSView.ToolTipTag?

        // Clicks go to the button underneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            if let tipTag { removeToolTip(tipTag) }
            tipTag = addToolTip(bounds, owner: self, userData: nil)
        }

        @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData: UnsafeMutableRawPointer?) -> String {
            text
        }
    }
}

// A bare glyph that gets a soft circle under the pointer.
private struct CellStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Cell(configuration: configuration)
    }

    private struct Cell: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.colorScheme) private var scheme
        @State private var hovering = false

        var body: some View {
            let pressed = configuration.isPressed
            // Solid colours: hierarchical styles turn grey on glass.
            let ink: Color = scheme == .dark ? .white : .black
            configuration.label
                .foregroundStyle(ink)
                .frame(width: cellSize, height: cellSize)
                .background { Circle().fill(ink.opacity(pressed ? 0.16 : hovering ? 0.08 : 0)) }
                .contentShape(Circle())
                .opacity(isEnabled ? 1 : 0.35)
                .onHover { hovering = $0 }
        }
    }
}
