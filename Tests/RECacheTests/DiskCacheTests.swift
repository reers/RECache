import Testing
import Foundation
@testable import RECache

@Suite("DiskCache")
struct DiskCacheTests {

    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "DiskCacheTests/\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Initialization

    @Test func initDefault() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = DiskCache(path: dir)
        #expect(cache != nil)
        #expect(cache?.path == dir)
        #expect(cache?.inlineThreshold == UInt(1024 * 20))
    }

    @Test func initWithInlineThreshold() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = DiskCache(path: dir, inlineThreshold: 0)
        #expect(cache != nil)
        #expect(cache?.inlineThreshold == 0)
    }

    @Test func initWithInlineThresholdMax() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = DiskCache(path: dir, inlineThreshold: .max)
        #expect(cache != nil)
        #expect(cache?.inlineThreshold == .max)
    }

    @Test func initWithEmptyPathFails() {
        let cache = DiskCache(path: "")
        #expect(cache == nil)
    }

    @Test func defaultLimits() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }
        #expect(cache.countLimit == .max)
        #expect(cache.costLimit == .max)
        #expect(cache.ageLimit == .greatestFiniteMagnitude)
        #expect(cache.freeDiskSpaceLimit == 0)
        #expect(cache.autoTrimInterval == 60)
    }

    // MARK: - Global Instance Deduplication

    @Test func sharedReturnsExistingInstance() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let first = DiskCache.shared(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }
        let second = DiskCache.shared(path: dir)
        #expect(first === second)
    }

    @Test func sharedCreatesNewIfNoExisting() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = DiskCache.shared(path: dir)
        #expect(cache != nil)
        #expect(cache?.path == dir)
    }

    // MARK: - Basic CRUD

    @Test func setAndGetObject() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        let key = "key1"
        let value: NSString = "hello world"
        cache.setObject(value, forKey: key)

        let retrieved = cache.object(forKey: key) as? NSString
        #expect(retrieved == value)
    }

    @Test func containsObject() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        #expect(cache.containsObject(forKey: "missing") == false)
        cache.setObject(NSString(string: "v"), forKey: "k")
        #expect(cache.containsObject(forKey: "k") == true)
    }

    @Test func removeObject() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "v"), forKey: "k")
        #expect(cache.containsObject(forKey: "k") == true)
        cache.removeObject(forKey: "k")
        #expect(cache.containsObject(forKey: "k") == false)
    }

    @Test func setNilRemovesObject() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "v"), forKey: "k")
        #expect(cache.containsObject(forKey: "k") == true)
        cache.setObject(nil, forKey: "k")
        #expect(cache.containsObject(forKey: "k") == false)
    }

    @Test func emptyKeyHasNoEffect() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "v"), forKey: "")
        #expect(cache.totalCount() == 0)
        #expect(cache.containsObject(forKey: "") == false)
        #expect(cache.object(forKey: "") == nil)
    }

    // MARK: - Remove All

    @Test func removeAllObjects() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        for i in 0..<10 {
            cache.setObject(NSNumber(value: i), forKey: "key\(i)")
        }
        #expect(cache.totalCount() == 10)
        cache.removeAllObjects()
        #expect(cache.totalCount() == 0)
    }

    // MARK: - Total Count & Cost

    @Test func totalCountAndCost() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        #expect(cache.totalCount() == 0)
        #expect(cache.totalCost() == 0)

        cache.setObject(NSString(string: "hello"), forKey: "k1")
        cache.setObject(NSString(string: "world"), forKey: "k2")
        #expect(cache.totalCount() == 2)
        #expect(cache.totalCost() > 0)
    }

    // MARK: - Inline Threshold / Storage Type Selection

    @Test func smallValueStoredInline() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir, inlineThreshold: 1024) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "small"), forKey: "k")

        let dataDir = (dir as NSString).appendingPathComponent("data")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dataDir)) ?? []
        #expect(contents.isEmpty)
        #expect(cache.containsObject(forKey: "k") == true)
    }

    @Test func largeValueStoredAsFile() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir, inlineThreshold: 128) else {
            Issue.record("Failed to create cache")
            return
        }

        let big = NSData(data: Data(repeating: 0x42, count: 2048))
        cache.setObject(big, forKey: "bigKey")

        let dataDir = (dir as NSString).appendingPathComponent("data")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dataDir)) ?? []
        #expect(contents.count == 1)

        let retrieved = cache.object(forKey: "bigKey") as? NSData
        #expect(retrieved == big)
    }

    @Test func allFileModeZeroThreshold() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir, inlineThreshold: 0) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "anything"), forKey: "k")
        let dataDir = (dir as NSString).appendingPathComponent("data")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dataDir)) ?? []
        #expect(contents.count == 1)
    }

    @Test func allSQLiteModeMaxThreshold() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir, inlineThreshold: .max) else {
            Issue.record("Failed to create cache")
            return
        }

        let big = NSData(data: Data(repeating: 0x42, count: 100_000))
        cache.setObject(big, forKey: "k")

        let dataDir = (dir as NSString).appendingPathComponent("data")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dataDir)) ?? []
        #expect(contents.isEmpty)

        let retrieved = cache.object(forKey: "k") as? NSData
        #expect(retrieved == big)
    }

    // MARK: - Trim

    @Test func trimToCount() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        for i in 0..<10 {
            cache.setObject(NSNumber(value: i), forKey: "k\(i)")
        }
        #expect(cache.totalCount() == 10)
        cache.trimToCount(3)
        #expect(cache.totalCount() <= 3)
    }

    @Test func trimToCost() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        for i in 0..<5 {
            let data = NSData(data: Data(repeating: UInt8(i), count: 1000))
            cache.setObject(data, forKey: "k\(i)")
        }
        let before = cache.totalCost()
        #expect(before > 0)
        cache.trimToCost(500)
        #expect(cache.totalCost() <= 500)
    }

    @Test func trimToAgeZeroRemovesAll() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "a"), forKey: "k")
        #expect(cache.totalCount() == 1)
        cache.trimToAge(0)
        #expect(cache.totalCount() == 0)
    }

    // MARK: - Custom Archive / Unarchive

    @Test func customArchiveAndUnarchive() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.customArchiveBlock = { object in
            guard let str = object as? NSString else { return nil }
            return (str as String).data(using: .utf8)
        }
        cache.customUnarchiveBlock = { data in
            String(data: data, encoding: .utf8).map(NSString.init(string:))
        }

        cache.setObject(NSString(string: "custom data"), forKey: "k")
        let retrieved = cache.object(forKey: "k") as? NSString
        #expect(retrieved == NSString(string: "custom data"))
    }

    // MARK: - Custom Filename Block

    @Test func customFileNameBlock() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir, inlineThreshold: 10) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.customFileNameBlock = { key in
            return "custom_\(key).dat"
        }

        let big = NSData(data: Data(repeating: 0x20, count: 512))
        cache.setObject(big, forKey: "myKey")

        let dataDir = (dir as NSString).appendingPathComponent("data")
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dataDir)) ?? []
        #expect(contents.contains("custom_myKey.dat"))
    }

    // MARK: - Extended Data

    @Test func extendedDataRoundTrip() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        let object = NSString(string: "payload")
        let extended = Data("meta".utf8)
        DiskCache.setExtendedData(extended, to: object)
        #expect(DiskCache.getExtendedData(from: object) == extended)

        cache.setObject(object, forKey: "k")
        let retrieved = cache.object(forKey: "k") as? NSString
        #expect(retrieved == object)
        #expect(DiskCache.getExtendedData(from: retrieved!) == extended)
    }

    @Test func extendedDataRemoval() {
        let object = NSString(string: "x")
        let data = Data("x".utf8)
        DiskCache.setExtendedData(data, to: object)
        #expect(DiskCache.getExtendedData(from: object) == data)
        DiskCache.setExtendedData(nil, to: object)
        #expect(DiskCache.getExtendedData(from: object) == nil)
    }

    // MARK: - Error Logs

    @Test func errorLogsEnabledProperty() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }
        #expect(cache.errorLogsEnabled == true)
        cache.errorLogsEnabled = false
        #expect(cache.errorLogsEnabled == false)
    }

    // MARK: - Description

    @Test func descriptionWithoutName() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }
        #expect(cache.description.contains(dir))
        #expect(cache.description.contains("DiskCache"))
    }

    @Test func descriptionWithName() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }
        cache.name = "test-cache"
        #expect(cache.description.contains("test-cache"))
        #expect(cache.description.contains(dir))
    }

    // MARK: - Async methods

    @Test func asyncContainsObject() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "v"), forKey: "k")

        let contains: Bool = await withCheckedContinuation { continuation in
            cache.containsObject(forKey: "k") { _, contains in
                continuation.resume(returning: contains)
            }
        }
        #expect(contains == true)
    }

    @Test func asyncObjectForKey() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "async-value"), forKey: "k")

        let retrieved: String? = await withCheckedContinuation { continuation in
            cache.object(forKey: "k") { _, object in
                continuation.resume(returning: (object as? NSString) as String?)
            }
        }
        #expect(retrieved == "async-value")
    }

    @Test func asyncSetObject() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        await withCheckedContinuation { continuation in
            cache.setObject(NSString(string: "async"), forKey: "k") {
                continuation.resume()
            }
        }
        #expect(cache.containsObject(forKey: "k") == true)
    }

    @Test func asyncRemoveObject() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "v"), forKey: "k")

        await withCheckedContinuation { continuation in
            cache.removeObject(forKey: "k") { _ in
                continuation.resume()
            }
        }
        #expect(cache.containsObject(forKey: "k") == false)
    }

    @Test func asyncRemoveAllObjects() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        for i in 0..<5 {
            cache.setObject(NSNumber(value: i), forKey: "k\(i)")
        }

        await withCheckedContinuation { continuation in
            cache.removeAllObjects {
                continuation.resume()
            }
        }
        #expect(cache.totalCount() == 0)
    }

    @Test func asyncRemoveAllObjectsWithProgress() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        for i in 0..<5 {
            cache.setObject(NSNumber(value: i), forKey: "k\(i)")
        }

        let error: Bool = await withCheckedContinuation { continuation in
            cache.removeAllObjects(progress: nil) { error in
                continuation.resume(returning: error)
            }
        }
        #expect(error == false)
        #expect(cache.totalCount() == 0)
    }

    @Test func asyncTotalCountAndCost() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "a"), forKey: "k1")
        cache.setObject(NSString(string: "b"), forKey: "k2")

        let count: Int = await withCheckedContinuation { continuation in
            cache.totalCount { count in
                continuation.resume(returning: count)
            }
        }
        #expect(count == 2)

        let cost: Int = await withCheckedContinuation { continuation in
            cache.totalCost { cost in
                continuation.resume(returning: cost)
            }
        }
        #expect(cost > 0)
    }

    @Test func asyncTrimToCount() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = DiskCache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        for i in 0..<10 {
            cache.setObject(NSNumber(value: i), forKey: "k\(i)")
        }

        await withCheckedContinuation { continuation in
            cache.trimToCount(3) {
                continuation.resume()
            }
        }
        #expect(cache.totalCount() <= 3)
    }

    // MARK: - Persistence across instances

    @Test func persistenceAcrossInstances() {
        let dir = makeTempDir()
        defer { cleanup(dir) }

        do {
            guard let cache = DiskCache(path: dir) else {
                Issue.record("Failed to create first cache")
                return
            }
            cache.setObject(NSString(string: "persisted"), forKey: "k")
            #expect(cache.object(forKey: "k") as? NSString == NSString(string: "persisted"))
        }

        // After first cache goes out of scope, create a new instance on the same path
        guard let cache2 = DiskCache(path: dir) else {
            Issue.record("Failed to create second cache")
            return
        }
        let retrieved = cache2.object(forKey: "k") as? NSString
        #expect(retrieved == NSString(string: "persisted"))
    }
}
