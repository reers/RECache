//
//  Copyright © 2025 reers.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Converts a cache `Value` to and from `Data` for disk persistence.
///
/// `MemoryCache` stores values directly and does **not** need a transformer.
/// `DiskCache` requires a transformer to serialize values to the SQLite
/// blob / file store and to deserialize them back.
///
/// Built-in factories live as `static` members on `Transformer` itself and
/// are selected via the value type of the surrounding context:
/// - ``Transformer/data()`` — pass-through for `Data`
/// - ``Transformer/codable(format:)`` — any `Codable` value
/// - ``Transformer/image()`` — `UIImage` / `NSImage` (platform-dependent)
///
/// Thanks to Swift's leading-dot syntax, call sites typically read as
/// `transformer: .codable()` / `.data()` / `.image()`.
public struct Transformer<Value: Sendable>: Sendable {
    /// Encode a value to `Data`. Throw to signal encoding failure.
    public let encode: @Sendable (Value) throws -> Data

    /// Decode `Data` back into a value. Throw to signal decoding failure.
    public let decode: @Sendable (Data) throws -> Value

    public init(
        encode: @escaping @Sendable (Value) throws -> Data,
        decode: @escaping @Sendable (Data) throws -> Value
    ) {
        self.encode = encode
        self.decode = decode
    }
}

// MARK: - CodableFormat

/// Wire format used by the built-in `Codable` transformer.
///
/// Benchmarks on modern Apple platforms (2026, Apple Silicon) show that
/// `JSONEncoder`/`JSONDecoder` — which were rewritten in pure Swift — are
/// generally faster than `PropertyListEncoder`/`PropertyListDecoder` for
/// pure text/number payloads. Binary plist still wins decisively when the
/// payload carries `Data` fields (no base64 overhead).
///
/// Default: ``CodableFormat/json``.
public enum CodableFormat: Sendable {
    case json
    case binaryPlist
}

// MARK: - Data

extension Transformer where Value == Data {
    /// Identity transformer for raw `Data` values.
    ///
    /// Zero encoding overhead — useful for caching prebuilt payloads
    /// (compressed blobs, pre-rendered JSON, binary protocol messages).
    public static func data() -> Transformer<Data> {
        Transformer(
            encode: { $0 },
            decode: { $0 }
        )
    }
}

// MARK: - Codable

extension Transformer where Value: Codable {
    /// `Codable` transformer with selectable wire format.
    ///
    /// - Parameter format: ``CodableFormat/json`` (default) or
    ///   ``CodableFormat/binaryPlist``. Pick `.binaryPlist` when the payload
    ///   is dominated by `Data` fields — it avoids base64 and is ~2–3×
    ///   faster in that specific case.
    public static func codable(format: CodableFormat = .json) -> Transformer<Value> {
        switch format {
        case .json:
            return Transformer(
                encode: { value in
                    let encoder = JSONEncoder()
                    encoder.dateEncodingStrategy = .iso8601
                    encoder.dataEncodingStrategy = .base64
                    do { return try encoder.encode(value) }
                    catch { throw CacheError.encodingFailed(error) }
                },
                decode: { data in
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    decoder.dataDecodingStrategy = .base64
                    do { return try decoder.decode(Value.self, from: data) }
                    catch { throw CacheError.decodingFailed(error) }
                }
            )
        case .binaryPlist:
            return Transformer(
                encode: { value in
                    let encoder = PropertyListEncoder()
                    encoder.outputFormat = .binary
                    do { return try encoder.encode(value) }
                    catch { throw CacheError.encodingFailed(error) }
                },
                decode: { data in
                    let decoder = PropertyListDecoder()
                    do { return try decoder.decode(Value.self, from: data) }
                    catch { throw CacheError.decodingFailed(error) }
                }
            )
        }
    }
}

// MARK: - Image (platform-dependent)

#if canImport(UIKit) || canImport(AppKit)
import CoreGraphics

