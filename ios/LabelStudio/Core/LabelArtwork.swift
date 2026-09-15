import UIKit

struct LabelArtwork {
    static let width = 400
    static let height = 300
    static let colors: [(UInt8, UInt8, UInt8)] = [(0,0,0), (255,255,255), (255,255,0), (255,0,0)]
    let image: UIImage
    let frame: Data

    /// Normalize orientation, fit without cropping, flatten transparency and enforce the physical palette.
    static func render(_ source: UIImage) throws -> LabelArtwork {
        guard source.size.width > 0, source.size.height > 0,
              source.size.width * source.size.height <= 80_000_000 else { throw ArtworkError.invalidImage }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let fitted = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let ratio = min(CGFloat(width) / source.size.width, CGFloat(height) / source.size.height)
            let size = CGSize(width: source.size.width * ratio, height: source.size.height * ratio)
            source.draw(in: CGRect(x: (CGFloat(width)-size.width)/2, y: (CGFloat(height)-size.height)/2, width: size.width, height: size.height))
        }
        guard let cg = fitted.cgImage else { throw ArtworkError.invalidImage }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let bitmap = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmap) else { throw ArtworkError.invalidImage }
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var packed = [UInt8](repeating: 0, count: width * height / 4)
        for pixel in 0..<(width * height) {
            let offset = pixel * 4
            let code = nearestColor(red: rgba[offset], green: rgba[offset+1], blue: rgba[offset+2])
            packed[pixel/4] |= UInt8(code) << (6 - 2 * (pixel % 4))
            let color = colors[code]
            rgba[offset] = color.0; rgba[offset+1] = color.1; rgba[offset+2] = color.2; rgba[offset+3] = 255
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let preview = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                    bytesPerRow: width*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: bitmap),
                                    provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ArtworkError.invalidImage }
        return LabelArtwork(image: UIImage(cgImage: preview), frame: Data(packed))
    }

    static func nearestColor(red: UInt8, green: UInt8, blue: UInt8) -> Int {
        colors.indices.min { a, b in
            func distance(_ index: Int) -> Int {
                let c = colors[index]
                let r = Int(red)-Int(c.0), g = Int(green)-Int(c.1), b = Int(blue)-Int(c.2)
                return r*r + g*g + b*b
            }
            return distance(a) < distance(b)
        }!
    }
}

enum ArtworkError: LocalizedError {
    case invalidImage
    var errorDescription: String? { "This image could not be prepared. Choose a smaller PNG or JPEG and try again." }
}
