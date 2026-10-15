import Foundation
import Testing
import UIKit
@testable import PaperclipIOS

/// Picked photos become a JPEG under the size limit.
@Suite
struct PhotoEncoderTests {
    /// A busy picture (many coloured squares) that does not compress well.
    static func busyImage(side: Int) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { context in
            let step = 5
            for x in stride(from: 0, to: side, by: step) {
                for y in stride(from: 0, to: side, by: step) {
                    let hue = CGFloat((x * 31 + y * 17) % 255) / 255
                    UIColor(hue: hue, saturation: 0.9, brightness: CGFloat((x + y) % 7 + 3) / 10, alpha: 1).setFill()
                    context.fill(CGRect(x: x, y: y, width: step, height: step))
                }
            }
        }
    }

    @Test func pngBecomesAJPEG() throws {
        let png = try #require(Self.busyImage(side: 64).pngData())
        let image = try #require(PhotoEncoder.pendingImage(from: png, filename: "photo.jpg"))
        #expect(image.contentType == "image/jpeg")
        #expect(image.filename == "photo.jpg")
        #expect(image.data.starts(with: [0xFF, 0xD8]))
        #expect(image.uploadedAttachmentId == nil)
    }

    @Test func largePhotoShrinksUnderTheLimit() throws {
        let image = Self.busyImage(side: 1024)
        let limit = 20_000
        let full = try #require(image.jpegData(compressionQuality: 0.25))
        #expect(full.count > limit)

        let jpeg = try #require(PhotoEncoder.jpeg(from: image, maxBytes: limit))
        #expect(jpeg.count <= limit)
        #expect(UIImage(data: jpeg) != nil)
    }

    @Test func notAnImageGivesNil() {
        #expect(PhotoEncoder.pendingImage(from: Data("hello".utf8), filename: "x.jpg") == nil)
    }

    @Test func defaultLimitIsFiveMegabytes() {
        #expect(PhotoEncoder.maxBytes == 5_000_000)
    }
}
