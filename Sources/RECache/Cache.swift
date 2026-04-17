//
//  Copyright © 2015 ibireme.
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

// `@preconcurrency` is required because we expose block-based APIs that pass
// `NSCoding?` values through `@Sendable` async closures. `NSCoding` is an
// `@objc` protocol that does not conform to `Sendable`, yet the common concrete
// implementations (`NSString`, `NSNumber`, `NSData`, ...) are effectively
// immutable value types and are safe to hand off across threads in practice.
// Removal plan: drop once all public APIs either become `async`, take only
// `Sendable` payloads, or Foundation's `NSCoding` gains `Sendable` conformance.
@preconcurrency import Foundation

// MARK: - NSCoding Box

/// A Sendable wrapper around `any NSCoding`.
///
/// `MemoryCache` requires its `Value` type to conform to `Sendable`, but the
/// `any NSCoding` existential does not. Wrapping the value in this box lets us
/// use `MemoryCache<String, NSCodingBox>` as the underlying memory layer of
/// `Cache`.
///
/// Safety invariant: the wrapped value is never mutated through this box and
/// the common `NSCoding` concrete types (`NSString`, `NSNumber`, `NSData`,
/// ...) are effectively immutable value-semantic types that are safe to hand
/// off across threads in practice.
public struct NSCodingBox: @unchecked Sendable {

    /// The underlying `NSCoding` value.
    public let value: any NSCoding

    /// Create a box that wraps an `NSCoding` value.
    ///
    /// - Parameter value: The value to wrap.
    public init(_ value: any NSCoding) {
        self.value = value
    }
}

// MARK: - Cache

/// `Cache` is a thread safe key-value cache.
///
/// It uses `MemoryCache` to store objects in a small and fast memory cache,
/// and uses `DiskCache` to persist objects to a large and slow disk cache.
/// See `MemoryCache` and `DiskCache` for more information.
///
/// Concurrency:
/// `@unchecked Sendable` is required because the class holds non-`Sendable`
/// stored properties (`memoryCache`'s boxed `NSCoding` values). Safety is
/// provided by the underlying `MemoryCache` / `DiskCache`, both of which
/// serialize access internally.
///
/// Removal plan: revisit once the public, synchronous Objective-C–style API
/// can be replaced by an `actor`-based, `async` surface. A direct `actor`
/// migration would force every caller to `await`, breaking 1:1 compatibility
/// with `YYCache`; keep `@unchecked Sendable` until that trade-off is
/// acceptable.
public final class Cache: @unchecked Sendable {

    // MARK: - Properties

    /// The name of the cache, read-only.
    public let name: String

    /// The underlying memory cache. See `MemoryCache` for more information.
    public let memoryCache: MemoryCache<String, NSCodingBox>

    /// The underlying disk cache. See `DiskCache` for more information.
    public let diskCache: DiskCache

    // MARK: - Initializer

    /// Create a new instance with the specified name.
    /// Multiple instances with the same name will make the cache unstable.
    ///
    /// - Parameter name: The name of the cache. It will create a dictionary
    ///   with the name in the app's caches dictionary for disk cache. Once
    ///   initialized you should not read and write to this directory.
    public convenience init?(name: String) {
        if name.isEmpty { return nil }
        let cacheFolder = NSSearchPathForDirectoriesInDomains(
            .cachesDirectory,
            .userDomainMask,
            true
        ).first ?? ""
        let path = (cacheFolder as NSString).appendingPathComponent(name)
        self.init(path: path)
    }

    /// The designated initializer. Create a new instance with the specified path.
    /// Multiple instances with the same name will make the cache unstable.
    ///
    /// - Parameter path: Full path of a directory in which the cache will write
    ///   data. Once initialized you should not read and write to this directory.
    public init?(path: String) {
        if path.isEmpty { return nil }
        guard let diskCache = DiskCache(path: path) else { return nil }

        let name = (path as NSString).lastPathComponent
        let memoryCache = MemoryCache<String, NSCodingBox>()
        memoryCache.name = name

        self.name = name
        self.diskCache = diskCache
        self.memoryCache = memoryCache
    }

    // MARK: - Access Methods

    /// Returns a boolean value that indicates whether a given key is in cache.
    /// This method may blocks the calling thread until file read finished.
    ///
    /// - Parameter key: A string identifying the value. If empty, just return `false`.
    /// - Returns: Whether the key is in cache.
    public func containsObject(forKey key: String) -> Bool {
        return memoryCache.containsObject(forKey: key) || diskCache.containsObject(forKey: key)
    }

    /// Returns a boolean value with the block that indicates whether a given key is in cache.
    /// This method returns immediately and invoke the passed block in background queue
    /// when the operation finished.
    ///
    /// - Parameters:
    ///   - key: A string identifying the value. If empty, just return `false`.
    ///   - block: A block which will be invoked in background queue when finished.
    public func containsObject(
        forKey key: String,
        block: (@Sendable (_ key: String, _ contains: Bool) -> Void)?
    ) {
        guard let block = block else { return }

        if memoryCache.containsObject(forKey: key) {
            DispatchQueue.global(qos: .default).async {
                block(key, true)
            }
        } else {
            diskCache.containsObject(forKey: key, block: block)
        }
    }

