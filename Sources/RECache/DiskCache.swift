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
import os.lock
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
/// serialized by ``lock`` (an `os_unfair_lock`, matching `MemoryCache`).
/// Mutable public properties follow the YYCache "configure once, use after"
/// convention — concurrent mutation from multiple threads is not supported.
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
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            return kv?.errorLogsEnabled ?? false
        }
        set {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            kv?.errorLogsEnabled = newValue
        }
    }

    // MARK: - Private state

    private var kv: KVStorage?

    // MARK: - Concurrency Migration
    //
    // Was: `DispatchSemaphore(value: 1)` used as a plain mutex (every
    // `wait/signal` pair was a lock critical section — no cross-thread
    // signalling semantics). Replaced with `os_unfair_lock` (the same
    // primitive `MemoryCache` uses) because:
    //   1. `os_unfair_lock_lock / _unlock` is the fastest Darwin mutex
    //      (~15-25 ns uncontested) while being semantically identical to
    //      a `DispatchSemaphore(value: 1)` used as a mutex.
    //   2. It unifies the two caches on one lock primitive.
    //   3. `OSAllocatedUnfairLock` (iOS 16+) and `Synchronization.Mutex`
    //      (iOS 18+) are not available on the iOS 13+ deployment floor.
    //
    // Stored as a heap-allocated `os_unfair_lock_t` so its identity is
    // stable across any copies / property-wrapper indirection. `deinit`
    // tears it down.
    private let lock: os_unfair_lock_t

    // MARK: - Concurrency Migration
    //
    // Was: `DispatchQueue(label: "com.reers.cache.disk", attributes: .concurrent)`
    // used for (a) `withCheckedContinuation + queue.async` bridges in
    // every `async` wrapper, and (b) the body of `asyncRemoveAll`.
    //
    // Now:
    //   (a) `async` overloads call non-`noasync` internal helpers
    //       (`_contains`, `_value`, `_set`, …) directly. `os_unfair_lock`
    //       serialises access to `kv`, so an extra dispatch hop bought
    //       nothing.
    //   (b) `asyncRemoveAll` uses `Task.detached(priority: .utility)`.
    //
    // The concurrent queue was also misleading: every job `lock.wait()`ed
    // before touching `kv`, so it was effectively serial. Removing it
    // makes that explicit.

    /// Handle to the background auto-trim Task. Cancelled in `deinit`.
    /// Replaces the old recursive `DispatchQueue.asyncAfter` chain.
    private var trimTask: Task<Void, Never>?

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
        self.lock = .allocate(capacity: 1)
        self.lock.initialize(to: os_unfair_lock())

        kv.errorLogsEnabled = false

        startAutoTrim()

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
        // MARK: - Concurrency Migration
        // Was: recursive asyncAfter chain relied on `[weak self]` nil to
        // stop. Now we own a Task handle and cancel it deterministically.
        trimTask?.cancel()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: - Sync API
    //
    // The sync methods below are marked `@available(*, noasync)`: calling them
    // from an async context triggers a warning (or an error under Swift 6 /
    // strict concurrency). Use the `async` overloads with `await` instead.

    /// Returns whether a non-expired entry exists for `key`.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func contains(_ key: Key) -> Bool {
        _contains(key)
    }

    /// Returns the value for `key`, or `nil` if absent / expired.
    ///
    /// - Throws: ``CacheError/decodingFailed(_:)`` if the stored blob exists
    ///   but the transformer rejects it.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func value(forKey key: Key) throws -> Value? {
        try _value(forKey: key)
    }

    /// Returns the extended data associated with `key`, without reading
    /// (or decoding) the main value. Cheap — only hits SQLite.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func extendedData(forKey key: Key) -> Data? {
        _extendedData(forKey: key)
    }

    /// Returns `(value, extendedData)` for `key`, or `nil` if absent / expired.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func valueWithExtendedData(forKey key: Key) throws -> (value: Value, extendedData: Data?)? {
        try _valueWithExtendedData(forKey: key)
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
        try _set(value, forKey: key, extendedData: extendedData)
    }

    /// Removes the entry for `key`, if any.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func remove(forKey key: Key) {
        _remove(forKey: key)
    }

    /// Empties the cache.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func removeAll() {
        _removeAll()
    }

    /// Asynchronously empties the cache, reporting progress through callbacks.
    ///
    /// Returns immediately; work runs on a background executor and delivers
    /// callbacks from that executor. Safe to invoke from any context.
    //
    // MARK: - Concurrency Migration
    // Was: `queue.async { [weak self] in lock.wait(); kv.removeAllItems(...); lock.signal() }`.
    // Now: `Task.detached(priority: .utility) { … }`. Semantics match —
    // fire-and-forget work on a background executor. The callbacks are
    // still invoked from that executor, as before.
    public func asyncRemoveAll(
        progress: (@Sendable (_ removed: Int32, _ total: Int32) -> Void)?,
        completion: (@Sendable (_ error: Bool) -> Void)?
    ) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else {
                completion?(true)
                return
            }
            // Delegated to a sync helper because `os_unfair_lock_lock` /
            // `_unlock` are `OS_SWIFT_UNAVAILABLE_FROM_ASYNC`; sitting them
            // inside a non-async helper keeps the call site itself out of
            // async context.
            self._asyncRemoveAllLocked(progress: progress, completion: completion)
        }
    }

    private func _asyncRemoveAllLocked(
        progress: (@Sendable (_ removed: Int32, _ total: Int32) -> Void)?,
        completion: (@Sendable (_ error: Bool) -> Void)?
    ) {
        os_unfair_lock_lock(lock)
        kv?.removeAllItems(progress: progress, end: completion)
        os_unfair_lock_unlock(lock)
    }

    /// Removes entries whose expiration has passed.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func removeExpired() {
        _removeExpired()
    }

    // MARK: - Trim

    /// Evicts LRU entries until the total count ≤ `limit`.
    public func trim(toCount limit: Int) {
        os_unfair_lock_lock(lock)
        _trimToCount(limit)
        os_unfair_lock_unlock(lock)
    }

    /// Evicts LRU entries until the total cost (bytes) ≤ `limit`.
    public func trim(toCost limit: Int) {
        os_unfair_lock_lock(lock)
        _trimToCost(limit)
        os_unfair_lock_unlock(lock)
    }

    // MARK: - Status

    public func totalCount() -> Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return Int(kv?.getItemsCount() ?? 0)
    }

    public func totalCost() -> Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return Int(kv?.getItemsSize() ?? 0)
    }

    // MARK: - Async API
    //
    // MARK: - Concurrency Migration
    // Each of these previously went through a
    // `withCheckedContinuation + queue.async { self?.syncMethod(...) }`
    // double-hop. Now they call the non-`noasync` internal helpers
    // (`_contains`, `_value`, …) directly. The sync implementations are
    // already thread-safe under `os_unfair_lock`, so calling them from any
    // isolation is safe, and we save one continuation allocation plus one
    // GCD enqueue per call.

    /// Async overload of ``contains(_:)``.
    public nonisolated func contains(_ key: Key) async -> Bool {
        _contains(key)
    }

    /// Async overload of ``value(forKey:)``.
    public nonisolated func value(forKey key: Key) async throws -> Value? {
        try _value(forKey: key)
    }

    /// Async overload of ``valueWithExtendedData(forKey:)``.
    public nonisolated func valueWithExtendedData(
        forKey key: Key
    ) async throws -> (value: Value, extendedData: Data?)? {
        try _valueWithExtendedData(forKey: key)
    }

    /// Async overload of ``extendedData(forKey:)``.
    public nonisolated func extendedData(forKey key: Key) async -> Data? {
        _extendedData(forKey: key)
    }

    /// Async overload of ``set(_:forKey:extendedData:)``.
    public nonisolated func set(
        _ value: Value?,
        forKey key: Key,
        extendedData: Data? = nil
    ) async throws {
        try _set(value, forKey: key, extendedData: extendedData)
    }

    /// Async overload of ``remove(forKey:)``.
    public nonisolated func remove(forKey key: Key) async {
        _remove(forKey: key)
    }

    /// Async overload of ``removeAll()``.
    public nonisolated func removeAll() async {
        _removeAll()
    }

    /// Async overload of ``removeExpired()``.
    public nonisolated func removeExpired() async {
        _removeExpired()
    }

    // MARK: - Internal helpers (shared by sync + async API)

    internal func _contains(_ key: Key) -> Bool {
        if isKeyInvalid(key) { return false }
        let k = stringKey(for: key)
        let now = Date()

        os_unfair_lock_lock(lock)
        let item = kv?.getItemInfo(forKey: k)
        os_unfair_lock_unlock(lock)

        guard let item else { return false }
        let writeDate = Date(timeIntervalSince1970: TimeInterval(item.modTime))
        if expiration.isExpired(writtenAt: writeDate, now: now) {
            os_unfair_lock_lock(lock)
            kv?.removeItem(forKey: k)
            os_unfair_lock_unlock(lock)
            return false
        }
        return true
    }

    internal func _value(forKey key: Key) throws -> Value? {
        if isKeyInvalid(key) { return nil }
        let k = stringKey(for: key)

        os_unfair_lock_lock(lock)
        let item = kv?.getItem(forKey: k)
        os_unfair_lock_unlock(lock)

        guard let item, !item.value.isEmpty else { return nil }

        let writeDate = Date(timeIntervalSince1970: TimeInterval(item.modTime))
        if expiration.isExpired(writtenAt: writeDate, now: Date()) {
            os_unfair_lock_lock(lock)
            kv?.removeItem(forKey: k)
            os_unfair_lock_unlock(lock)
            return nil
        }

        return try transformer.decode(item.value)
    }

    internal func _extendedData(forKey key: Key) -> Data? {
        if isKeyInvalid(key) { return nil }
        let k = stringKey(for: key)
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return kv?.getItemInfo(forKey: k)?.extendedData
    }

    internal func _valueWithExtendedData(forKey key: Key) throws -> (value: Value, extendedData: Data?)? {
        if isKeyInvalid(key) { return nil }
        let k = stringKey(for: key)

        os_unfair_lock_lock(lock)
        let item = kv?.getItem(forKey: k)
        os_unfair_lock_unlock(lock)

        guard let item, !item.value.isEmpty else { return nil }

        let writeDate = Date(timeIntervalSince1970: TimeInterval(item.modTime))
        if expiration.isExpired(writtenAt: writeDate, now: Date()) {
            os_unfair_lock_lock(lock)
            kv?.removeItem(forKey: k)
            os_unfair_lock_unlock(lock)
            return nil
        }

        let value = try transformer.decode(item.value)
        return (value, item.extendedData)
    }

    internal func _set(
        _ value: Value?,
        forKey key: Key,
        extendedData: Data? = nil
    ) throws {
        if isKeyInvalid(key) { return }
        guard let value = value else {
            _remove(forKey: key)
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

        os_unfair_lock_lock(lock)
        let ok = kv?.saveItem(withKey: k, value: payload, filename: fname, extendedData: extendedData) ?? false
        os_unfair_lock_unlock(lock)

        if !ok { throw CacheError.writeFailed }
    }

    internal func _remove(forKey key: Key) {
        if isKeyInvalid(key) { return }
        let k = stringKey(for: key)
        os_unfair_lock_lock(lock)
        kv?.removeItem(forKey: k)
        os_unfair_lock_unlock(lock)
    }

    internal func _removeAll() {
        os_unfair_lock_lock(lock)
        kv?.removeAllItems()
        os_unfair_lock_unlock(lock)
    }

    internal func _removeExpired() {
        switch expiration {
        case .never:
            return
        case .seconds(let seconds):
            _removeExpiredByAge(seconds)
        case .days(let days):
            _removeExpiredByAge(TimeInterval(days) * 86_400)
        case .date(let date):
            os_unfair_lock_lock(lock)
            if Date() >= date {
                kv?.removeAllItems()
            }
            os_unfair_lock_unlock(lock)
        }
    }

    private func _removeExpiredByAge(_ seconds: TimeInterval) {
        let now = TimeInterval(time(nil))
        if now <= seconds { return }
        let cutoff = now - seconds
        if cutoff >= TimeInterval(Int32.max) { return }
        os_unfair_lock_lock(lock)
        kv?.removeItemsEarlierThanTime(Int32(cutoff))
        os_unfair_lock_unlock(lock)
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
        os_unfair_lock_lock(lock)
        kv = nil
        os_unfair_lock_unlock(lock)
    }

    // MARK: - Concurrency Migration
    //
    // Was: `DispatchQueue.global(qos:.utility).asyncAfter(deadline: …) { [weak self] in trimInBackground(); trimRecursively() }`.
    // Now: a single `Task.detached(priority:.utility)` sleeps between
    // iterations. `trimTask` holds the handle so `deinit` can cancel
    // the loop without having to rely on weak-self nil'ing to stop the
    // next rescheduled block.
    private func startAutoTrim() {
        trimTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.autoTrimInterval else { return }
                let nanos = UInt64(max(0, interval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                self?.trimInBackground()
            }
        }
    }

    private func trimInBackground() {
        // Single critical section covering cost / count / age / freespace
        // trims, matching the original semantics (was previously one
        // `lock.wait() … lock.signal()` block inside `queue.async`).
        os_unfair_lock_lock(lock)
        _trimToCost(costLimit)
        _trimToCount(countLimit)
        _removeExpired_locked()
        _trimToFreeDiskSpace(freeDiskSpaceLimit)
        os_unfair_lock_unlock(lock)
    }

    /// Lock-held variant of `_removeExpired()`: `trimInBackground` already
    /// holds `lock`, so we mustn't take it again (`os_unfair_lock` is not
    /// reentrant — the second `_lock` would deadlock the thread).
    private func _removeExpired_locked() {
        switch expiration {
        case .never:
            return
        case .seconds(let seconds):
            _removeExpiredByAgeLocked(seconds)
        case .days(let days):
            _removeExpiredByAgeLocked(TimeInterval(days) * 86_400)
        case .date(let date):
            if Date() >= date {
                kv?.removeAllItems()
            }
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

    private func _removeExpiredByAgeLocked(_ seconds: TimeInterval) {
        if seconds <= 0 {
            kv?.removeAllItems()
            return
        }
        let now = TimeInterval(time(nil))
        if now <= seconds { return }
        let cutoff = now - seconds
        if cutoff >= TimeInterval(Int32.max) { return }
        kv?.removeItemsEarlierThanTime(Int32(cutoff))
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

// MARK: - Auto Transformer
//
// Convenience initializers that pick a built-in ``Transformer`` based solely
// on `Value`. See the companion note on ``Cache`` for the overload-resolution
// rules — same-type constraints (`Value == Data`, `Value == UIImage`) take
// precedence over the `Value: Codable` overload, so `DiskCache<_, Data>` and
// `DiskCache<_, UIImage>` route to the dedicated factories unambiguously.

extension DiskCache where Value == Data {
    /// Creates a disk cache at `path` using ``Transformer/data()``.
    public convenience init?(path: String, inlineThreshold: UInt = 20480) {
        self.init(path: path, transformer: .data(), inlineThreshold: inlineThreshold)
    }
}

extension DiskCache where Value: Codable {
    /// Creates a disk cache at `path` using ``Transformer/codable(format:)``.
    ///
    /// - Parameter format: Wire format. Default ``CodableFormat/json``.
    public convenience init?(
        path: String,
        format: CodableFormat = .json,
        inlineThreshold: UInt = 20480
    ) {
        self.init(path: path, transformer: .codable(format: format), inlineThreshold: inlineThreshold)
    }
}

#if canImport(UIKit)
import UIKit

extension DiskCache where Value == UIImage {
    /// Creates a disk cache at `path` using ``Transformer/image(jpegCompressionQuality:)``.
    public convenience init?(
        path: String,
        jpegCompressionQuality: CGFloat = 1.0,
        inlineThreshold: UInt = 20480
    ) {
        self.init(
            path: path,
            transformer: .image(jpegCompressionQuality: jpegCompressionQuality),
            inlineThreshold: inlineThreshold
        )
    }
}
#elseif canImport(AppKit)
import AppKit

@available(macOS 14.0, *)
extension DiskCache where Value == NSImage {
    /// Creates a disk cache at `path` using ``Transformer/image(jpegCompressionQuality:)``.
    public convenience init?(
        path: String,
        jpegCompressionQuality: CGFloat = 1.0,
        inlineThreshold: UInt = 20480
    ) {
        self.init(
            path: path,
            transformer: .image(jpegCompressionQuality: jpegCompressionQuality),
            inlineThreshold: inlineThreshold
        )
    }
}
#endif
