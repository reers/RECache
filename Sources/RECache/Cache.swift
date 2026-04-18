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
    //
    // The sync methods below are marked `@available(*, noasync)`: calling them
    // from an async context triggers a warning (or an error under Swift 6 /
    // strict concurrency). Use the `async` overloads with `await` instead.

    /// Returns whether a non-expired entry exists for `key` in either layer.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func contains(_ key: Key) -> Bool {
        memoryCache.contains(key) || diskCache.contains(key)
    }

    /// Returns the value for `key`. Memory is consulted first; a disk hit
    /// repopulates memory.
    @available(*, noasync, message: "Use `await` in async contexts.")
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
    @available(*, noasync, message: "Use `await` in async contexts.")
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
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func remove(forKey key: Key) {
        memoryCache.remove(forKey: key)
        diskCache.remove(forKey: key)
    }

    /// Empties both layers.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func removeAll() {
        memoryCache.removeAll()
        diskCache.removeAll()
    }

    /// Asynchronously empties both layers; reports disk-layer progress through
    /// callbacks.
    ///
    /// Returns immediately; the disk wipe runs on an internal background queue
    /// and delivers callbacks from that queue. Safe to invoke from any context.
    public func asyncRemoveAll(
        progress: (@Sendable (_ removed: Int32, _ total: Int32) -> Void)?,
        completion: (@Sendable (_ error: Bool) -> Void)?
    ) {
        memoryCache.removeAll()
        diskCache.asyncRemoveAll(progress: progress, completion: completion)
    }

    // MARK: - Async API

    /// Async overload of ``contains(_:)``.
    public func contains(_ key: Key) async -> Bool {
        if await memoryCache.contains(key) { return true }
        return await diskCache.contains(key)
    }

    /// Async overload of ``value(forKey:)``.
    public func value(forKey key: Key) async throws -> Value? {
        if let v = await memoryCache.value(forKey: key) { return v }
        guard let v = try await diskCache.value(forKey: key) else { return nil }
        await memoryCache.set(v, forKey: key)
        return v
    }

    /// Async overload of ``set(_:forKey:cost:extendedData:)``.
    public func set(
        _ value: Value?,
        forKey key: Key,
        cost: Int = 0,
        extendedData: Data? = nil
    ) async throws {
        guard let value = value else {
            await remove(forKey: key)
            return
        }
        await memoryCache.set(value, forKey: key, cost: cost)
        try await diskCache.set(value, forKey: key, extendedData: extendedData)
    }

    /// Async overload of ``remove(forKey:)``.
    public func remove(forKey key: Key) async {
        await memoryCache.remove(forKey: key)
        await diskCache.remove(forKey: key)
    }

    /// Async overload of ``removeAll()``.
    public func removeAll() async {
        await memoryCache.removeAll()
        await diskCache.removeAll()
    }
}

// MARK: - CustomStringConvertible

extension Cache: CustomStringConvertible {
    public var description: String {
        let id = ObjectIdentifier(self)
        return "<\(type(of: self)): \(id)> (\(name))"
    }
}