    /// Returns the value associated with a given key.
    /// This method may blocks the calling thread until file read finished.
    ///
    /// - Parameter key: A string identifying the value. If empty, just return nil.
    /// - Returns: The value associated with key, or nil if no value is associated with key.
    public func object(forKey key: String) -> NSCoding? {
        if let box = memoryCache.object(forKey: key) {
            return box.value
        }
        if let object = diskCache.object(forKey: key) {
            memoryCache.setObject(NSCodingBox(object), forKey: key)
            return object
        }
        return nil
    }

    /// Returns the value associated with a given key.
    /// This method returns immediately and invoke the passed block in background queue
    /// when the operation finished.
    ///
    /// - Parameters:
    ///   - key: A string identifying the value. If empty, just return nil.
    ///   - block: A block which will be invoked in background queue when finished.
    public func object(
        forKey key: String,
        block: (@Sendable (_ key: String, _ object: NSCoding?) -> Void)?
    ) {
        guard let block = block else { return }

        if let box = memoryCache.object(forKey: key) {
            DispatchQueue.global(qos: .default).async {
                block(key, box.value)
            }
        } else {
            diskCache.object(forKey: key) { [weak self] key, object in
                if let self, let object, self.memoryCache.object(forKey: key) == nil {
                    self.memoryCache.setObject(NSCodingBox(object), forKey: key)
                }
                block(key, object)
            }
        }
    }

    /// Sets the value of the specified key in the cache.
    /// This method may blocks the calling thread until file write finished.
    ///
    /// - Parameters:
    ///   - object: The object to be stored in the cache. If nil, it calls
    ///     `removeObject(forKey:)`.
    ///   - key: The key with which to associate the value. If empty, this
    ///     method has no effect.
    public func setObject(_ object: NSCoding?, forKey key: String) {
        if let object = object {
            memoryCache.setObject(NSCodingBox(object), forKey: key)
        } else {
            memoryCache.removeObject(forKey: key)
        }
        diskCache.setObject(object, forKey: key)
    }

    /// Sets the value of the specified key in the cache.
    /// This method returns immediately and invoke the passed block in background queue
    /// when the operation finished.
    ///
    /// - Parameters:
    ///   - object: The object to be stored in the cache. If nil, it calls
    ///     `removeObject(forKey:)`.
    ///   - key: The key with which to associate the value. If empty, this
    ///     method has no effect.
    ///   - block: A block which will be invoked in background queue when finished.
    public func setObject(
        _ object: NSCoding?,
        forKey key: String,
        block: (@Sendable () -> Void)?
    ) {
        if let object = object {
            memoryCache.setObject(NSCodingBox(object), forKey: key)
        } else {
            memoryCache.removeObject(forKey: key)
        }
        diskCache.setObject(object, forKey: key, block: block)
    }

    /// Removes the value of the specified key in the cache.
    /// This method may blocks the calling thread until file delete finished.
    ///
    /// - Parameter key: The key identifying the value to be removed. If empty,
    ///   this method has no effect.
    public func removeObject(forKey key: String) {
        memoryCache.removeObject(forKey: key)
        diskCache.removeObject(forKey: key)
    }

    /// Removes the value of the specified key in the cache.
    /// This method returns immediately and invoke the passed block in background queue
    /// when the operation finished.
    ///
    /// - Parameters:
    ///   - key: The key identifying the value to be removed. If empty, this
    ///     method has no effect.
    ///   - block: A block which will be invoked in background queue when finished.
    public func removeObject(
        forKey key: String,
        block: (@Sendable (_ key: String) -> Void)?
    ) {
        memoryCache.removeObject(forKey: key)
        diskCache.removeObject(forKey: key, block: block)
    }

    /// Empties the cache.
    /// This method may blocks the calling thread until file delete finished.
    public func removeAllObjects() {
        memoryCache.removeAllObjects()
        diskCache.removeAllObjects()
    }

    /// Empties the cache.
    /// This method returns immediately and invoke the passed block in background queue
    /// when the operation finished.
    ///
    /// - Parameter block: A block which will be invoked in background queue when finished.
    public func removeAllObjects(block: (@Sendable () -> Void)?) {
        memoryCache.removeAllObjects()
        diskCache.removeAllObjects(block: block)
    }

    /// Empties the cache with block.
    /// This method returns immediately and executes the clear operation with block in background.
    ///
    /// - Parameters:
    ///   - progress: This block will be invoked during removing, pass nil to ignore.
    ///   - end: This block will be invoked at the end, pass nil to ignore.
    /// - Warning: You should not send message to this instance in these blocks.
    public func removeAllObjects(
        progress: (@Sendable (_ removedCount: Int32, _ totalCount: Int32) -> Void)?,
        end: (@Sendable (_ error: Bool) -> Void)?
    ) {
        memoryCache.removeAllObjects()
        diskCache.removeAllObjects(progress: progress, end: end)
    }
}

// MARK: - CustomStringConvertible

extension Cache: CustomStringConvertible {
    public var description: String {
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        return "<\(type(of: self)): \(ptr)> (\(name))"
    }
}
