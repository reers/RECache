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

import Foundation

/// A generic, thread-safe, two-tier (memory + disk) cache.
///
/// `Cache` delegates to ``memoryCache`` and ``diskCache``, serving reads from
/// memory first and repopulating memory on disk hits. Both layers share the
/// same `Key` / `Value` and the same ``Transformer``.
///
/// ### Concurrency
/// `@unchecked Sendable`: the class holds two `@unchecked Sendable` sub-caches
/// (``MemoryCache`` / ``DiskCache``), each serialized internally. No
/// additional mutable state lives on this type.
public final class Cache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {

    /// The name of the cache (read-only).
    public let name: String

    /// The memory layer.
    public let memoryCache: MemoryCache<Key, Value>

    /// The disk layer.
    public let diskCache: DiskCache<Key, Value>

    // MARK: - Init

    /// Creates a cache named `name` under the user's caches directory.
    ///
    /// - Parameters:
    ///   - name: Directory name for the disk layer. Must be non-empty.
    ///   - transformer: Value serializer shared by the disk layer.
    public convenience init?(name: String, transformer: Transformer<Value>) {
        if name.isEmpty { return nil }
        let caches = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true).first ?? ""
        let path = (caches as NSString).appendingPathComponent(name)
        self.init(path: path, transformer: transformer)
    }

    /// Creates a cache at `path`.
    ///
    /// - Parameters:
    ///   - path: Absolute directory path for the disk layer.
    ///   - transformer: Value serializer shared by the disk layer.
    public init?(path: String, transformer: Transformer<Value>) {
        if path.isEmpty { return nil }
        guard let diskCache = DiskCache<Key, Value>(path: path, transformer: transformer) else { return nil }

        let name = (path as NSString).lastPathComponent
        let memoryCache = MemoryCache<Key, Value>()
        memoryCache.name = name

        self.name = name
        self.diskCache = diskCache
        self.memoryCache = memoryCache
    }

    // MARK: - Sync API

    /// Returns whether a non-expired entry exists for `key` in either layer.
    public func contains(_ key: Key) -> Bool {
        memoryCache.contains(key) || diskCache.contains(key)
    }

    /// Returns the value for `key`. Memory is consulted first; a disk hit
    /// repopulates memory.
    public func value(forKey key: Key) throws -> Value? {
        if let v = memoryCache.value(forKey: key) { return v }
        guard let v = try diskCache.value(forKey: key) else { return nil }
        memoryCache.set(v, forKey: key)
        return v
    }

    /// Stores `value` in both layers.
    ///
    /// - Parameters:
    ///   - value: Pass `nil` to remove.
    ///   - key: Key.
    ///   - cost: Cost for the memory layer.
    ///   - extendedData: Extra metadata persisted only by the disk layer.
    /// - Throws: Transformer / disk write errors bubble up.
    public func set(
        _ value: Value?,
        forKey key: Key,
        cost: Int = 0,
        extendedData: Data? = nil
    ) throws {
        guard let value = value else {
            remove(forKey: key)
            return
        }
        memoryCache.set(value, forKey: key, cost: cost)
        try diskCache.set(value, forKey: key, extendedData: extendedData)
    }

    /// Returns the disk-layer extended data for `key`, or `nil`.
    public func extendedData(forKey key: Key) -> Data? {
        diskCache.extendedData(forKey: key)
    }

    /// Removes `key` from both layers.
    public func remove(forKey key: Key) {
        memoryCache.remove(forKey: key)
        diskCache.remove(forKey: key)
    }

    /// Empties both layers.
    public func removeAll() {
        memoryCache.removeAll()
        diskCache.removeAll()
    }

    /// Empties both layers; reports disk-layer progress.
    public func removeAll(
        progress: (@Sendable (_ removed: Int32, _ total: Int32) -> Void)?,
        completion: (@Sendable (_ error: Bool) -> Void)?
    ) {
        memoryCache.removeAll()
        diskCache.removeAll(progress: progress, completion: completion)
    }

    // MARK: - Async API

    public func asyncContains(_ key: Key) async -> Bool {
        if memoryCache.contains(key) { return true }
        return await diskCache.asyncContains(key)
    }

    public func asyncValue(forKey key: Key) async throws -> Value? {
        if let v = memoryCache.value(forKey: key) { return v }
        guard let v = try await diskCache.asyncValue(forKey: key) else { return nil }
        await memoryCache.asyncSet(v, forKey: key)
        return v
    }

    public func asyncSet(
        _ value: Value?,
        forKey key: Key,
        cost: Int = 0,
        extendedData: Data? = nil
    ) async throws {
        guard let value = value else {
            await asyncRemove(forKey: key)
            return
        }
        await memoryCache.asyncSet(value, forKey: key, cost: cost)
        try await diskCache.asyncSet(value, forKey: key, extendedData: extendedData)
    }

    public func asyncRemove(forKey key: Key) async {
        await memoryCache.asyncRemove(forKey: key)
        await diskCache.asyncRemove(forKey: key)
    }

    public func asyncRemoveAll() async {
        await memoryCache.asyncRemoveAll()
        await diskCache.asyncRemoveAll()
    }
}

// MARK: - CustomStringConvertible

extension Cache: CustomStringConvertible {
    public var description: String {
        let id = ObjectIdentifier(self)
        return "<\(type(of: self)): \(id)> (\(name))"
    }
}