/// Reads `CGImage.alphaInfo` to determine whether the pixel buffer actually
/// carries alpha. Matches the test used by Kingfisher / SDWebImage.
private func cgImageHasAlpha(_ cgImage: CGImage?) -> Bool {
    guard let alphaInfo = cgImage?.alphaInfo else { return false }
    switch alphaInfo {
    case .none, .noneSkipLast, .noneSkipFirst:
        return false
    default:
        return true
    }
}
#endif

#if canImport(UIKit)
extension Transformer where Value == UIImage {
    /// `UIImage` transformer with alpha-aware encoding:
    ///
    /// - images **with** an alpha channel are encoded as **PNG** (preserves
    ///   transparency, lossless);
    /// - images **without** alpha (typical photos) are encoded as **JPEG**
    ///   (much smaller on disk at the same visual quality).
    ///
    /// This mirrors the defaults used by Kingfisher's `DefaultCacheSerializer`
    /// and SDWebImage.
    ///
    /// Decodes via `UIImage(data:)`.
    ///
    /// - Parameter jpegCompressionQuality: JPEG quality in `[0.0, 1.0]`,
    ///   applied only when the source image has no alpha. Default: `1.0`
    ///   (visually lossless, largest file). Drop to `0.85`–`0.9` for a
    ///   ~3–5× size reduction with barely perceptible loss.
    public static func image(jpegCompressionQuality: CGFloat = 1.0) -> Transformer<UIImage> {
        Transformer(
            encode: { image in
                let hasAlpha = cgImageHasAlpha(image.cgImage)
                let data: Data? = hasAlpha
                    ? image.pngData()
                    : image.jpegData(compressionQuality: jpegCompressionQuality)
                guard let data else {
                    throw CacheError.encodingFailed(
                        NSError(domain: "RECache.Transformer.Image", code: -1,
                                userInfo: [NSLocalizedDescriptionKey:
                                    "UIImage -> \(hasAlpha ? "PNG" : "JPEG") data failed"])
                    )
                }
                return data
            },
            decode: { data in
                guard let image = UIImage(data: data) else {
                    throw CacheError.decodingFailed(
                        NSError(domain: "RECache.Transformer.Image", code: -2,
                                userInfo: [NSLocalizedDescriptionKey: "UIImage(data:) returned nil"])
                    )
                }
                return image
            }
        )
    }
}
#elseif canImport(AppKit)
extension Transformer where Value == NSImage {
    /// `NSImage` transformer with alpha-aware encoding:
    ///
    /// - images **with** an alpha channel are encoded as **PNG**;
    /// - images **without** alpha are encoded as **JPEG**.
    ///
    /// Decodes via `NSImage(data:)`.
    ///
    /// - Parameter jpegCompressionQuality: JPEG quality in `[0.0, 1.0]`,
    ///   applied only when the source image has no alpha. Default: `1.0`.
    ///
    /// - Note: `@available(macOS 14.0, *)` because `NSImage`'s `Sendable`
    ///   conformance (required by `Transformer`) only ships in macOS 14+.
    @available(macOS 14.0, *)
    public static func image(jpegCompressionQuality: CGFloat = 1.0) -> Transformer<NSImage> {
        Transformer(
            encode: { image in
                let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
                let hasAlpha = cgImageHasAlpha(cgImage)
                let data: Data?
                if let cgImage {
                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    if hasAlpha {
                        data = rep.representation(using: .png, properties: [:])
                    } else {
                        data = rep.representation(
                            using: .jpeg,
                            properties: [.compressionFactor: jpegCompressionQuality]
                        )
                    }
                } else {
                    data = nil
                }
                guard let data else {
                    throw CacheError.encodingFailed(
                        NSError(domain: "RECache.Transformer.Image", code: -1,
                                userInfo: [NSLocalizedDescriptionKey:
                                    "NSImage -> \(hasAlpha ? "PNG" : "JPEG") data failed"])
                    )
                }
                return data
            },
            decode: { data in
                guard let image = NSImage(data: data) else {
                    throw CacheError.decodingFailed(
                        NSError(domain: "RECache.Transformer.Image", code: -2,
                                userInfo: [NSLocalizedDescriptionKey: "NSImage(data:) returned nil"])
                    )
                }
                return image
            }
        )
    }
}
#endif
