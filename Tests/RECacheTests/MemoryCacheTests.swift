import Testing
import Foundation
@testable import RECache

@Suite("MemoryCache")
struct MemoryCacheTests {

    // MARK: - Basic CRUD

    @Test func setAndGet() {
        let cache = MemoryCache<String, String>()
        cache.set("value1", forKey: "key1")
        #expect(cache.value(forKey: "key1") == "value1")
        #expect(cache.value(forKey: "nonexistent") == nil)
    }

    @Test func contains() {
        let cache = MemoryCache<String, Int>()
        cache.set(42, forKey: "answer")
        #expect(cache.contains("answer"))
        #expect(!cache.contains("missing"))
    }

    @Test func remove() {
        let cache = MemoryCache<String, String>()
        cache.set("value", forKey: "key")
        cache.remove(forKey: "key")
        #expect(cache.value(forKey: "key") == nil)
        #expect(cache.totalCount == 0)
    }

    @Test func removeAll() {
        let cache = MemoryCache<String, Int>()
        for i in 0..<100 {
            cache.set(i, forKey: "key\(i)")
        }
        #expect(cache.totalCount == 100)
        cache.removeAll()
        #expect(cache.totalCount == 0)
        #expect(cache.totalCost == 0)
    }

    @Test func setNilRemovesEntry() {
        let cache = MemoryCache<String, String>()
        cache.set("value", forKey: "key")
        #expect(cache.contains("key"))
        cache.set(nil, forKey: "key")
        #expect(!cache.contains("key"))
        #expect(cache.totalCount == 0)
    }

    @Test func updateExistingKey() {
        let cache = MemoryCache<String, String>()
        cache.set("old", forKey: "key")
        cache.set("new", forKey: "key")
        #expect(cache.value(forKey: "key") == "new")
        #expect(cache.totalCount == 1)
    }

    // MARK: - Count / cost

    @Test func totalCountAndCost() {
        let cache = MemoryCache<String, String>()
        cache.set("a", forKey: "k1", cost: 10)
        cache.set("b", forKey: "k2", cost: 20)
        cache.set("c", forKey: "k3", cost: 30)
        #expect(cache.totalCount == 3)
        #expect(cache.totalCost == 60)
    }

    @Test func updateAdjustsCost() {
        let cache = MemoryCache<String, String>()
        cache.set("a", forKey: "k1", cost: 10)
        #expect(cache.totalCost == 10)
        cache.set("b", forKey: "k1", cost: 50)
        #expect(cache.totalCost == 50)
        #expect(cache.totalCount == 1)
    }

    // MARK: - Limits

    @Test func countLimitEvictsLRU() {
        let cache = MemoryCache<String, Int>()
        cache.countLimit = 3
        cache.set(1, forKey: "a")
        cache.set(2, forKey: "b")
        cache.set(3, forKey: "c")
        cache.set(4, forKey: "d") // should evict "a"
        #expect(cache.value(forKey: "a") == nil)
        #expect(cache.value(forKey: "b") == 2)
        #expect(cache.value(forKey: "d") == 4)
    }

    @Test func costLimitTrimsEventually() async {
        let cache = MemoryCache<String, Int>()
        cache.costLimit = 50
        await cache.set(1, forKey: "a", cost: 30)
        await cache.set(2, forKey: "b", cost: 30) // overflow fires async trim
        cache.trim(toCost: 50) // force sync
        #expect(cache.totalCost <= 50)
    }

    @Test func trimToCount() {
        let cache = MemoryCache<String, Int>()
        for i in 0..<10 {
            cache.set(i, forKey: "k\(i)")
        }
        cache.trim(toCount: 3)
        #expect(cache.totalCount == 3)
    }

    @Test func trimToZeroRemovesAll() {
        let cache = MemoryCache<String, Int>()
        cache.set(1, forKey: "a")
        cache.trim(toCount: 0)
        #expect(cache.totalCount == 0)
    }

    @Test func trimToCostZeroRemovesAll() {
        let cache = MemoryCache<String, Int>()
        cache.set(1, forKey: "a", cost: 5)
        cache.set(2, forKey: "b", cost: 5)
        cache.trim(toCost: 0)
        #expect(cache.totalCount == 0)
        #expect(cache.totalCost == 0)
    }

