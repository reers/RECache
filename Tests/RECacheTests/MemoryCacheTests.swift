import Testing
import Foundation
@testable import RECache

@Suite("MemoryCache")
struct MemoryCacheTests {

    // MARK: - Basic CRUD

    @Test func setAndGet() {
        let cache = MemoryCache<String, String>()
        cache.setObject("value1", forKey: "key1")
        #expect(cache.object(forKey: "key1") == "value1")
        #expect(cache.object(forKey: "nonexistent") == nil)
    }

    @Test func containsObject() {
        let cache = MemoryCache<String, Int>()
        cache.setObject(42, forKey: "answer")
        #expect(cache.containsObject(forKey: "answer") == true)
        #expect(cache.containsObject(forKey: "missing") == false)
    }

    @Test func removeObject() {
        let cache = MemoryCache<String, String>()
        cache.setObject("value", forKey: "key")
        cache.removeObject(forKey: "key")
        #expect(cache.object(forKey: "key") == nil)
        #expect(cache.totalCount == 0)
    }

    @Test func removeAllObjects() {
        let cache = MemoryCache<String, Int>()
        for i in 0..<100 {
            cache.setObject(i, forKey: "key\(i)")
        }
        #expect(cache.totalCount == 100)
        cache.removeAllObjects()
        #expect(cache.totalCount == 0)
        #expect(cache.totalCost == 0)
    }

    @Test func setNilRemovesObject() {
        let cache = MemoryCache<String, String>()
        cache.setObject("value", forKey: "key")
        #expect(cache.containsObject(forKey: "key") == true)
        cache.setObject(nil, forKey: "key")
        #expect(cache.containsObject(forKey: "key") == false)
        #expect(cache.totalCount == 0)
    }

    @Test func updateExistingKey() {
        let cache = MemoryCache<String, String>()
        cache.setObject("old", forKey: "key")
        cache.setObject("new", forKey: "key")
        #expect(cache.object(forKey: "key") == "new")
        #expect(cache.totalCount == 1)
    }

    // MARK: - Count & Cost Tracking

    @Test func totalCountTracking() {
        let cache = MemoryCache<String, Int>()
        #expect(cache.totalCount == 0)
        cache.setObject(1, forKey: "a")
        cache.setObject(2, forKey: "b")
        cache.setObject(3, forKey: "c")
        #expect(cache.totalCount == 3)
        cache.removeObject(forKey: "b")
        #expect(cache.totalCount == 2)
    }

    @Test func totalCostTracking() {
        let cache = MemoryCache<String, Int>()
        cache.setObject(1, forKey: "a", cost: 10)
        cache.setObject(2, forKey: "b", cost: 20)
        #expect(cache.totalCost == 30)

        cache.setObject(1, forKey: "a", cost: 5)
        #expect(cache.totalCost == 25)

        cache.removeObject(forKey: "a")
        #expect(cache.totalCost == 20)
    }

    @Test func defaultCostIsZero() {
        let cache = MemoryCache<String, String>()
        cache.setObject("v", forKey: "k")
        #expect(cache.totalCost == 0)
    }

    // MARK: - LRU Ordering

    @Test func accessPromotesToHead() {
        let cache = MemoryCache<String, Int>()
        cache.countLimit = 3
        cache.setObject(1, forKey: "a")
        cache.setObject(2, forKey: "b")
        cache.setObject(3, forKey: "c")

        _ = cache.object(forKey: "a")

        cache.setObject(4, forKey: "d")

        #expect(cache.containsObject(forKey: "a") == true)
        #expect(cache.containsObject(forKey: "c") == true)
        #expect(cache.containsObject(forKey: "d") == true)
        #expect(cache.containsObject(forKey: "b") == false)
    }

    // MARK: - Trim Methods

    @Test func trimToCount() {
        let cache = MemoryCache<String, Int>()
        for i in 0..<10 {
            cache.setObject(i, forKey: "key\(i)")
        }
        cache.trimToCount(5)
        #expect(cache.totalCount == 5)

        cache.trimToCount(0)
        #expect(cache.totalCount == 0)
    }

    @Test func trimToCost() {
        let cache = MemoryCache<String, Int>()
        for i in 0..<10 {
            cache.setObject(i, forKey: "key\(i)", cost: 10)
        }
        #expect(cache.totalCost == 100)
        cache.trimToCost(50)
        #expect(cache.totalCost <= 50)
    }

    @Test func trimToAge() async throws {
        let cache = MemoryCache<String, Int>()
        cache.setObject(1, forKey: "old")

        try await Task.sleep(nanoseconds: 200_000_000)

        cache.setObject(2, forKey: "new")

        cache.trimToAge(0.1)

        #expect(cache.containsObject(forKey: "old") == false)
        #expect(cache.containsObject(forKey: "new") == true)
    }

    @Test func trimToCountEvictsLRU() {
        let cache = MemoryCache<String, Int>()
        cache.setObject(1, forKey: "first")
        cache.setObject(2, forKey: "second")
        cache.setObject(3, forKey: "third")

        cache.trimToCount(1)

        #expect(cache.containsObject(forKey: "third") == true)
        #expect(cache.containsObject(forKey: "second") == false)
        #expect(cache.containsObject(forKey: "first") == false)
    }

