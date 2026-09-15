import UIKit
import XCTest
@testable import LabelStudio

final class ArtworkTests: XCTestCase {
    private func fixture(size: CGSize = CGSize(width: 400, height: 300),
                         draw: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: draw)
    }

    private func quadrants() -> UIImage {
        fixture { context in
            for (color, rect) in [
                (UIColor.black, CGRect(x: 0, y: 0, width: 200, height: 150)),
                (UIColor.white, CGRect(x: 200, y: 0, width: 200, height: 150)),
                (UIColor.yellow, CGRect(x: 0, y: 150, width: 200, height: 150)),
                (UIColor.red, CGRect(x: 200, y: 150, width: 200, height: 150))
            ] {
                color.setFill()
                context.fill(rect)
            }
        }
    }

    private func pixel(_ frame: Data, x: Int, y: Int) -> UInt8 {
        let index = y * 400 + x
        return (frame[index / 4] >> (6 - (index % 4) * 2)) & 3
    }

    func testFourQuadrantsMatchEntireIndependentWireFrameAndPreview() throws {
        let artwork = try LabelArtwork.render(quadrants())
        XCTAssertEqual(artwork.image.size, CGSize(width: 400, height: 300))
        XCTAssertEqual(artwork.image.scale, 1)
        XCTAssertEqual(artwork.image.imageOrientation, .up)
        XCTAssertEqual(artwork.frame.count, 30_000)

        // A full byte is four equal pixels. This fixture does not use the
        // production palette, quantizer, or packing algorithm to form expected bytes.
        let topRow = Data(repeating: 0x00, count: 50) + Data(repeating: 0x55, count: 50)
        let bottomRow = Data(repeating: 0xAA, count: 50) + Data(repeating: 0xFF, count: 50)
        var expected = Data()
        for _ in 0..<150 { expected.append(topRow) }
        for _ in 0..<150 { expected.append(bottomRow) }
        XCTAssertEqual(artwork.frame, expected)

        let cgImage = try XCTUnwrap(artwork.image.cgImage)
        XCTAssertEqual(cgImage.width, 400)
        XCTAssertEqual(cgImage.height, 300)
        XCTAssertEqual(cgImage.bitsPerPixel, 32)
        let providerData = try XCTUnwrap(cgImage.dataProvider?.data)
        let rgba = providerData as Data
        let expectedPalette: [[UInt8]] = [[0, 0, 0, 255], [255, 255, 255, 255],
                                          [255, 255, 0, 255], [255, 0, 0, 255]]
        for y in 0..<300 {
            for x in 0..<400 {
                let start = y * cgImage.bytesPerRow + x * 4
                let expectedCode = y < 150 ? (x < 200 ? 0 : 1) : (x < 200 ? 2 : 3)
                guard Array(rgba[start..<(start + 4)]) == expectedPalette[expectedCode] else {
                    return XCTFail("Preview palette or orientation differs at (\(x), \(y))")
                }
            }
        }
    }

    func testWirePixelsAreMostSignificantPairFirst() throws {
        let stripes = fixture { context in
            let colors: [UIColor] = [.black, .white, .yellow, .red]
            for x in 0..<400 {
                colors[x % 4].setFill()
                context.fill(CGRect(x: x, y: 0, width: 1, height: 300))
            }
        }
        let artwork = try LabelArtwork.render(stripes)
        // Black=00, white=01, yellow=10, red=11 => 00011011.
        XCTAssertEqual(artwork.frame, Data(repeating: 0x1B, count: 30_000))
    }

    func testSourceMirroringAndRotationAreNormalizedBeforePacking() throws {
        let source = try XCTUnwrap(quadrants().cgImage)
        let mirrored = try LabelArtwork.render(UIImage(cgImage: source, scale: 1, orientation: .upMirrored))
        XCTAssertEqual(pixel(mirrored.frame, x: 20, y: 20), 1)
        XCTAssertEqual(pixel(mirrored.frame, x: 380, y: 20), 0)
        XCTAssertEqual(pixel(mirrored.frame, x: 20, y: 280), 3)
        XCTAssertEqual(pixel(mirrored.frame, x: 380, y: 280), 2)

        let rotated = try LabelArtwork.render(UIImage(cgImage: source, scale: 1, orientation: .down))
        XCTAssertEqual(pixel(rotated.frame, x: 20, y: 20), 3)
        XCTAssertEqual(pixel(rotated.frame, x: 380, y: 20), 2)
        XCTAssertEqual(pixel(rotated.frame, x: 20, y: 280), 1)
        XCTAssertEqual(pixel(rotated.frame, x: 380, y: 280), 0)
    }

    func testTransparencyIsFlattenedOntoWhite() throws {
        let source = fixture { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 100, y: 100, width: 200, height: 100))
        }
        let artwork = try LabelArtwork.render(source)
        for (x, y) in [(0, 0), (399, 299), (50, 150), (350, 150)] {
            XCTAssertEqual(pixel(artwork.frame, x: x, y: y), 1)
        }
        XCTAssertEqual(pixel(artwork.frame, x: 200, y: 150), 0)
    }

    func testAspectRatioIsPreservedWithWhiteLetterboxing() throws {
        let source = fixture(size: CGSize(width: 200, height: 100)) { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        let artwork = try LabelArtwork.render(source)
        let whiteRow = Data(repeating: 0x55, count: 100)
        let redRow = Data(repeating: 0xFF, count: 100)
        var expected = Data()
        for _ in 0..<50 { expected.append(whiteRow) }
        for _ in 0..<200 { expected.append(redRow) }
        for _ in 0..<50 { expected.append(whiteRow) }
        XCTAssertEqual(artwork.frame, expected)
    }

    func testNonPaletteColorsAreQuantizedAndEmptyImageRejected() throws {
        let samples: [(UIColor, UInt8)] = [
            (UIColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1), 0),
            (UIColor(red: 0.92, green: 0.92, blue: 0.92, alpha: 1), 1),
            (UIColor(red: 0.92, green: 0.90, blue: 0.08, alpha: 1), 2),
            (UIColor(red: 0.90, green: 0.08, blue: 0.08, alpha: 1), 3)
        ]
        for (color, expected) in samples {
            let image = fixture(size: CGSize(width: 4, height: 3)) { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
            }
            let artwork = try LabelArtwork.render(image)
            XCTAssertEqual(pixel(artwork.frame, x: 200, y: 150), expected)
        }
        XCTAssertThrowsError(try LabelArtwork.render(UIImage())) { error in
            guard case ArtworkError.invalidImage = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }

    func testLiveGeneratedImageUsesProductionRendererAndProducesStableDisplayFrame() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "live-label-generated", withExtension: "png"))
        let sourceData = try Data(contentsOf: url)
        let source = try XCTUnwrap(UIImage(data: sourceData))
        XCTAssertEqual(source.cgImage?.width, 1_024)
        XCTAssertEqual(source.cgImage?.height, 768)

        // This is the real, approved image-generation result, not a synthetic
        // fixture or a second implementation of the native renderer.
        let artwork = try LabelArtwork.render(source)
        XCTAssertEqual(artwork.image.size, CGSize(width: 400, height: 300))
        XCTAssertEqual(artwork.frame.count, 30_000)
        let preview = try XCTUnwrap(artwork.image.cgImage)
        XCTAssertEqual(preview.bitsPerPixel, 32)
        let rgba = try XCTUnwrap(preview.dataProvider?.data) as Data
        let palette: [[UInt8]] = [[0, 0, 0, 255], [255, 255, 255, 255],
                                  [255, 255, 0, 255], [255, 0, 0, 255]]
        var colorCounts = [Int](repeating: 0, count: 4)
        for y in 0..<300 {
            for x in 0..<400 {
                let code = Int(pixel(artwork.frame, x: x, y: y))
                let offset = y * preview.bytesPerRow + x * 4
                guard Array(rgba[offset..<(offset + 4)]) == palette[code] else {
                    return XCTFail("Packed frame differs from the opaque four-colour preview at (\(x), \(y))")
                }
                colorCounts[code] += 1
            }
        }
        XCTAssertEqual(colorCounts.reduce(0, +), 120_000)
        XCTAssertTrue(colorCounts.allSatisfy { $0 > 100 }, "The source contains substantial regions of all four colours")

        XCTAssertEqual(try LabelArtwork.render(artwork.image).frame, artwork.frame)
        let png = try XCTUnwrap(artwork.image.pngData())
        let reopened = try XCTUnwrap(UIImage(data: png))
        XCTAssertEqual(try LabelArtwork.render(reopened).frame, artwork.frame, "Saving and reopening a design must retain its exact display bytes")

        let pngAttachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        pngAttachment.name = "generated-preview.png"
        pngAttachment.lifetime = .keepAlways
        add(pngAttachment)
        let frameAttachment = XCTAttachment(data: artwork.frame, uniformTypeIdentifier: "public.data")
        frameAttachment.name = "generated-preview.frame"
        frameAttachment.lifetime = .keepAlways
        add(frameAttachment)
        let summary = XCTAttachment(string: "Source: 1024 × 768; output: 400 × 300; frame: 30000 bytes; pixel counts black/white/yellow/red: \(colorCounts). Native image and PNG round trips preserved every frame byte.")
        summary.name = "generated-preview-validation.txt"
        summary.lifetime = .keepAlways
        add(summary)
    }
}