    @Test func trimToCostAboveCurrentIsNoOp() {
        let cache = MemoryCache<String, Int>()
        cache.set(1, forKey: "a", cost: 5)
        cache.trim(toCost: 100)
        #expect(cache.totalCount == 1)
    }

    // MARK: - Expiration

    @Test func defaultExpirationNever() {
        let cache = MemoryCache<String, Int>()
        cache.set(1, forKey: "a")
        #expect(cache.value(forKey: "a") == 1)
    }

    @Test func cacheLevelExpirationSecondsEvicts() async throws {
        let cache = MemoryCache<String, Int>()
        cache.expiration = .seconds(0.4)
        await cache.set(1, forKey: "a")
        #expect(await cache.value(forKey: "a") == 1)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(await cache.value(forKey: "a") == nil)
        #expect(cache.totalCount == 0)
    }

    @Test func cacheLevelExpirationDatePast() {
        let cache = MemoryCache<String, Int>()
        cache.set(1, forKey: "a")
        cache.expiration = .date(Date(timeIntervalSinceNow: -1))
        #expect(cache.value(forKey: "a") == nil)
    }

    @Test func readDoesNotRefreshExpiration() async throws {
        let cache = MemoryCache<String, Int>()
        cache.expiration = .seconds(0.15)
        await cache.set(1, forKey: "a")
        try await Task.sleep(nanoseconds: 80_000_000)
        _ = await cache.value(forKey: "a") // should NOT refresh write time
        try await Task.sleep(nanoseconds: 90_000_000)
        #expect(await cache.value(forKey: "a") == nil)
    }

    @Test func setRefreshesExpiration() async throws {
        let cache = MemoryCache<String, Int>()
        cache.expiration = .seconds(0.2)
        await cache.set(1, forKey: "a")
        try await Task.sleep(nanoseconds: 120_000_000)
        await cache.set(2, forKey: "a")
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(await cache.value(forKey: "a") == 2)
    }

    @Test func removeExpiredSweepsAll() async throws {
        let cache = MemoryCache<String, Int>()
        cache.expiration = .seconds(0.05)
        await cache.set(1, forKey: "a")
        await cache.set(2, forKey: "b")
        try await Task.sleep(nanoseconds: 100_000_000)
        await cache.removeExpired()
        #expect(!(await cache.contains("a")))
        #expect(!(await cache.contains("b")))
        #expect(cache.totalCount == 0)
    }

    @Test func cacheLevelExpirationDaysPastEvicts() {
        let cache = MemoryCache<String, Int>()
        cache.set(1, forKey: "a")
        cache.expiration = .days(-1)
        #expect(cache.value(forKey: "a") == nil)
    }

    @Test func cacheLevelExpirationDaysFutureKeeps() {
        let cache = MemoryCache<String, Int>()
        cache.expiration = .days(1)
        cache.set(1, forKey: "a")
        #expect(cache.value(forKey: "a") == 1)
    }

    @Test func removeExpiredDaysSweeps() async throws {
        let cache = MemoryCache<String, Int>()
        await cache.set(1, forKey: "a")
        await cache.set(2, forKey: "b")
        cache.expiration = .days(-1)
        await cache.removeExpired()
        #expect(!(await cache.contains("a")))
        #expect(!(await cache.contains("b")))
        #expect(cache.totalCount == 0)
    }

    // MARK: - Async API

    @Test func asyncRoundtrip() async {
        let cache = MemoryCache<String, Int>()
        await cache.set(7, forKey: "a")
        let v = await cache.value(forKey: "a")
        #expect(v == 7)
        #expect(await cache.contains("a"))
        await cache.remove(forKey: "a")
        #expect(!(await cache.contains("a")))
    }

    @Test func asyncRemoveAll() async {
        let cache = MemoryCache<String, Int>()
        for i in 0..<10 { await cache.set(i, forKey: "k\(i)") }
        await cache.removeAll()
        #expect(cache.totalCount == 0)
    }

