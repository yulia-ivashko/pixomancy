import Foundation
import ImageIO

enum MetadataStripper {
    enum Failure: Error { case unreadable, writeFailed }

    // Drops EXIF, GPS, IPTC, XMP and the rest; keeps pixels, colour profile and orientation.
    static func strip(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let typeID = CGImageSourceGetType(source) else { throw Failure.unreadable }

        let fileManager = FileManager.default
        let scratch = try fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
        defer { try? fileManager.removeItem(at: scratch) }
        let output = scratch.appendingPathComponent(url.lastPathComponent)

        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1

        // Lossless path: same compressed data, empty metadata.
        if let destination = CGImageDestinationCreateWithURL(output as CFURL, typeID, 1, nil) {
            let options: [CFString: Any] = [
                kCGImageDestinationMetadata: CGImageMetadataCreateMutable(),
                kCGImageDestinationMergeMetadata: false,
                kCGImageMetadataShouldExcludeGPS: true,
                kCGImageDestinationOrientation: orientation,
            ]
            if CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, nil),
               isClean(output) {
                _ = try fileManager.replaceItemAt(url, withItemAt: output)
                scrubFile(url)
                return
            }
        }

        // Fallback: re-encode the pixels with nothing attached; orientation is baked in.
        guard let image = ImageLoader.decode(url),
              let destination = CGImageDestinationCreateWithURL(output as CFURL, typeID, 1, nil) else {
            throw Failure.writeFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.writeFailed }
        _ = try fileManager.replaceItemAt(url, withItemAt: output)
        scrubFile(url)
    }

    // What macOS keeps beside the photo: download source, quarantine, last opened, tags, comments.
    // Then both file dates become "now".
    private static func scrubFile(_ url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return }
            var buffer = [CChar](repeating: 0, count: size)
            guard listxattr(path, &buffer, size, XATTR_NOFOLLOW) == size else { return }
            let names = buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
            for name in names { removexattr(path, name, XATTR_NOFOLLOW) }
        }
        let now = Date()
        try? FileManager.default.setAttributes([.creationDate: now, .modificationDate: now], ofItemAtPath: url.path)
    }

    private static func isClean(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return false }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        return props[kCGImagePropertyGPSDictionary] == nil
            && props[kCGImagePropertyIPTCDictionary] == nil
            && exif[kCGImagePropertyExifDateTimeOriginal] == nil
            && tiff[kCGImagePropertyTIFFMake] == nil
            && tiff[kCGImagePropertyTIFFModel] == nil
            && tiff[kCGImagePropertyTIFFSoftware] == nil
    }
}
