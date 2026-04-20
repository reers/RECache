import Testing
import Foundation
@testable import RECache

#if canImport(AppKit)
import AppKit
import CoreGraphics
#endif

@Suite("Transformer")
struct TransformerTests {

    // MARK: - Data transformer

    @Test func dataRoundtrip() throws {
        let t = Transformer<Data>.data()
        let payload = Data([0x01, 0x02, 0x03, 0x04])
        let encoded = try t.encode(payload)
        let decoded = try t.decode(encoded)
        #expect(encoded == payload)
        #expect(decoded == payload)
    }

    // MARK: - Codable transformer error paths

    struct Sample: Codable, Sendable, Equatable {
        let v: Int
    }

    @Test func codableJSONDecodeFailureWrappedInCacheError() {
        let t = Transformer<Sample>.codable()
        do {
            _ = try t.decode(Data("not json".utf8))
            Issue.record("decode should have thrown")
        } catch let CacheError.decodingFailed(err) {
            #expect(err is DecodingError)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    @Test func codableBinaryPlistDecodeFailureWrappedInCacheError() {
        let t = Transformer<Sample>.codable(format: .binaryPlist)
        do {
            _ = try t.decode(Data("not a plist".utf8))
            Issue.record("decode should have thrown")
        } catch let CacheError.decodingFailed(err) {
            #expect(err is DecodingError)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    // MARK: - NSImage transformer (macOS 14+)

    #if canImport(AppKit)
    @available(macOS 14.0, *)
    @Test func nsImageTransformerPNGRoundtrip() throws {
        let image = Self.makeNSImage(width: 8, height: 8, withAlpha: true)
        let t = Transformer<NSImage>.image()
        let data = try t.encode(image)
        #expect(data.count > 0)
        // PNG header magic.
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        let decoded = try t.decode(data)
        #expect(decoded.size.width > 0)
        #expect(decoded.size.height > 0)
    }

    @available(macOS 14.0, *)
    @Test func nsImageTransformerJPEGRoundtrip() throws {
        let image = Self.makeNSImage(width: 16, height: 16, withAlpha: false)
        let t = Transformer<NSImage>.image(jpegCompressionQuality: 0.8)
        let data = try t.encode(image)
        #expect(data.count > 0)
        // JPEG SOI marker.
        #expect(data.starts(with: [0xFF, 0xD8]))
        let decoded = try t.decode(data)
        #expect(decoded.size.width > 0)
    }

    @available(macOS 14.0, *)
    @Test func nsImageTransformerDecodeGarbageThrows() {
        let t = Transformer<NSImage>.image()
        do {
            _ = try t.decode(Data([0x00, 0x01, 0x02]))
            Issue.record("decode should throw")
        } catch let CacheError.decodingFailed(err) {
            #expect((err as NSError).domain == "RECache.Transformer.Image")
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// Build an NSImage backed by a CGImage so that `cgImage(forProposedRect:...)`
    /// returns a non-nil image inside the transformer. `withAlpha` controls
    /// whether the bitmap carries an alpha channel (driving PNG vs JPEG).
    private static func makeNSImage(width: Int, height: Int, withAlpha: Bool) -> NSImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = withAlpha
            ? CGImageAlphaInfo.premultipliedLast.rawValue
            : CGImageAlphaInfo.noneSkipLast.rawValue
        let bytesPerRow = width * 4
        guard let ctx = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: withAlpha ? 0.5 : 1.0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cg = ctx.makeImage() else {
            return NSImage(size: NSSize(width: width, height: height))
        }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
    #endif
}
