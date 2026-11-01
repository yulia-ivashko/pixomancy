import AppKit
import Combine
import CoreServices
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct InfoSection: Identifiable {
    let id: String
    let rows: [(label: String, value: String)]
    var title: String { L(id) }

    // Labels arrive in English and are translated here.
    init(title: String, rows: [(String, String)]) {
        id = title
        self.rows = rows.map { (L($0.0), $0.1) }
    }
}

// What the right-hand info panel shows; follows the photo as you step.
@MainActor
final class InfoModel: ObservableObject {
    @Published private(set) var sections: [InfoSection] = []
    @Published private(set) var location: (lat: Double, lon: Double)?
    private var watch: AnyCancellable?
    let viewer: ViewerModel

    init(viewer: ViewerModel) {
        self.viewer = viewer
        // Again when the file changes under the same name: new tags, a rotation, edits in another program.
        watch = viewer.$currentURL.combineLatest(viewer.$revision).sink { [weak self] url, _ in self?.load(url) }
    }

    func confirmStrip() {
        guard let url = viewer.currentURL, let window = viewer.window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = String(format: L("Remove all metadata from “%@”?"), url.lastPathComponent)
        alert.informativeText = L("Camera, date taken, location, download source, tags and other details will be deleted for good. File dates will be set to now.")
        alert.addButton(withTitle: L("Remove"))
        alert.addButton(withTitle: L("Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in
                let done = await Task.detached(priority: .userInitiated) {
                    (try? MetadataStripper.strip(url)) != nil
                }.value
                if done {
                    self.viewer.reloadIfShowing(url)
                    self.load(url)
                } else {
                    let failure = NSAlert()
                    failure.messageText = L("Couldn’t remove the metadata")
                    failure.beginSheetModal(for: window, completionHandler: nil)
                }
            }
        }
    }

    private func load(_ url: URL?) {
        guard let url else {
            sections = []
            location = nil
            return
        }
        Task {
            let result = await Task.detached(priority: .userInitiated) { PhotoInfoReader.read(url) }.value
            guard viewer.currentURL == url else { return }
            sections = result.sections
            location = result.location
        }
    }
}

// Dense like Finder's Get Info and Preview's Inspector, not grouped cards: grey labels on the left, values beside
// them on one line, small section headings. The title sits in the band beside the ⓘ button, the one action at the bottom.
struct InfoView: View {
    @ObservedObject var info: InfoModel
    // Sections folded by a click on their heading, as in Finder's Get Info; kept for every photo.
    @AppStorage("FoldedInfoSections") private var foldedList = ""
    private var folded: Set<String> { Set(foldedList.split(separator: ",").map(String.init)) }

    private func toggle(_ id: String) {
        var set = folded
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        withAnimation(.easeOut(duration: 0.15)) { foldedList = set.sorted().joined(separator: ",") }
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                Text("Metadata")
                    .font(.headline)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    // Clear of the ⓘ button, and centred on it, which sits a little above the band's middle (measured).
                    .padding(.horizontal, 52)
                    .padding(.bottom, 8)
                    .frame(height: geometry.safeAreaInsets.top)
                ScrollView {
                    // Every other row shaded, like Finder's list; one label width for all sections, so values line up.
                    let labelWidth = info.sections.flatMap(\.rows).map {
                        ceil(($0.label as NSString).size(withAttributes: [.font: NSFont.preferredFont(forTextStyle: .callout)]).width)
                    }.max() ?? 0
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(info.sections.enumerated()), id: \.element.id) { index, section in
                            let open = !folded.contains(section.id)
                            SectionHeader(title: section.title, open: open, first: index == 0) { toggle(section.id) }
                            ForEach(Array((open ? section.rows : []).enumerated()), id: \.element.label) { row, item in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(item.label)
                                        .foregroundStyle(.secondary)
                                        .frame(width: labelWidth, alignment: .trailing)
                                    LongValue(text: item.value)
                                        // A new photo's text starts folded again.
                                        .id(item.value)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .font(.callout)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 6).fill(row % 2 == 1 ? Color.primary.opacity(0.05) : .clear))
                            }
                            if open, section.id == "Location", let location = info.location {
                                Button("Open in Maps") {
                                    NSWorkspace.shared.open(URL(string: "maps://?ll=\(location.lat),\(location.lon)&q=Photo")!)
                                }
                                .controlSize(.small)
                                .padding(.leading, labelWidth + 16)
                                .padding(.top, 4)
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 16)
                }
                .scrollEdgeEffectHidden(true, for: .top)
                // Rows fade out before the button instead of ending on a hard edge.
                .mask {
                    VStack(spacing: 0) {
                        Color.black
                        LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: 20)
                    }
                }
                if !info.sections.isEmpty {
                    Button(role: .destructive) { info.confirmStrip() } label: {
                        Text("Remove All Metadata…").frame(maxWidth: .infinity)
                    }
                    .buttonBorderShape(.capsule)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 14)
                    .padding(.top, 4)
                }
            }
            .ignoresSafeArea(.container, edges: .top)
        }
        .frame(minWidth: 260)
    }
}

