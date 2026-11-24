import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation

public enum QRCodeGenerator {
    private static let sharedContext = CIContext(options: nil)

    public static func generate(from string: String, size: CGFloat = 200) -> NSImage? {
        guard let data = string.data(using: .utf8) else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"

        guard let outputImage = filter.outputImage else { return nil }
        let extent = outputImage.extent.integral
        guard extent.width > 0, extent.height > 0 else { return nil }

        guard let cgQR = sharedContext.createCGImage(outputImage, from: extent) else {
            return nil
        }

        let pixelScale = max(1, floor(size / extent.width))
        let renderedWidth = extent.width * pixelScale
        let renderedHeight = extent.height * pixelScale
        let quietPadding: CGFloat = 10
        let totalSize = NSSize(
            width: renderedWidth + quietPadding * 2,
            height: renderedHeight + quietPadding * 2
        )

        let image = NSImage(size: totalSize, flipped: false) { _ in
            NSColor.white.setFill()
            NSBezierPath(rect: NSRect(origin: .zero, size: totalSize)).fill()

            if let cgContext = NSGraphicsContext.current?.cgContext {
                cgContext.interpolationQuality = .none
                cgContext.setShouldAntialias(false)
                cgContext.draw(
                    cgQR,
                    in: CGRect(
                        x: quietPadding,
                        y: quietPadding,
                        width: renderedWidth,
                        height: renderedHeight
                    )
                )
            }
            return true
        }

        return image
    }
}
