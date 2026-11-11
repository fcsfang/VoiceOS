import Foundation

/// The menu bar mark is the letter carved out of the supplied logo tile: the
/// dark ink becomes opaque, the tile background becomes transparent, and the
/// result is cropped to the ink bounds. Kept free of AppKit so the thresholding
/// and cropping can be tested directly.
public enum MenuBarMark {
    public struct Mask: Equatable, Sendable {
        public let width: Int
        public let height: Int
        public let alpha: [UInt8]

        public init(width: Int, height: Int, alpha: [UInt8]) {
            self.width = width
            self.height = height
            self.alpha = alpha
        }
    }

    /// `rgba` must be tightly packed, opaque samples of `width * height` pixels.
    /// Returns nil when no ink survives the threshold.
    public static func derive(rgba: [UInt8], width: Int, height: Int) -> Mask? {
        guard width > 0, height > 0, rgba.count == width * height * 4 else { return nil }
        var alpha = [UInt8](repeating: 0, count: width * height)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * 4
                let luminance = (2126 * Int(rgba[offset]) + 7152 * Int(rgba[offset + 1]) + 722 * Int(rgba[offset + 2])) / 10000
                // Ink is dark and the background is white; the ramp keeps anti-aliased ribbon edges smooth.
                let value: Int
                if luminance <= 90 {
                    value = 255
                } else if luminance >= 160 {
                    value = 0
                } else {
                    value = (160 - luminance) * 255 / 70
                }
                alpha[y * width + x] = UInt8(value)
                if value > 16 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let croppedWidth = maxX - minX + 1
        let croppedHeight = maxY - minY + 1
        var cropped = [UInt8](repeating: 0, count: croppedWidth * croppedHeight)
        for y in 0..<croppedHeight {
            for x in 0..<croppedWidth {
                cropped[y * croppedWidth + x] = alpha[(y + minY) * width + (x + minX)]
            }
        }
        return Mask(width: croppedWidth, height: croppedHeight, alpha: cropped)
    }
}
