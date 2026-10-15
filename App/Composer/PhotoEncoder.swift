import UIKit

/// Turns a picked photo into a JPEG of at most `maxBytes` (5 MB by default;
/// the server takes up to 10 MB). Lowers the quality first, then the size.
enum PhotoEncoder {
    static let maxBytes = 5_000_000

    static func pendingImage(from data: Data, filename: String, maxBytes: Int = maxBytes) -> PendingImage? {
        guard let image = UIImage(data: data) else { return nil }
        return pendingImage(from: image, filename: filename, maxBytes: maxBytes)
    }

    static func pendingImage(from image: UIImage, filename: String, maxBytes: Int = maxBytes) -> PendingImage? {
        guard let jpeg = jpeg(from: image, maxBytes: maxBytes) else { return nil }
        return PendingImage(data: jpeg, filename: filename, contentType: "image/jpeg")
    }

    static func jpeg(from image: UIImage, maxBytes: Int = maxBytes) -> Data? {
        var current = image
        for _ in 0..<12 {
            for quality in [0.8, 0.6, 0.4, 0.25] as [CGFloat] {
                guard let data = current.jpegData(compressionQuality: quality) else { return nil }
                if data.count <= maxBytes { return data }
            }
            guard let smaller = scaled(current, by: 0.7) else { return nil }
            current = smaller
        }
        return nil
    }

    /// The image at `factor` of its pixel size, upright.
    private static func scaled(_ image: UIImage, by factor: CGFloat) -> UIImage? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let size = CGSize(width: (pixels.width * factor).rounded(.down), height: (pixels.height * factor).rounded(.down))
        guard size.width >= 1, size.height >= 1 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