    // MARK: - Generic keys

    @Test func intKeys() {
        let cache = MemoryCache<Int, String>()
        cache.set("one", forKey: 1)
        cache.set("two", forKey: 2)
        #expect(cache.value(forKey: 1) == "one")
        #expect(cache.value(forKey: 2) == "two")
    }

    @Test func customHashableKeys() {
        struct Key: Hashable {
            let user: Int
            let scope: String
        }
        let cache = MemoryCache<Key, Int>()
        cache.set(99, forKey: Key(user: 1, scope: "a"))
        #expect(cache.value(forKey: Key(user: 1, scope: "a")) == 99)
        #expect(cache.value(forKey: Key(user: 2, scope: "a")) == nil)
    }

    // MARK: - Release flags (read/write the backing linked list)

    @Test func releaseOnMainThreadFlag() {
        let cache = MemoryCache<String, Int>()
        #expect(cache.releaseOnMainThread == false)
        cache.releaseOnMainThread = true
        #expect(cache.releaseOnMainThread == true)
        cache.releaseOnMainThread = false
        #expect(cache.releaseOnMainThread == false)
    }

    @Test func releaseAsynchronouslyFlag() {
        let cache = MemoryCache<String, Int>()
        #expect(cache.releaseAsynchronously == true)
        cache.releaseAsynchronously = false
        #expect(cache.releaseAsynchronously == false)
        cache.releaseAsynchronously = true
        #expect(cache.releaseAsynchronously == true)
    }

    /// Exercises the `releaseAsynchronously = true` (default) path through
    /// `scheduleRelease` / `LinkedList.removeAll` / `_trimToCost` / `_trimToCount`
    /// where nodes are dispatched to a background queue for release.
    @Test func releaseAsyncPathsRun() async {
        let cache = MemoryCache<String, Int>()
        cache.releaseAsynchronously = true
        for i in 0..<5 { await cache.set(i, forKey: "k\(i)", cost: 10) }
        cache.trim(toCount: 2)
        #expect(cache.totalCount == 2)
        cache.trim(toCost: 5)
        await cache.set(9, forKey: "solo", cost: 1)
        await cache.remove(forKey: "solo")
        await cache.removeAll()
        // Give the async release dispatches time to drain.
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(cache.totalCount == 0)
    }

    /// Exercises the `releaseAsynchronously = false && releaseOnMainThread` branch
    /// of `scheduleRelease` / `LinkedList.removeAll`.
    @Test func releaseSyncOnMainThreadPath() async {
        let cache = MemoryCache<String, Int>()
        cache.releaseAsynchronously = false
        cache.releaseOnMainThread = true
        for i in 0..<3 { await cache.set(i, forKey: "k\(i)") }
        await cache.remove(forKey: "k0")
        await cache.removeAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(cache.totalCount == 0)
    }

    // MARK: - CustomStringConvertible

    @Test func descriptionWithoutName() {
        let cache = MemoryCache<String, Int>()
        let desc = cache.description
        #expect(desc.contains("MemoryCache"))
    }

    @Test func descriptionWithName() {
        let cache = MemoryCache<String, Int>()
        cache.name = "memo"
        #expect(cache.description.contains("memo"))
    }

    // MARK: - Auto-trim

    /// Drives `trimRecursively` / `trimInBackground` by dropping the interval
    /// and waiting. Asserts the count shrinks to `countLimit` without manual
    /// `trim(toCount:)` calls.
    @Test func autoTrimRunsInBackground() async throws {
        let cache = MemoryCache<String, Int>()
        cache.autoTrimInterval = 0.1
        cache.countLimit = 2
        for i in 0..<6 { await cache.set(i, forKey: "k\(i)") }
        // Wait a few auto-trim cycles.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(cache.totalCount <= 2)
    }

    // MARK: - Concurrent access smoke test

    @Test func concurrentAccessDoesNotCrash() async {
        let cache = MemoryCache<String, Int>()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    await cache.set(i, forKey: "k\(i % 20)")
                    _ = await cache.value(forKey: "k\(i % 20)")
                }
            }
        }
    }
}
