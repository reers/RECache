//
//  Copyright © 2014 ibireme.
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
import os.lock
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Linked list node

/// Internal LRU doubly-linked-list node. Fields are accessed only while
/// `MemoryCache.lock` is held.
///
/// `prev` / `next` use `unowned(unsafe)` to match YYCache's
/// `__unsafe_unretained` semantics: the linked list itself owns every node
/// via `nodeMap`, so we don't need runtime retain-count checks on each
/// traversal. This removes per-pointer ARC overhead on the hot path.
///
/// Marked `@usableFromInline internal` so the `@inlinable` hot-path APIs
/// on `MemoryCache` can reference the type and enable cross-module
/// specialization for concrete `Key`/`Value` types.
@usableFromInline
internal final class LinkedListNode<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    @usableFromInline unowned(unsafe) var prev: LinkedListNode?
    @usableFromInline unowned(unsafe) var next: LinkedListNode?
    @usableFromInline let key: Key
    @usableFromInline var value: Value
    @usableFromInline var cost: Int = 0
    /// Write time, set on `set(_:forKey:)` and **not** refreshed on read.
    /// Evaluated against the cache-level `expiration` at read time.
    ///
    /// Stored as `TimeInterval` (`Date`'s underlying representation) to avoid
    /// per-write `Date()` struct construction on the hot path. Only meaningful
    /// when `expiration != .never`; callers skip touching this field entirely
    /// in the default case.
    @usableFromInline var writeTime: TimeInterval = 0

    @inlinable
    internal init(key: Key, value: Value) {
        self.key = key
        self.value = value
    }
}

// MARK: - Linked list

@usableFromInline
internal final class LinkedList<Key: Hashable & Sendable, Value: Sendable> {
    @usableFromInline var head: LinkedListNode<Key, Value>?
    @usableFromInline var tail: LinkedListNode<Key, Value>?
    @usableFromInline var nodeMap: [Key: LinkedListNode<Key, Value>] = [:]

    @usableFromInline var totalCost: Int = 0
    @usableFromInline var totalCount: Int = 0
    @usableFromInline var releaseOnMainThread: Bool = false
    @usableFromInline var releaseAsynchronously: Bool = true

    @inlinable
    internal init() {}

    @inlinable
    internal func insertAtHead(_ node: LinkedListNode<Key, Value>) {
        nodeMap[node.key] = node
        totalCost += node.cost
        totalCount += 1

        guard let head = head else {
            self.head = node
            self.tail = node
            return
        }

        node.next = head
        head.prev = node
        self.head = node
    }

    @inlinable
    internal func bringToHead(_ node: LinkedListNode<Key, Value>) {
        guard node !== head else { return }

        if node === tail {
            tail = node.prev
            tail?.next = nil
        } else {
            node.next?.prev = node.prev
            node.prev?.next = node.next
        }

        node.next = head
        node.prev = nil
        head?.prev = node
        head = node
    }

    @inlinable
    internal func remove(_ node: LinkedListNode<Key, Value>) {
        nodeMap.removeValue(forKey: node.key)
        totalCost -= node.cost
        totalCount -= 1

        if let next = node.next {
            next.prev = node.prev
        }
        if let prev = node.prev {
            prev.next = node.next
        }
        if node === head {
            head = node.next
        }
        if node === tail {
            tail = node.prev
        }
    }

    @discardableResult
    @inlinable
    internal func removeTail() -> LinkedListNode<Key, Value>? {
        guard let tail = tail else { return nil }

        nodeMap.removeValue(forKey: tail.key)
        totalCost -= tail.cost
        totalCount -= 1

        if head === tail {
            head = nil
            self.tail = nil
        } else {
            self.tail = tail.prev
            self.tail?.next = nil
        }

        return tail
    }

