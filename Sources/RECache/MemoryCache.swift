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
import QuartzCore
import os.lock
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Linked list node

/// Internal LRU doubly-linked-list node. Fields are accessed only while
/// `MemoryCache.lock` is held.
fileprivate final class LinkedListNode<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    unowned var prev: LinkedListNode?
    unowned var next: LinkedListNode?
    let key: Key
    var value: Value
    var cost: Int = 0
    /// Last-access time in monotonic seconds (CACurrentMediaTime); drives LRU
    /// ordering by the linked list itself, stored here only for future use.
    var accessTime: TimeInterval = 0
    /// Write time, set on `set(_:forKey:)` and **not** refreshed on read.
    /// Evaluated against the cache-level `expiration` at read time.
    var writeDate: Date = Date()

    init(key: Key, value: Value) {
        self.key = key
        self.value = value
    }
}

// MARK: - Linked list

fileprivate final class LinkedList<Key: Hashable & Sendable, Value: Sendable> {
    private(set) var head: LinkedListNode<Key, Value>?
    private(set) var tail: LinkedListNode<Key, Value>?
    var nodeMap: [Key: LinkedListNode<Key, Value>] = [:]

    var totalCost: Int = 0
    var totalCount: Int = 0
    var releaseOnMainThread: Bool = false
    var releaseAsynchronously: Bool = true

    func insertAtHead(_ node: LinkedListNode<Key, Value>) {
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

    func bringToHead(_ node: LinkedListNode<Key, Value>) {
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

    func remove(_ node: LinkedListNode<Key, Value>) {
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
    func removeTail() -> LinkedListNode<Key, Value>? {
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

    func removeAll() {
        let holder = Array(nodeMap.values)
        nodeMap = [:]
        totalCost = 0
        totalCount = 0
        head = nil
        tail = nil

        if releaseAsynchronously {
            let queue: DispatchQueue = releaseOnMainThread ? .main : .global(qos: .utility)
            queue.async { [holder] in
                _ = holder
            }
        } else if releaseOnMainThread && pthread_main_np() == 0 {
            DispatchQueue.main.async { [holder] in
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

    private let lock: os_unfair_lock_t
    private let linkedList = LinkedList<Key, Value>()
    private let queue: DispatchQueue
    #if canImport(UIKit)
    private var memoryWarningObserver: (any NSObjectProtocol)?
    private var enterBackgroundObserver: (any NSObjectProtocol)?
    #endif

    // MARK: - Init

    public init() {
        lock = .allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        queue = DispatchQueue(label: "com.reers.cache.memory")

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
        removeAll()
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
        let now = Date()
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard let node = linkedList.nodeMap[key] else { return false }
        return !expiration.isExpired(writtenAt: node.writeDate, now: now)
    }

    /// Returns the value for `key`, or `nil` if not cached or expired.
    ///
    /// Reading **moves the entry to the head of the LRU list** but does **not**
    /// refresh its write time — expiration is evaluated against the original write.
    /// Expired entries are removed lazily here.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func value(forKey key: Key) -> Value? {
        let now = Date()
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        guard let node = linkedList.nodeMap[key] else { return nil }
        if expiration.isExpired(writtenAt: node.writeDate, now: now) {
            linkedList.remove(node)
            scheduleRelease(of: node)
            return nil
        }
        node.accessTime = CACurrentMediaTime()
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
    public func set(_ value: Value?, forKey key: Key, cost: Int = 0) {
        guard let value = value else {
            remove(forKey: key)
            return
        }

        let now = CACurrentMediaTime()
        let writeDate = Date()

        os_unfair_lock_lock(lock)

        if let node = linkedList.nodeMap[key] {
            linkedList.totalCost -= node.cost
            linkedList.totalCost += cost
            node.cost = cost
            node.accessTime = now
            node.writeDate = writeDate
            node.value = value
            linkedList.bringToHead(node)
        } else {
            let node = LinkedListNode(key: key, value: value)
            node.cost = cost
            node.accessTime = now
            node.writeDate = writeDate
            linkedList.insertAtHead(node)
        }

        // Overflow bookkeeping (kept identical to YYCache's invariants).
        let overflowCost = linkedList.totalCost > costLimit
        if linkedList.totalCount > countLimit,
           let evicted = linkedList.removeTail() {
            scheduleRelease(of: evicted)
        }

        os_unfair_lock_unlock(lock)

        if overflowCost {
            queue.async { [weak self] in
                self?.trim(toCost: self?.costLimit ?? .max)
            }
        }
    }

    /// Removes the entry for `key`, if any.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func remove(forKey key: Key) {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        if let node = linkedList.nodeMap[key] {
            linkedList.remove(node)
            scheduleRelease(of: node)
        }
    }

    /// Empties the cache.
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func removeAll() {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        linkedList.removeAll()
    }

    /// Removes every entry whose expiration has passed. O(n).
    @available(*, noasync, message: "Use `await` in async contexts.")
    public func removeExpired() {
        let now = Date()
        var holder: [LinkedListNode<Key, Value>] = []
        os_unfair_lock_lock(lock)
        let currentExpiration = expiration
        var current = linkedList.head
        while let node = current {
            let next = node.next
            if currentExpiration.isExpired(writtenAt: node.writeDate, now: now) {
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
            let q: DispatchQueue = releaseOnMain ? .main : .global(qos: .utility)
            q.async { [holder] in _ = holder }
        } else if releaseOnMain && pthread_main_np() == 0 {
            DispatchQueue.main.async { [holder] in _ = holder }
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
    public func set(_ value: Value?, forKey key: Key, cost: Int = 0) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                self?.set(value, forKey: key, cost: cost)
                continuation.resume()
            }
        }
    }

    /// Async overload of ``value(forKey:)``.
    public func value(forKey key: Key) async -> Value? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
            queue.async { [weak self] in
                continuation.resume(returning: self?.value(forKey: key))
            }
        }
    }

    /// Async overload of ``contains(_:)``.
    public func contains(_ key: Key) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            queue.async { [weak self] in
                continuation.resume(returning: self?.contains(key) ?? false)
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

    private func scheduleRelease(of node: LinkedListNode<Key, Value>) {
        if linkedList.releaseAsynchronously {
            let q: DispatchQueue = linkedList.releaseOnMainThread ? .main : .global(qos: .utility)
            q.async { _ = node }
        } else if linkedList.releaseOnMainThread && pthread_main_np() == 0 {
            DispatchQueue.main.async { _ = node }
        }
    }

    private func trimRecursively() {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + autoTrimInterval) { [weak self] in
            guard let self else { return }
            trimInBackground()
            trimRecursively()
        }
    }

    private func trimInBackground() {
        queue.async { [weak self] in
            guard let self else { return }
            trim(toCost: costLimit)
            trim(toCount: countLimit)
            removeExpired()
        }
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
            let releaseQueue: DispatchQueue = releaseOnMainThread ? .main : .global(qos: .utility)
            releaseQueue.async { [holder] in _ = holder }
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
            let releaseQueue: DispatchQueue = releaseOnMainThread ? .main : .global(qos: .utility)
            releaseQueue.async { [holder] in _ = holder }
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
