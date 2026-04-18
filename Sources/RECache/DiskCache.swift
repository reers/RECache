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
import CryptoKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Free disk space helper

private func diskSpaceFree() -> Int64 {
    do {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        guard let size = attrs[.systemFreeSize] as? NSNumber else { return -1 }
        let space = size.int64Value
        return space < 0 ? -1 : space
    } catch {
        return -1
    }
}

/// MD5 hash of a string. Used only as a stable filename; not security-sensitive.
private func stringMD5(_ string: String) -> String {
    let digest = Insecure.MD5.hash(data: Data(string.utf8))
    return digest.reduce(into: "") { $0 += String(format: "%02x", $1) }
}

// MARK: - DiskCache

/// `DiskCache` is a thread-safe, generic, LRU cache backed by SQLite + the
/// file system (the same dual-storage scheme pioneered by `YYDiskCache`:
/// small blobs live in SQLite, large blobs spill to standalone files).
///
/// Values are serialized via a user-supplied ``Transformer``.
///
/// ### Concurrency
/// `@unchecked Sendable`: all access to the underlying `KVStorage` is
/// serialized by ``lock`` (a `DispatchSemaphore`). Mutable public properties
/// follow the YYCache "configure once, use after" convention — concurrent
/// mutation from multiple threads is not supported.
public final class DiskCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {

    // MARK: - Attribute

    /// The name of the cache. Default: `nil`.
    public var name: String?

    /// The path of the cache directory (read-only).
    public let path: String

    /// Values larger than this (in bytes, after transformer encoding) are
    /// stored as standalone files; smaller values live inline in SQLite.
    ///
    /// `0` → always file; `UInt.max` → always SQLite.
    /// Default: `20480` (20KB).
    public let inlineThreshold: UInt

    /// Value serializer. Set at init and never changed.
    public let transformer: Transformer<Value>

    /// Custom filename for a given key. If `nil`, `md5(String(describing: key))`
    /// is used. Default: `nil`.
    public var fileNameProvider: (@Sendable (Key) -> String)?

    // MARK: - Limits

    /// Maximum number of entries. Default: `Int.max`. Soft limit.
    public var countLimit: Int = .max

    /// Maximum total cost (bytes on disk). Default: `Int.max`. Soft limit.
    public var costLimit: Int = .max

    /// Expiration policy applied to all entries. Evaluated at read time against
    /// each entry's last write time (second-level precision from
    /// `KVStorage.modTime`). Default: ``Expiration/never``.
    public var expiration: Expiration = .never

    /// The cache will evict until free disk space is at or above this
    /// threshold (bytes). `0` means no such limit. Default: `0`.
    public var freeDiskSpaceLimit: UInt64 = 0

    /// Auto-trim check interval in seconds. Default: `60`.
    public var autoTrimInterval: TimeInterval = 60

    /// If `true`, KVStorage prints error logs. Default: `false`.
    public var isLoggingEnabled: Bool {
        get {
            lock.wait()
            defer { lock.signal() }
            return kv?.errorLogsEnabled ?? false
        }
        set {
            lock.wait()
            defer { lock.signal() }
            kv?.errorLogsEnabled = newValue
        }
    }

    // MARK: - Private state

    private var kv: KVStorage?
    private let lock = DispatchSemaphore(value: 1)
    private let queue: DispatchQueue
    #if canImport(UIKit) || canImport(AppKit)
    private var terminateObserver: (any NSObjectProtocol)?
    #endif

    // MARK: - Init