enum PhotoInfoReader {
    nonisolated static func read(_ url: URL) -> (sections: [InfoSection], location: (lat: Double, lon: Double)?) {
        var sections: [InfoSection] = []
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey])
        // Short dates: the long ones wrapped onto a second line in the panel.
        let dates = Date.FormatStyle(date: .abbreviated, time: .shortened)

        var file: [(String, String)] = []
        // "JPEG", not "JPEG image": every file here is an image.
        if let kind = values?.contentType { file.append(("Kind", (kind.preferredFilenameExtension ?? url.pathExtension).uppercased())) }
        if let size = values?.fileSize { file.append(("Size", ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))) }
        if let created = values?.creationDate { file.append(("Created", created.formatted(dates))) }
        if let modified = values?.contentModificationDate { file.append(("Modified", modified.formatted(dates))) }
        // When the file arrived in its folder: a download or a copy, often more telling than Created.
        if let added = (try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]))?.addedToDirectoryDate {
            file.append(("Added", added.formatted(dates)))
        }
        file.append(("Folder", (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath))
        if let tags = (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames, !tags.isEmpty {
            file.append(("Tags", tags.joined(separator: ", ")))
        }
        if let item = MDItemCreateWithURL(nil, url as CFURL) {
            if let opened = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
                file.append(("Last opened", opened.formatted(dates)))
            }
            if let sources = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String], !sources.isEmpty {
                file.append(("Downloaded from", sources.joined(separator: "\n")))
            }
            if let comment = MDItemCopyAttribute(item, kMDItemFinderComment) as? String, !comment.isEmpty {
                file.append(("Comment", comment))
            }
        }
        sections.append(InfoSection(title: "File", rows: file))

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return (sections, nil)
        }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]

        // What people write about a photo goes first: title, caption, keywords, who made it.
        func text(_ value: Any?) -> String? {
            let string = (value as? [String])?.joined(separator: ", ") ?? value as? String
            let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed?.isEmpty == false ? trimmed : nil
        }
        var about: [(String, String)] = []
        let title = text(iptc[kCGImagePropertyIPTCObjectName])
        let headline = text(iptc[kCGImagePropertyIPTCHeadline])
        if let title = title ?? headline { about.append(("Title", title)) }
        if let headline, title != nil, headline != title { about.append(("Headline", headline)) }
        if let caption = text(iptc[kCGImagePropertyIPTCCaptionAbstract]) ?? text(tiff[kCGImagePropertyTIFFImageDescription]) {
            about.append(("Description", caption))
        }
        if let keywords = text(iptc[kCGImagePropertyIPTCKeywords]) { about.append(("Keywords", keywords)) }
        if let author = text(iptc[kCGImagePropertyIPTCByline]) ?? text(tiff[kCGImagePropertyTIFFArtist]) { about.append(("Author", author)) }
        let credit = text(iptc[kCGImagePropertyIPTCCredit])
        if let credit { about.append(("Credit", credit)) }
        if let source = text(iptc[kCGImagePropertyIPTCSource]), source != credit { about.append(("Source", source)) }
        if let rights = text(iptc[kCGImagePropertyIPTCCopyrightNotice]) ?? text(tiff[kCGImagePropertyTIFFCopyright]) {
            about.append(("Copyright", rights))
        }
        if let note = text(exif[kCGImagePropertyExifUserComment]) { about.append(("Comment", note)) }
        // Lightroom and Bridge keep the rating and colour label in XMP; older tools in IPTC.
        let xmp = CGImageSourceCopyMetadataAtIndex(source, 0, nil)
        func xmpText(_ path: String) -> String? {
            xmp.flatMap { CGImageMetadataCopyStringValueWithPath($0, nil, path as CFString) as String? }.flatMap(text)
        }
        let stars = xmpText("xmp:Rating").flatMap(Int.init) ?? (iptc[kCGImagePropertyIPTCStarRating] as? Int) ?? 0
        if (1...5).contains(stars) { about.append(("Rating", String(repeating: "★", count: stars) + String(repeating: "☆", count: 5 - stars))) }
        if let label = xmpText("xmp:Label") { about.append(("Label", label)) }
        if !about.isEmpty { sections.insert(InfoSection(title: "Description", rows: about), at: 0) }

        var image: [(String, String)] = []
        if var width = props[kCGImagePropertyPixelWidth] as? Int, var height = props[kCGImagePropertyPixelHeight] as? Int {
            if let orientation = props[kCGImagePropertyOrientation] as? Int, orientation >= 5 { swap(&width, &height) }
            image.append(("Dimensions", "\(width) × \(height)"))
            image.append(("Megapixels", String(format: L("%.1f MP"), Double(width * height) / 1_000_000)))
        }
        if let dpi = props[kCGImagePropertyDPIWidth] as? Double { image.append(("Resolution", "\(Int(dpi.rounded())) dpi")) }
        if let depth = props[kCGImagePropertyDepth] as? Int { image.append(("Color depth", String(format: L("%d-bit"), depth))) }
        if let profile = props[kCGImagePropertyProfileName] as? String { image.append(("Color profile", profile)) }
        if CGImageSourceGetCount(source) > 1 { image.append(("Frames", "\(CGImageSourceGetCount(source))")) }
        if !image.isEmpty { sections.append(InfoSection(title: "Image", rows: image)) }

        var shot: [(String, String)] = []
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String { shot.append(("Date taken", prettyExifDate(taken))) }
        let camera = [tiff[kCGImagePropertyTIFFMake] as? String, tiff[kCGImagePropertyTIFFModel] as? String]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
        if !camera.isEmpty {
            // "Apple iPhone 15" rather than "Apple Apple iPhone 15".
            let text = camera.count == 2 && camera[1].hasPrefix(camera[0]) ? camera[1] : camera.joined(separator: " ")
            shot.append(("Camera", text))
        }
        // Nikon and others put the lens only in the auxiliary block.
        if var lens = text(exif[kCGImagePropertyExifLensModel]) ?? text(aux[kCGImagePropertyExifAuxLensModel]) {
            // "Sigma 24-70mm", unless the model already names its maker.
            if let make = text(exif[kCGImagePropertyExifLensMake]), !lens.localizedCaseInsensitiveContains(make) { lens = make + " " + lens }
            shot.append(("Lens", lens))
        }
        if let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 {
            shot.append(("Exposure", time >= 1 ? String(format: L("%g s"), time) : String(format: L("1/%d s"), Int((1 / time).rounded()))))
        }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { shot.append(("Aperture", String(format: "ƒ/%g", f))) }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { shot.append(("ISO", "\(iso)")) }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double {
            var text = String(format: L("%g mm"), focal)
            if let full = exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? Int { text += " " + String(format: L("(%d mm equiv.)"), full) }
            shot.append(("Focal length", text))
        }
        if let bias = exif[kCGImagePropertyExifExposureBiasValue] as? Double {
            shot.append(("Exposure bias", abs(bias) < 0.05 ? "0 EV" : String(format: "%+.1f EV", bias).replacingOccurrences(of: "-", with: "−")))
        }
        let programs = [1: "Manual", 2: "Program", 3: "Aperture priority", 4: "Shutter priority",
                        5: "Creative", 6: "Action", 7: "Portrait", 8: "Landscape"]
        if let mode = (exif[kCGImagePropertyExifExposureProgram] as? Int).flatMap({ programs[$0] }) { shot.append(("Mode", L(mode))) }
        let meterings = [1: "Average", 2: "Center-weighted", 3: "Spot", 4: "Multi-spot", 5: "Matrix", 6: "Partial"]
        if let metering = (exif[kCGImagePropertyExifMeteringMode] as? Int).flatMap({ meterings[$0] }) { shot.append(("Metering", L(metering))) }
        if let balance = exif[kCGImagePropertyExifWhiteBalance] as? Int { shot.append(("White balance", L(balance == 1 ? "Manual" : "Auto"))) }
        if let flash = exif[kCGImagePropertyExifFlash] as? Int { shot.append(("Flash", flash & 1 == 1 ? L("Fired") : L("Off"))) }
        if let software = tiff[kCGImagePropertyTIFFSoftware] as? String { shot.append(("Software", software)) }
        // What an iPhone adds: the still of a Live Photo carries its pair's identifier in Apple's maker note,
        // HDR is a composite of several frames, Portrait keeps a depth map beside the picture.
        var features: [String] = []
        let apple = props[kCGImagePropertyMakerAppleDictionary] as? [String: Any] ?? [:]
        if apple["17"] != nil { features.append("Live Photo") }
        if let composite = exif[kCGImagePropertyExifCompositeImage] as? Int, composite >= 2 { features.append("HDR") }
        let depth = [kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypePortraitEffectsMatte]
        if depth.contains(where: { CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, $0) != nil }) { features.append(L("Portrait")) }
        if !features.isEmpty { shot.append(("Features", features.joined(separator: ", "))) }
        if !shot.isEmpty { sections.append(InfoSection(title: "Shooting", rows: shot)) }

        var location: (lat: Double, lon: Double)?
        var place: [(String, String)] = []
        // The place in words, as Lightroom and Photos write it: nearest first.
        let words = [kCGImagePropertyIPTCSubLocation, kCGImagePropertyIPTCCity, kCGImagePropertyIPTCProvinceState,
                     kCGImagePropertyIPTCCountryPrimaryLocationName].compactMap { text(iptc[$0]) }
        if !words.isEmpty { place.append(("Place", words.joined(separator: ", "))) }
        if var lat = gps[kCGImagePropertyGPSLatitude] as? Double, var lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            if (gps[kCGImagePropertyGPSLatitudeRef] as? String) == "S" { lat = -lat }
            if (gps[kCGImagePropertyGPSLongitudeRef] as? String) == "W" { lon = -lon }
            location = (lat, lon)
            place.append(("Coordinates", String(format: "%.5f, %.5f", lat, lon)))
        }
        if let altitude = gps[kCGImagePropertyGPSAltitude] as? Double {
            let below = (gps[kCGImagePropertyGPSAltitudeRef] as? Int) == 1
            place.append(("Altitude", String(format: L("%d m"), Int((below ? -altitude : altitude).rounded()))))
        }
        if let heading = gps[kCGImagePropertyGPSImgDirection] as? Double {
            let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
            let point = points[Int((heading / 45).rounded()) % 8]
            place.append(("Direction", "\(Int(heading.rounded()))° \(L(point))"))
        }
        if let speed = gps[kCGImagePropertyGPSSpeed] as? Double, speed > 0 {
            let unit = ["K": "km/h", "M": "mph", "N": "kn"][gps[kCGImagePropertyGPSSpeedRef] as? String ?? "K"] ?? "km/h"
            place.append(("Speed", String(format: "%g ", (speed * 10).rounded() / 10) + L(unit)))
        }
        if !place.isEmpty { sections.append(InfoSection(title: "Location", rows: place)) }
        return (sections, location)
    }

    // EXIF writes "2024:07:15 18:42:03".
    private static func prettyExifDate(_ raw: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy:MM:dd HH:mm:ss"
        guard let date = parser.date(from: raw) else { return raw }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened))
    }
}

// Long values (a NASA caption runs to twenty lines) show two lines, with an arrow after them to unfold the rest.
private struct LongValue: View {
    let text: String
    @State private var open = false
    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0

    var body: some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(text)
                .textSelection(.enabled)
                .lineLimit(open ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
                // The whole text, unseen, to tell whether two lines cut anything off.
                .background(alignment: .topLeading) {
                    Text(text)
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
                }
            if open || fullHeight > shownHeight + 1 {
                Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(open ? L("Less") : L("More"))
            }
        }
    }
}

// Finder's Get Info heading: a chevron and the name in plain text, a line above every section but the first.
private struct SectionHeader: View {
    let title: String
    let open: Bool
    let first: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !first { Divider() }
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(title)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)
        }
        .padding(.top, first ? 0 : 10)
        .padding(.bottom, 4)
    }
}
