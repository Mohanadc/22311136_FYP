import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import FYP_22311136

final class ContentViewTests: XCTestCase {
    /// Mirrors the decode check used in ContentView: attempts to create a CGImage from the data.
    private func canDecodeJPEG(_ data: Data) -> Bool {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return false }
        guard CGImageSourceGetCount(src) > 0 else { return false }
        return CGImageSourceCreateImageAtIndex(src, 0, nil) != nil
    }

    /// Create a tiny valid 1x1 JPEG in memory using Image I/O. This avoids relying on an embedded base64 string
    /// that may not round-trip across toolchains.
    private func makeSmallJPEGData() -> Data? {
        let width = 1
        let height = 1
        let bitsPerComponent = 8
        let bytesPerRow = 4 * width
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

        guard let ctx = CGContext(data: nil,
                                  width: width,
                                  height: height,
                                  bitsPerComponent: bitsPerComponent,
                                  bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo.rawValue) else { return nil }

        // Paint a single white pixel
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        guard let cgImage = ctx.makeImage() else { return nil }

        let destData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(destData, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cgImage, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return destData as Data
    }

    func testGeneratedJPEGDecodes() throws {
        let jpegData = try XCTUnwrap(makeSmallJPEGData(), "Could not generate in-memory JPEG data")
        XCTAssertTrue(canDecodeJPEG(jpegData), "Generated JPEG should decode via Image I/O")
    }

    func testInvalidDataDoesNotDecode() {
        let data = Data([0x00, 0x01, 0x02, 0x03, 0x04])
        XCTAssertFalse(canDecodeJPEG(data), "Non-JPEG data should not decode as an image")
    }

    func testMarkerSanityCheck() throws {
        // Build a minimal fake JPEG-like data with SOI and EOI markers but no valid content
        var data = Data([0xFF, 0xD8]) // SOI
        data.append(contentsOf: [UInt8](repeating: 0x00, count: 10))
        data.append(contentsOf: [0xFF, 0xD9]) // EOI

        // Marker check: starts with FF D8 and ends with FF D9
        let bytes = [UInt8](data)
        XCTAssertTrue(bytes.count >= 4 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[bytes.count - 2] == 0xFF && bytes[bytes.count - 1] == 0xD9,
                      "Marker sanity check should pass for synthetic SOI/EOI data")

        // But decoding should fail
        XCTAssertFalse(canDecodeJPEG(data), "Data with only markers should not decode into a real image")
    }
}
