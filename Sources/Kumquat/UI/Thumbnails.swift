import AppKit
import QuickLookThumbnailing

/// QuickLook thumbnails with a Finder-icon fallback, delivered on the main thread.
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    static func load(_ url: URL, size: CGSize, completion: @escaping @MainActor (NSImage) -> Void) {
        let key = "\(url.path)|\(Int(size.width))x\(Int(size.height))"
        if let cached = cache.object(forKey: key as NSString) {
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(cached) } }
            return
        }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image = rep?.nsImage
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let result = image ?? NSWorkspace.shared.icon(forFile: url.path)
                    cache.setObject(result, forKey: key as NSString)
                    completion(result)
                }
            }
        }
    }
}
