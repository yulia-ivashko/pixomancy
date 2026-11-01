import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageRotator {
    enum Failure: Error { case unreadable, unsupported, writeFailed }

    // EXIF orientation after one clockwise quarter turn.
    private static let clockwiseTurn: [Int: Int] = [1: 6, 6: 3, 3: 8, 8: 1, 2: 7, 7: 4, 4: 5, 5: 2]

    // Formats where turning means changing the orientation tag, so the photo is not re-compressed.
    private static let taggedTypes: [UTType] = [.jpeg, .heic, .heif, .tiff]

    static func rotate(_ url: URL, clockwise: Bool) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let typeID = CGImageSourceGetType(source) else { throw Failure.unreadable }
        guard CGImageSourceGetCount(source) == 1 else { throw Failure.unsupported }

        let fileManager = FileManager.default
        let scratch = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let output = scratch.appendingPathComponent(url.lastPathComponent)

        let type = UTType(typeID as String)
        if let type, taggedTypes.contains(where: { type.conforms(to: $0) }) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
            let old = props[kCGImagePropertyOrientation] as? Int ?? 1
            var new = clockwiseTurn[old] ?? 6
            if !clockwise { new = clockwiseTurn[clockwiseTurn[new]!]! }
            try writeTagged(source: source, typeID: typeID, props: props, orientation: new, to: output)
        } else {
            guard let decoded = ImageLoader.decode(url),
                  let turned = turn(decoded, clockwise: clockwise),
                  let destination = CGImageDestinationCreateWithURL(output as CFURL, typeID, 1, nil) else {
                throw Failure.unsupported
            }
            CGImageDestinationAddImage(destination, turned, nil)
            guard CGImageDestinationFinalize(destination) else { throw Failure.writeFailed }
        }
        _ = try fileManager.replaceItemAt(url, withItemAt: output)
    }

    private static func writeTagged(source: CGImageSource, typeID: CFString, props: [CFString: Any], orientation: Int, to output: URL) throws {
        if let destination = CGImageDestinationCreateWithURL(output as CFURL, typeID, 1, nil) {
            let options = [kCGImageDestinationOrientation: orientation] as CFDictionary
            if CGImageDestinationCopyImageSource(destination, source, options, nil) { return }
        }
        // Fallback: re-encode with the new tag.
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, typeID, 1, nil) else {
            throw Failure.writeFailed
        }
        var newProps = props
        newProps[kCGImagePropertyOrientation] = orientation
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = orientation
            newProps[kCGImagePropertyTIFFDictionary] = tiff
        }
        newProps[kCGImageDestinationLossyCompressionQuality] = 0.95
        CGImageDestinationAddImageFromSource(destination, source, 0, newProps as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.writeFailed }
    }

    private static func turn(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let width = image.width, height = image.height
        let space = image.colorSpace.flatMap { $0.model == .rgb ? $0 : nil } ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil, width: height, height: width, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        if clockwise {
            context.translateBy(x: 0, y: CGFloat(width))
            context.rotate(by: -.pi / 2)
        } else {
            context.translateBy(x: CGFloat(height), y: 0)
            context.rotate(by: .pi / 2)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
