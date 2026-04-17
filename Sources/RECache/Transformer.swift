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
/// Use the factories in ``Transformers`` for the common cases:
/// - ``Transformers/data()`` — pass-through for `Data`
/// - ``Transformers/codable(_:format:)`` — any `Codable` value
/// - ``Transformers/image()`` — `UIImage` / `NSImage` (platform-dependent)
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

// MARK: - Transformers factory

/// Built-in `Transformer` factories. Prefer these over hand-rolled closures
/// unless you need a custom on-disk representation.
public enum Transformers {

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

    /// `Codable` transformer with selectable wire format.
    ///
    /// - Parameters:
    ///   - type: The value type (inferred in most call sites).
    ///   - format: ``CodableFormat/json`` (default) or
    ///     ``CodableFormat/binaryPlist``. Pick `.binaryPlist` when the payload
    ///     is dominated by `Data` fields — it avoids base64 and is ~2–3×
    ///     faster in that specific case.
    public static func codable<T: Codable & Sendable>(
        _ type: T.Type = T.self,
        format: CodableFormat = .json
    ) -> Transformer<T> {
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
                    do { return try decoder.decode(T.self, from: data) }
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
                    do { return try decoder.decode(T.self, from: data) }
                    catch { throw CacheError.decodingFailed(error) }
                }
            )
        }
    }
}

// MARK: - Image transformer (platform-dependent)

#if canImport(UIKit)
public extension Transformers {
    /// `UIImage` transformer. Encodes as PNG (preserves alpha); decodes via
    /// `UIImage(data:)`.
    ///
    /// If you need JPEG or a non-default compression quality, build your own
    /// `Transformer<UIImage>` with a custom `encode` closure.
    static func image() -> Transformer<UIImage> {
        Transformer(
            encode: { image in
                guard let data = image.pngData() else {
                    throw CacheError.encodingFailed(
                        NSError(domain: "RECache.Transformer.Image", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "UIImage.pngData() returned nil"])
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
public extension Transformers {
    /// `NSImage` transformer. Encodes as PNG; decodes via `NSImage(data:)`.
    @available(macOS 14.0, *)
    static func image() -> Transformer<NSImage> {
        Transformer(
            encode: { image in
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff),
                      let data = rep.representation(using: .png, properties: [:])
                else {
                    throw CacheError.encodingFailed(
                        NSError(domain: "RECache.Transformer.Image", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "NSImage -> PNG data failed"])
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