    @inlinable
    internal func removeAll() {
        // Build `holder` by draining nodeMap so we don't pay for an extra
        // Array(values) copy — we're throwing the dict contents away anyway.
        // Keep the dict's bucket capacity so the next batch of inserts can
        // reuse it without rehashing (matches YYCache, whose CFMutableDictionary
        // does not shrink on removeObjectForKey:). This is what kept YYCache
        // ahead on the "without resize" benchmark.
        let holder = ContiguousArray(nodeMap.values)
        nodeMap.removeAll(keepingCapacity: true)
        totalCost = 0
        totalCount = 0
        head = nil
        tail = nil

        if releaseAsynchronously {
            if releaseOnMainThread {
                Task { @MainActor [holder] in
                    _ = holder
                }
            } else {
                Task.detached(priority: .utility) { [holder] in
                    _ = holder
                }
            }
        } else if releaseOnMainThread && pthread_main_np() == 0 {
            Task { @MainActor [holder] in
                _ = holder
            }
        }
    }
}

// MARK: - MemoryCache

/// A thread-safe, generic, LRU in-memory cache.
///
/// `MemoryCache` stores values directly (no encoding), bounded by `countLimit`,
/// `costLimit`, and a cache-level `Expiration`. Access is O(1); eviction on overflow is
/// LRU. Auto-trimming runs every ``autoTrimInterval`` seconds.
///
/// ### Concurrency
/// `@unchecked Sendable`: all mutable state (the `LinkedList`, `trimQueue`,
/// NotificationCenter tokens) is either (a) protected by `lock`, or (b)
/// written only on `init` / read-only `let`. Blocks assigned to
/// ``didReceiveMemoryWarningBlock`` / ``didEnterBackgroundBlock`` follow the
/// "configure once, use after" convention inherited from YYCache; concurrent
/// mutation from multiple threads is not supported.
public final class MemoryCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {

    // MARK: - Attribute

    /// The name of the cache. Default is `nil`.
    public var name: String?

