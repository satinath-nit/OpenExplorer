import AppKit
import Foundation
import ImageIO
import OpenExplorerCore
import QuickLookThumbnailing

@MainActor
final class ThumbnailCacheService {
    static let shared = ThumbnailCacheService()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: Set<String> = []

    private init() {
        cache.countLimit = 600
    }

    static let thumbnailEligibleExtensions: Set<String> = [
        "png", "jpg", "jpeg", "webp", "heic", "gif", "tiff", "bmp", "svg", "ico",
        "pdf", "mp4", "mov", "m4v", "avi", "mkv", "psd", "ai", "pages", "numbers", "key"
    ]

    func isEligibleForThumbnail(_ url: URL, isDirectory: Bool) -> Bool {
        guard !isDirectory else { return false }
        return Self.thumbnailEligibleExtensions.contains(url.pathExtension.lowercased())
    }

    func cachedThumbnail(for url: URL, size: CGFloat) -> NSImage? {
        let bucket = Int(size.rounded())
        let key = "\(url.standardizedFileURL.path)#\(bucket)" as NSString
        return cache.object(forKey: key)
    }

    func requestThumbnail(
        for url: URL,
        size: CGFloat,
        scale: CGFloat = NSScreen.main?.backingScaleFactor ?? 2.0,
        completion: @escaping @MainActor (NSImage?) -> Void
    ) {
        let bucket = Int(max(24, size).rounded())
        let keyString = "\(url.standardizedFileURL.path)#\(bucket)"
        if let existing = cache.object(forKey: keyString as NSString) {
            completion(existing)
            return
        }
        guard !inFlight.contains(keyString) else { return }
        inFlight.insert(keyString)

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: CGFloat(bucket), height: CGFloat(bucket)),
            scale: scale,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] representation, _ in
            let image = representation?.nsImage
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inFlight.remove(keyString)
                if let image {
                    self.cache.setObject(image, forKey: keyString as NSString)
                }
                completion(image)
            }
        }
    }

    nonisolated static func imageDimensions(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let imageExts: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "gif", "tiff", "bmp"]
        guard imageExts.contains(ext),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        return "\(width) × \(height) px"
    }
}
