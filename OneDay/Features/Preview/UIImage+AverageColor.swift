import UIKit
import CoreImage

extension UIImage {
    /// Average color of the image via CIAreaAverage (downsampled to 1x1).
    var averageColor: UIColor? {
        guard let cgImage else { return nil }
        let input = CIImage(cgImage: cgImage)
        let extent = CIVector(cgRect: input.extent)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: input,
                                                 kCIInputExtentKey: extent]),
              let output = filter.outputImage else { return nil }

        var bitmap = [UInt8](repeating: 0, count: 4)
        let context = CIContext(options: [.workingColorSpace: NSNull()])
        context.render(output, toBitmap: &bitmap, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())

        return UIColor(red: CGFloat(bitmap[0]) / 255,
                       green: CGFloat(bitmap[1]) / 255,
                       blue: CGFloat(bitmap[2]) / 255,
                       alpha: 1)
    }

    /// The dominant color, only slightly darkened, for preview backgrounds.
    func deepTone() -> UIColor? {
        guard let base = averageColor else { return nil }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard base.getHue(&h, saturation: &s, brightness: &b, alpha: &a) else { return nil }
        return UIColor(hue: h,
                       saturation: min(s, 0.7),
                       brightness: max(min(b * 0.78, 0.6), 0.16),
                       alpha: 1)
    }
}