    /// The number of cached entries (read-only).
    public var totalCount: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return linkedList.totalCount
    }

    /// The total cost of cached entries (read-only).
    public var totalCost: Int {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        return linkedList.totalCost
    }

    // MARK: - Limits

    /// Maximum number of entries the cache should hold. Default: `Int.max`
    /// (no limit). Not a hard limit — overflow is evicted asynchronously.
    public var countLimit: Int = .max

    /// Maximum total cost the cache should hold before it starts evicting
    /// entries. Default: `Int.max` (no limit). Not a hard limit.
    public var costLimit: Int = .max

    /// Expiration policy applied to all entries. Evaluated at read time against
    /// each entry's last write time. Default: ``Expiration/never``.
    /// Replaces YYCache's `ageLimit`.
    public var expiration: Expiration = .never

    /// Auto-trim check interval in seconds. Default: `5.0`.
    public var autoTrimInterval: TimeInterval = 5.0

    /// If `true`, the cache flushes on `UIApplication.didReceiveMemoryWarning`.
    /// Default: `true`.
    ///
    /// - Note: Only active on platforms that import UIKit (iOS, tvOS, visionOS,
    ///   Mac Catalyst). macOS does not deliver UIKit-style memory warnings, so
    ///   this flag has no effect there.
    public var flushOnMemoryWarning: Bool = true

    /// If `true`, the cache flushes on `UIApplication.didEnterBackground`.
    /// Default: `true`.
    ///
    /// - Note: Only active on platforms that import UIKit (iOS, tvOS, visionOS,
    ///   Mac Catalyst). macOS apps do not have an equivalent lifecycle event,
    ///   so this flag has no effect there.
    public var flushOnBackground: Bool = true

    /// Invoked when the app receives a memory warning, before any automatic
    /// flush. Default: `nil`.
    ///
    /// - Note: UIKit-only (see ``flushOnMemoryWarning``).
    public var didReceiveMemoryWarningBlock: (@Sendable (MemoryCache) -> Void)?

    /// Invoked when the app enters background, before any automatic flush.
    /// Default: `nil`.
    ///
    /// - Note: UIKit-only (see ``flushOnBackground``).
    public var didEnterBackgroundBlock: (@Sendable (MemoryCache) -> Void)?

    /// Whether evicted entries are released on the main thread. Default: `false`.
    public var releaseOnMainThread: Bool {
        get {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            return linkedList.releaseOnMainThread
        }
        set {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            linkedList.releaseOnMainThread = newValue
        }
    }

    /// Whether evicted entries are released asynchronously (off the access
    /// methods' thread). Default: `true`.
    public var releaseAsynchronously: Bool {
        get {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            return linkedList.releaseAsynchronously
        }
        set {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            linkedList.releaseAsynchronously = newValue
        }
    }

    // MARK: - Private state

    // Exposed as `@usableFromInline internal` (not `private`) so the
    // `@inlinable` hot-path methods below can reference them and get
    // cross-module specialization for concrete `Key`/`Value` types.
    @usableFromInline internal let lock: os_unfair_lock_t
    @usableFromInline internal let linkedList = LinkedList<Key, Value>()

    /// Stored closure that asynchronously trims the cache down to `costLimit`.
    /// Built inside `init` to avoid `[weak self]` closure literals in
    /// `@inlinable` bodies (which crash SIL cross-module specialization).
    @usableFromInline
    internal var _scheduleAsyncTrim: @Sendable () -> Void = { }


    private var trimTask: Task<Void, Never>?

    #if canImport(UIKit)
    private var memoryWarningObserver: (any NSObjectProtocol)?
    private var enterBackgroundObserver: (any NSObjectProtocol)?
    #endif

    // MARK: - Init

    public init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())

        #if canImport(UIKit)
        memoryWarningObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            didReceiveMemoryWarningBlock?(self)
            if flushOnMemoryWarning {
                removeAll()
            }
        }

        enterBackgroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            didEnterBackgroundBlock?(self)
            if flushOnBackground {
                removeAll()
            }
        }
        #endif

        _scheduleAsyncTrim = { [weak self] in
            Task.detached(priority: .utility) { [weak self] in
                self?.trim(toCost: self?.costLimit ?? .max)
            }
        }

        trimRecursively()
    }

    deinit {
        #if canImport(UIKit)
        if let observer = memoryWarningObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = enterBackgroundObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
        trimTask?.cancel()
        removeAll()
        lock.deinitialize(count: 1)
        lock.deallocate()
    }

    // MARK: - Sync API

    /// Returns whether a non-expired entry exists for `key`.
    @available(*, noasync, message: "Use `await` in async contexts.")
    @inlinable
    public func contains(_ key: Key) -> Bool {
        _contains(key)
    }

    /// Returns the value for `key`, or `nil` if not cached or expired.
    ///
    /// Reading **moves the entry to the head of the LRU list** but does **not**
    /// refresh its write time — expiration is evaluated against the original write.
    /// Expired entries are removed lazily here.
    @available(*, noasync, message: "Use `await` in async contexts.")
    @inlinable
    public func value(forKey key: Key) -> Value? {
        _value(forKey: key)
    }

    @inlinable
    internal func _contains(_ key: Key) -> Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard let node = linkedList.nodeMap[key] else { return false }
        if case .never = expiration { return true }
        return !isExpired(node: node, nowRef: Date.timeIntervalSinceReferenceDate)
    }

    @inlinable
    internal func _value(forKey key: Key) -> Value? {
        if case .never = expiration {
            os_unfair_lock_lock(lock)
            defer { os_unfair_lock_unlock(lock) }
            guard let node = linkedList.nodeMap[key] else { return nil }
            linkedList.bringToHead(node)
            return node.value
        }

        let nowRef = Date.timeIntervalSinceReferenceDate
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard let node = linkedList.nodeMap[key] else { return nil }
        if isExpired(node: node, nowRef: nowRef) {
            linkedList.remove(node)
            scheduleRelease(of: node)
            return nil
        }
        linkedList.bringToHead(node)
        return node.value
    }

    /// Stores `value` for `key`.
    ///
    /// - Parameters:
    ///   - value: The value to cache. Passing `nil` is equivalent to
    ///     `remove(forKey:)`.
    ///   - key: The key.
    ///   - cost: Cost of the entry in your chosen unit (bytes, items, ...).
    @available(*, noasync, message: "Use `await` in async contexts.")
    @inlinable
    public func set(_ value: Value?, forKey key: Key, cost: Int = 0) {
        _set(value, forKey: key, cost: cost)
    }

    /// Removes the entry for `key`, if any.
    @available(*, noasync, message: "Use `await` in async contexts.")
    @inlinable
    public func remove(forKey key: Key) {
        _remove(forKey: key)
    }

    /// Empties the cache.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func removeAll() {
        _removeAll()
    }

    /// Removes every entry whose expiration has passed. O(n).
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func removeExpired() {
        _removeExpired()
    }

    @inlinable
    internal func _set(_ value: Value?, forKey key: Key, cost: Int = 0) {
        guard let value = value else {
            _remove(forKey: key)
            return
        }

        // Only compute a write timestamp when expiration is enabled.
        // `.never` is the common default and the timestamp would be unused.
        let writeTime: TimeInterval
        if case .never = expiration {
            writeTime = 0
        } else {
            writeTime = Date.timeIntervalSinceReferenceDate
        }

        os_unfair_lock_lock(lock)

        if let node = linkedList.nodeMap[key] {
            linkedList.totalCost += cost - node.cost
            node.cost = cost
            node.writeTime = writeTime
            node.value = value
            linkedList.bringToHead(node)
        } else {
            let node = LinkedListNode(key: key, value: value)
            node.cost = cost
            node.writeTime = writeTime
            linkedList.insertAtHead(node)
        }

        let overflowCost = linkedList.totalCost > costLimit
        if linkedList.totalCount > countLimit,
           let evicted = linkedList.removeTail() {
            scheduleRelease(of: evicted)
        }

        os_unfair_lock_unlock(lock)

        if overflowCost {
            _scheduleAsyncTrim()
        }
    }

    @inlinable
    internal func _remove(forKey key: Key) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        if let node = linkedList.nodeMap[key] {
            linkedList.remove(node)
            scheduleRelease(of: node)
        }
    }

    internal func _removeAll() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        linkedList.removeAll()
    }

    internal func _removeExpired() {
        if case .never = expiration { return }

        let nowRef = Date.timeIntervalSinceReferenceDate
        var holder: [LinkedListNode<Key, Value>] = []
        os_unfair_lock_lock(lock)
        var current = linkedList.head
        while let node = current {
            let next = node.next
            if isExpired(node: node, nowRef: nowRef) {
                linkedList.remove(node)
                holder.append(node)
            }
            current = next
        }
        let releaseOnMain = linkedList.releaseOnMainThread
        let releaseAsync = linkedList.releaseAsynchronously
        os_unfair_lock_unlock(lock)

        if holder.isEmpty { return }
        if releaseAsync {
            if releaseOnMain {
                Task { @MainActor [holder] in _ = holder }
            } else {
                Task.detached(priority: .utility) { [holder] in _ = holder }
            }
        } else if releaseOnMain && pthread_main_np() == 0 {
            Task { @MainActor [holder] in _ = holder }
        }
    }

    /// Expiration check using the `TimeInterval` (reference-date) representation
    /// stored on `LinkedListNode.writeTime`, avoiding `Date` struct round-trips.
    /// Caller must have already verified that `expiration != .never`.
    @inline(__always)
    @inlinable
    internal func isExpired(node: LinkedListNode<Key, Value>, nowRef: TimeInterval) -> Bool {
        switch expiration {
        case .never:
            return false
        case .seconds(let interval):
            return nowRef >= node.writeTime + interval
        case .days(let days):
            return nowRef >= node.writeTime + TimeInterval(days) * 86_400
        case .date(let date):
            return nowRef >= date.timeIntervalSinceReferenceDate
        }
    }

    // MARK: - Trim

    /// Evicts LRU entries until the total count is at or below `limit`.
    public func trim(toCount limit: Int) {
        if limit == 0 {
            removeAll()
            return
        }
        _trimToCount(limit)
    }

    /// Evicts LRU entries until the total cost is at or below `limit`.
    public func trim(toCost limit: Int) {
        _trimToCost(limit)
    }

    // MARK: - Async API

    /// Async overload of ``set(_:forKey:cost:)``.
    public nonisolated func set(_ value: Value?, forKey key: Key, cost: Int = 0) async {
        _set(value, forKey: key, cost: cost)
    }

    /// Async overload of ``value(forKey:)``.
    public nonisolated func value(forKey key: Key) async -> Value? {
        _value(forKey: key)
    }

    /// Async overload of ``contains(_:)``.
    public nonisolated func contains(_ key: Key) async -> Bool {
        _contains(key)
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

    // MARK: - Private

    @inlinable
    internal func scheduleRelease(of node: LinkedListNode<Key, Value>) {
        if linkedList.releaseAsynchronously {
            if linkedList.releaseOnMainThread {
                Task { @MainActor in _ = node }
            } else {
                Task.detached(priority: .utility) { _ = node }
            }
        } else if linkedList.releaseOnMainThread && pthread_main_np() == 0 {
            Task { @MainActor in _ = node }
        }
    }

    private func trimRecursively() {
        trimTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.autoTrimInterval else { return }
                let nanos = UInt64(max(0, interval) * 1_000_000_000)
                // `try?` swallows CancellationError; the `while` guard will
                // exit on the next iteration.
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { return }
                self?.trimInBackground()
            }
        }
    }

    private func trimInBackground() {
        trim(toCost: costLimit)
        trim(toCount: countLimit)
        _removeExpired()
    }

    private func _trimToCost(_ limit: Int) {
        var finished = false
        os_unfair_lock_lock(lock)
        if limit == 0 {
            linkedList.removeAll()
            finished = true
        } else if linkedList.totalCost <= limit {
            finished = true
        }
        os_unfair_lock_unlock(lock)
        if finished { return }

        var holder: [LinkedListNode<Key, Value>] = []
        var releaseOnMainThread = false
        while !finished {
            if os_unfair_lock_trylock(lock) {
                if linkedList.totalCost > limit {
                    if let node = linkedList.removeTail() {
                        holder.append(node)
                    }
                } else {
                    finished = true
                }
                releaseOnMainThread = linkedList.releaseOnMainThread
                os_unfair_lock_unlock(lock)
            } else {
                usleep(10 * 1000)
            }
        }

        if !holder.isEmpty {
            if releaseOnMainThread {
                Task { @MainActor [holder] in _ = holder }
            } else {
                Task.detached(priority: .utility) { [holder] in _ = holder }
            }
        }
    }

    private func _trimToCount(_ limit: Int) {
        var finished = false
        os_unfair_lock_lock(lock)
        if limit == 0 {
            linkedList.removeAll()
            finished = true
        } else if linkedList.totalCount <= limit {
            finished = true
        }
        os_unfair_lock_unlock(lock)
        if finished { return }

        var holder: [LinkedListNode<Key, Value>] = []
        var releaseOnMainThread = false
        while !finished {
            if os_unfair_lock_trylock(lock) {
                if linkedList.totalCount > limit {
                    if let node = linkedList.removeTail() {
                        holder.append(node)
                    }
                } else {
                    finished = true
                }
                releaseOnMainThread = linkedList.releaseOnMainThread
                os_unfair_lock_unlock(lock)
            } else {
                usleep(10 * 1000)
            }
        }

        if !holder.isEmpty {
            if releaseOnMainThread {
                Task { @MainActor [holder] in _ = holder }
            } else {
                Task.detached(priority: .utility) { [holder] in _ = holder }
            }
        }
    }
}

// MARK: - CustomStringConvertible

extension MemoryCache: CustomStringConvertible {
    public var description: String {
        let id = ObjectIdentifier(self)
        if let name = name {
            return "<\(type(of: self)): \(id)> (\(name))"
        } else {
            return "<\(type(of: self)): \(id)>"
        }
    }
}