    @Test func trimToCostEvictsLRU() {
        let cache = MemoryCache<String, Int>()
        cache.setObject(1, forKey: "a", cost: 10)
        cache.setObject(2, forKey: "b", cost: 10)
        cache.setObject(3, forKey: "c", cost: 10)

        cache.trimToCost(10)

        #expect(cache.totalCount == 1)
        #expect(cache.containsObject(forKey: "c") == true)
    }

    // MARK: - Count Limit

    @Test func countLimitEvictsOnInsert() {
        let cache = MemoryCache<String, Int>()
        cache.countLimit = 3

        cache.setObject(1, forKey: "a")
        cache.setObject(2, forKey: "b")
        cache.setObject(3, forKey: "c")
        #expect(cache.totalCount == 3)

        cache.setObject(4, forKey: "d")
        #expect(cache.totalCount == 3)
        #expect(cache.containsObject(forKey: "a") == false)
    }

    // MARK: - Cost Limit (async trim)

    @Test func costLimitTrimsAsynchronously() async throws {
        let cache = MemoryCache<String, Int>()
        cache.costLimit = 50

        for i in 0..<10 {
            cache.setObject(i, forKey: "key\(i)", cost: 10)
        }

        try await Task.sleep(nanoseconds: 500_000_000)

        #expect(cache.totalCost <= 50)
    }

    // MARK: - Thread Safety

    @Test func concurrentReadWrite() async {
        let cache = MemoryCache<Int, Int>()
        let iterations = 1000

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<iterations {
                group.addTask {
                    cache.setObject(i, forKey: i, cost: 1)
                }
            }
            for i in 0..<iterations {
                group.addTask {
                    _ = cache.object(forKey: i)
                }
            }
        }

        #expect(cache.totalCount <= iterations)
        #expect(cache.totalCount > 0)
    }

    @Test func concurrentMixedOperations() async {
        let cache = MemoryCache<Int, Int>()
        cache.countLimit = 50

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<500 {
                group.addTask { cache.setObject(i, forKey: i) }
                group.addTask { _ = cache.object(forKey: i) }
                group.addTask { _ = cache.containsObject(forKey: i) }
            }
            group.addTask { cache.trimToCount(10) }
            group.addTask { cache.removeAllObjects() }
        }

        #expect(cache.totalCount >= 0)
    }

    // MARK: - Properties

    @Test func releaseFlags() {
        let cache = MemoryCache<String, Int>()
        #expect(cache.releaseOnMainThread == false)
        #expect(cache.releaseAsynchronously == true)

        cache.releaseOnMainThread = true
        cache.releaseAsynchronously = false
        #expect(cache.releaseOnMainThread == true)
        #expect(cache.releaseAsynchronously == false)
    }

    @Test func defaultLimits() {
        let cache = MemoryCache<String, Int>()
        #expect(cache.countLimit == Int.max)
        #expect(cache.costLimit == Int.max)
        #expect(cache.ageLimit == .greatestFiniteMagnitude)
        #expect(cache.autoTrimInterval == 5.0)
    }

    @Test func booleanDefaults() {
        let cache = MemoryCache<String, Int>()
        #expect(cache.shouldRemoveAllObjectsOnMemoryWarning == true)
        #expect(cache.shouldRemoveAllObjectsWhenEnteringBackground == true)
    }

    // MARK: - Description

    @Test func descriptionWithName() {
        let cache = MemoryCache<String, Int>()
        cache.name = "TestCache"
        #expect(cache.description.contains("TestCache"))
        #expect(cache.description.contains("MemoryCache"))
    }

    @Test func descriptionWithoutName() {
        let cache = MemoryCache<String, Int>()
        #expect(cache.description.contains("MemoryCache"))
        #expect(!cache.description.contains("()"))
    }

    // MARK: - Edge Cases

    @Test func intKeys() {
        let cache = MemoryCache<Int, String>()
        cache.setObject("zero", forKey: 0)
        cache.setObject("max", forKey: Int.max)
        #expect(cache.object(forKey: 0) == "zero")
        #expect(cache.object(forKey: Int.max) == "max")
    }

    @Test func removeNonexistentKey() {
        let cache = MemoryCache<String, Int>()
        cache.setObject(1, forKey: "a")
        cache.removeObject(forKey: "nonexistent")
        #expect(cache.totalCount == 1)
    }

    @Test func largeNumberOfEntries() {
        let cache = MemoryCache<Int, Int>()
        let count = 10_000
        for i in 0..<count {
            cache.setObject(i, forKey: i)
        }
        #expect(cache.totalCount == count)
        for i in 0..<count {
            #expect(cache.object(forKey: i) == i)
        }
    }

    @Test func repeatedSetAndRemove() {
        let cache = MemoryCache<String, Int>()
        for i in 0..<100 {
            cache.setObject(i, forKey: "key")
            #expect(cache.object(forKey: "key") == i)
        }
        #expect(cache.totalCount == 1)
        cache.removeObject(forKey: "key")
        #expect(cache.totalCount == 0)
    }
}
