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
        cache.set(1, forKey: "a", cost: 30)
        cache.set(2, forKey: "b", cost: 30) // overflow fires async trim
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

    // MARK: - Expiration

    @Test func defaultExpirationNever() {
        let cache = MemoryCache<String, Int>()
        cache.set(1, forKey: "a")
        #expect(cache.value(forKey: "a") == 1)
    }

    @Test func cacheLevelExpirationSecondsEvicts() async throws {
        let cache = MemoryCache<String, Int>()
        cache.expiration = .seconds(0.1)
        cache.set(1, forKey: "a")
        #expect(cache.value(forKey: "a") == 1)
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(cache.value(forKey: "a") == nil)
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
        cache.set(1, forKey: "a")
        try await Task.sleep(nanoseconds: 80_000_000)
        _ = cache.value(forKey: "a") // should NOT refresh write time
        try await Task.sleep(nanoseconds: 90_000_000)
        #expect(cache.value(forKey: "a") == nil)
    }

    @Test func setRefreshesExpiration() async throws {
        let cache = MemoryCache<String, Int>()
        cache.expiration = .seconds(0.2)
        cache.set(1, forKey: "a")
        try await Task.sleep(nanoseconds: 120_000_000)
        cache.set(2, forKey: "a")
        try await Task.sleep(nanoseconds: 120_000_000)
        #expect(cache.value(forKey: "a") == 2)
    }

    @Test func removeExpiredSweepsAll() async throws {
        let cache = MemoryCache<String, Int>()
        cache.expiration = .seconds(0.05)
        cache.set(1, forKey: "a")
        cache.set(2, forKey: "b")
        try await Task.sleep(nanoseconds: 100_000_000)
        cache.removeExpired()
        #expect(!cache.contains("a"))
        #expect(!cache.contains("b"))
        #expect(cache.totalCount == 0)
    }

    // MARK: - Async API

    @Test func asyncRoundtrip() async {
        let cache = MemoryCache<String, Int>()
        await cache.asyncSet(7, forKey: "a")
        let v = await cache.asyncValue(forKey: "a")
        #expect(v == 7)
        #expect(await cache.asyncContains("a"))
        await cache.asyncRemove(forKey: "a")
        #expect(!(await cache.asyncContains("a")))
    }

    @Test func asyncRemoveAll() async {
        let cache = MemoryCache<String, Int>()
        for i in 0..<10 { cache.set(i, forKey: "k\(i)") }
        await cache.asyncRemoveAll()
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

    // MARK: - Concurrent access smoke test

    @Test func concurrentAccessDoesNotCrash() async {
        let cache = MemoryCache<String, Int>()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<100 {
                group.addTask {
                    cache.set(i, forKey: "k\(i % 20)")
                    _ = cache.value(forKey: "k\(i % 20)")
                }
            }
        }
    }
}