    /// - Parameters:
    ///   - path: Full directory path where the cache will write data. Once
    ///     initialized, do not read / write this directory from outside.
    ///   - transformer: Serializer used to convert `Value` ↔ `Data`.
    ///   - inlineThreshold: See ``inlineThreshold``. Default `20480` (20KB).
    public init?(path: String, transformer: Transformer<Value>, inlineThreshold: UInt = 20480) {
        if path.isEmpty { return nil }

        let type: KVStorageType
        if inlineThreshold == 0 {
            type = .file
        } else if inlineThreshold == .max {
            type = .sqlite
        } else {
            type = .mixed
        }

        guard let kv = KVStorage(path: path, type: type) else { return nil }

        self.kv = kv
        self.path = path
        self.inlineThreshold = inlineThreshold
        self.transformer = transformer
        self.queue = DispatchQueue(label: "com.reers.cache.disk", attributes: .concurrent)

        kv.errorLogsEnabled = false

        trimRecursively()

        #if canImport(UIKit)
        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.appWillBeTerminated()
        }
        #elseif canImport(AppKit)
        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.appWillBeTerminated()
        }
        #endif
    }

    deinit {
        #if canImport(UIKit) || canImport(AppKit)
        if let observer = terminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    // MARK: - Sync API
    //
    // The sync methods below are marked `@available(*, noasync)`: calling them
    // from an async context triggers a warning (or an error under Swift 6 /
    // strict concurrency). Use the `async` overloads with `await` instead.

    /// Returns whether a non-expired entry exists for `key`.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func contains(_ key: Key) -> Bool {
        if isKeyInvalid(key) { return false }
        let k = stringKey(for: key)
        let now = Date()

        lock.wait()
        let item = kv?.getItemInfo(forKey: k)
        lock.signal()

        guard let item else { return false }
        let writeDate = Date(timeIntervalSince1970: TimeInterval(item.modTime))
        if expiration.isExpired(writtenAt: writeDate, now: now) {
            lock.wait()
            kv?.removeItem(forKey: k)
            lock.signal()
            return false
        }
        return true
    }

    /// Returns the value for `key`, or `nil` if absent / expired.
    ///
    /// - Throws: ``CacheError/decodingFailed(_:)`` if the stored blob exists
    ///   but the transformer rejects it.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func value(forKey key: Key) throws -> Value? {
        if isKeyInvalid(key) { return nil }
        let k = stringKey(for: key)

        lock.wait()
        let item = kv?.getItem(forKey: k)
        lock.signal()

        guard let item, !item.value.isEmpty else { return nil }

        let writeDate = Date(timeIntervalSince1970: TimeInterval(item.modTime))
        if expiration.isExpired(writtenAt: writeDate, now: Date()) {
            lock.wait()
            kv?.removeItem(forKey: k)
            lock.signal()
            return nil
        }

        return try transformer.decode(item.value)
    }

    /// Returns the extended data associated with `key`, without reading
    /// (or decoding) the main value. Cheap — only hits SQLite.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func extendedData(forKey key: Key) -> Data? {
        if isKeyInvalid(key) { return nil }
        let k = stringKey(for: key)
        lock.wait()
        defer { lock.signal() }
        return kv?.getItemInfo(forKey: k)?.extendedData
    }

    /// Returns `(value, extendedData)` for `key`, or `nil` if absent / expired.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func valueWithExtendedData(forKey key: Key) throws -> (value: Value, extendedData: Data?)? {
        if isKeyInvalid(key) { return nil }
        let k = stringKey(for: key)

        lock.wait()
        let item = kv?.getItem(forKey: k)
        lock.signal()

        guard let item, !item.value.isEmpty else { return nil }

        let writeDate = Date(timeIntervalSince1970: TimeInterval(item.modTime))
        if expiration.isExpired(writtenAt: writeDate, now: Date()) {
            lock.wait()
            kv?.removeItem(forKey: k)
            lock.signal()
            return nil
        }

        let value = try transformer.decode(item.value)
        return (value, item.extendedData)
    }

    /// Stores `value` for `key`.
    ///
    /// - Parameters:
    ///   - value: Value to cache. Pass `nil` to remove.
    ///   - key: Key.
    ///   - extendedData: Optional opaque metadata (e.g. image decoding hints,
    ///     ETag, source URL) stored alongside the value without affecting
    ///     the transformer.
    /// - Throws: ``CacheError/encodingFailed(_:)`` if the transformer rejects
    ///   the value; ``CacheError/writeFailed`` on disk errors.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func set(
        _ value: Value?,
        forKey key: Key,
        extendedData: Data? = nil
    ) throws {
        if isKeyInvalid(key) { return }
        guard let value = value else {
            remove(forKey: key)
            return
        }

        let payload: Data = try transformer.encode(value)

        let k = stringKey(for: key)
        var fname: String?
        if kv?.type != .sqlite {
            if UInt(payload.count) > inlineThreshold {
                fname = filename(for: key)
            }
        }

        lock.wait()
        let ok = kv?.saveItem(withKey: k, value: payload, filename: fname, extendedData: extendedData) ?? false
        lock.signal()

        if !ok { throw CacheError.writeFailed }
    }

    /// Removes the entry for `key`, if any.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func remove(forKey key: Key) {
        if isKeyInvalid(key) { return }
        let k = stringKey(for: key)
        lock.wait()
        kv?.removeItem(forKey: k)
        lock.signal()
    }

    /// Empties the cache.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func removeAll() {
        lock.wait()
        kv?.removeAllItems()
        lock.signal()
    }

    /// Asynchronously empties the cache, reporting progress through callbacks.
    ///
    /// Returns immediately; work runs on an internal background queue and
    /// delivers callbacks from that queue. Safe to invoke from any context.
    public func asyncRemoveAll(
        progress: (@Sendable (_ removed: Int32, _ total: Int32) -> Void)?,
        completion: (@Sendable (_ error: Bool) -> Void)?
    ) {
        queue.async { [weak self] in
            guard let self else {
                completion?(true)
                return
            }
            lock.wait()
            kv?.removeAllItems(progress: progress, end: completion)
            lock.signal()
        }
    }

    /// Removes entries whose expiration has passed.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func removeExpired() {
        guard case .seconds(let seconds) = expiration else {
            if case .date(let date) = expiration {
                lock.wait()
                if Date() >= date {
                    kv?.removeAllItems()
                }
                lock.signal()
            }
            return
        }
        let now = TimeInterval(time(nil))
        if now <= seconds { return }
        let cutoff = now - seconds
        if cutoff >= TimeInterval(Int32.max) { return }
        lock.wait()
        kv?.removeItemsEarlierThanTime(Int32(cutoff))
        lock.signal()
    }

    // MARK: - Trim

    /// Evicts LRU entries until the total count ≤ `limit`.
    public func trim(toCount limit: Int) {
        lock.wait()
        _trimToCount(limit)
        lock.signal()
    }

    /// Evicts LRU entries until the total cost (bytes) ≤ `limit`.
    public func trim(toCost limit: Int) {
        lock.wait()
        _trimToCost(limit)
        lock.signal()
    }

    // MARK: - Status

    public func totalCount() -> Int {
        lock.wait()
        defer { lock.signal() }
        return Int(kv?.getItemsCount() ?? 0)
    }

    public func totalCost() -> Int {
        lock.wait()
        defer { lock.signal() }
        return Int(kv?.getItemsSize() ?? 0)
    }

    // MARK: - Async API

    /// Async overload of ``contains(_:)``.
    public func contains(_ key: Key) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { [weak self] in
                continuation.resume(returning: self?.contains(key) ?? false)
            }
        }
    }

    /// Async overload of ``value(forKey:)``.
    public func value(forKey key: Key) async throws -> Value? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value?, any Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    let result = try value(forKey: key)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Async overload of ``valueWithExtendedData(forKey:)``.
    public func valueWithExtendedData(
        forKey key: Key
    ) async throws -> (value: Value, extendedData: Data?)? {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<(value: Value, extendedData: Data?)?, any Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    let result = try valueWithExtendedData(forKey: key)
                    continuation.resume(returning: result)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Async overload of ``extendedData(forKey:)``.
    public func extendedData(forKey key: Key) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            queue.async { [weak self] in
                continuation.resume(returning: self?.extendedData(forKey: key))
            }
        }
    }

    /// Async overload of ``set(_:forKey:extendedData:)``.
    public func set(
        _ value: Value?,
        forKey key: Key,
        extendedData: Data? = nil
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CacheError.storageUnavailable)
                    return
                }
                do {
                    try set(value, forKey: key, extendedData: extendedData)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Async overload of ``remove(forKey:)``.
    public func remove(forKey key: Key) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                self?.remove(forKey: key)
                continuation.resume()
            }
        }
    }

    /// Async overload of ``removeAll()``.
    public func removeAll() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                self?.removeAll()
                continuation.resume()
            }
        }
    }

    /// Async overload of ``removeExpired()``.
    public func removeExpired() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                self?.removeExpired()
                continuation.resume()
            }
        }
    }

    // MARK: - Private

    @inline(__always)
    private func isKeyInvalid(_ key: Key) -> Bool {
        if let k = key as? String, k.isEmpty { return true }
        return false
    }

    @inline(__always)
    private func stringKey(for key: Key) -> String {
        if let k = key as? String { return k }
        return String(describing: key)
    }

    private func filename(for key: Key) -> String {
        if let provider = fileNameProvider {
            let name = provider(key)
            if !name.isEmpty { return name }
        }
        return stringMD5(stringKey(for: key))
    }

    private func appWillBeTerminated() {
        lock.wait()
        kv = nil
        lock.signal()
    }

    private func trimRecursively() {
        DispatchQueue
            .global(qos: .utility)
            .asyncAfter(deadline: .now() + autoTrimInterval) { [weak self] in
                guard let self else { return }
                trimInBackground()
                trimRecursively()
            }
    }

    private func trimInBackground() {
        queue.async { [weak self] in
            guard let self else { return }
            lock.wait()
            _trimToCost(costLimit)
            _trimToCount(countLimit)
            _removeExpired()
            _trimToFreeDiskSpace(freeDiskSpaceLimit)
            lock.signal()
        }
    }

    private func _trimToCost(_ limit: Int) {
        if limit >= Int(Int32.max) { return }
        kv?.removeItemsToFitSize(Int32(limit))
    }

    private func _trimToCount(_ limit: Int) {
        if limit >= Int(Int32.max) { return }
        kv?.removeItemsToFitCount(Int32(limit))
    }

    private func _removeExpired() {
        switch expiration {
        case .never:
            return
        case .seconds(let seconds):
            if seconds <= 0 {
                kv?.removeAllItems()
                return
            }
            let now = TimeInterval(time(nil))
            if now <= seconds { return }
            let cutoff = now - seconds
            if cutoff >= TimeInterval(Int32.max) { return }
            kv?.removeItemsEarlierThanTime(Int32(cutoff))
        case .date(let date):
            if Date() >= date {
                kv?.removeAllItems()
            }
        }
    }

    private func _trimToFreeDiskSpace(_ target: UInt64) {
        if target == 0 { return }
        let totalBytes = Int64(kv?.getItemsSize() ?? 0)
        if totalBytes <= 0 { return }
        let free = diskSpaceFree()
        if free < 0 { return }
        let needTrim = Int64(target) - free
        if needTrim <= 0 { return }
        var costLimit = totalBytes - needTrim
        if costLimit < 0 { costLimit = 0 }
        _trimToCost(Int(costLimit))
    }
}

// MARK: - CustomStringConvertible

extension DiskCache: CustomStringConvertible {
    public var description: String {
        let id = ObjectIdentifier(self)
        if let name = name {
            return "<\(type(of: self)): \(id)> (\(name):\(path))"
        } else {
            return "<\(type(of: self)): \(id)> (\(path))"
        }
    }
}
