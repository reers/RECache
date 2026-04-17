import Testing
import Foundation
@testable import RECache

@Suite("Cache")
struct CacheTests {

    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "CacheTests/\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Initialization

    @Test func initWithPath() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let cache = Cache(path: dir)
        #expect(cache != nil)
        #expect(cache?.name == (dir as NSString).lastPathComponent)
        #expect(cache?.diskCache.path == dir)
        #expect(cache?.memoryCache.name == (dir as NSString).lastPathComponent)
    }

    @Test func initWithEmptyPathFails() {
        let cache = Cache(path: "")
        #expect(cache == nil)
    }

    @Test func initWithName() {
        let name = "CacheTests-\(UUID().uuidString)"
        guard let cache = Cache(name: name) else {
            Issue.record("Failed to create cache with name")
            return
        }
        defer { cleanup(cache.diskCache.path) }
        #expect(cache.name == name)
        #expect(cache.diskCache.path.hasSuffix(name))
    }

    @Test func initWithEmptyNameFails() {
        let cache = Cache(name: "")
        #expect(cache == nil)
    }

    // MARK: - Basic CRUD

    @Test func setAndGetObject() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
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
        guard let cache = Cache(path: dir) else {
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
        guard let cache = Cache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "v"), forKey: "k")
        #expect(cache.containsObject(forKey: "k") == true)
        cache.removeObject(forKey: "k")
        #expect(cache.containsObject(forKey: "k") == false)
        #expect(cache.memoryCache.containsObject(forKey: "k") == false)
        #expect(cache.diskCache.containsObject(forKey: "k") == false)
    }

    @Test func setNilRemovesObject() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "v"), forKey: "k")
        #expect(cache.containsObject(forKey: "k") == true)
        cache.setObject(nil, forKey: "k")
        #expect(cache.containsObject(forKey: "k") == false)
    }

    @Test func removeAllObjects() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        for i in 0..<10 {
            cache.setObject(NSNumber(value: i), forKey: "key\(i)")
        }
        #expect(cache.memoryCache.totalCount == 10)
        #expect(cache.diskCache.totalCount() == 10)

        cache.removeAllObjects()
        #expect(cache.memoryCache.totalCount == 0)
        #expect(cache.diskCache.totalCount() == 0)
    }

    // MARK: - Memory / Disk Coordination

    @Test func objectIsCachedInMemoryAfterDiskHit() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "value"), forKey: "k")

        cache.memoryCache.removeAllObjects()
        #expect(cache.memoryCache.containsObject(forKey: "k") == false)

        let retrieved = cache.object(forKey: "k") as? NSString
        #expect(retrieved == NSString(string: "value"))
        #expect(cache.memoryCache.containsObject(forKey: "k") == true)
    }

    @Test func memoryHitShortCircuitsDiskLookup() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.memoryCache.setObject(NSCodingBox(NSString(string: "memOnly")), forKey: "k")
        let retrieved = cache.object(forKey: "k") as? NSString
        #expect(retrieved == NSString(string: "memOnly"))
        #expect(cache.diskCache.containsObject(forKey: "k") == false)
    }

    @Test func setObjectWritesBothLayers() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "v"), forKey: "k")
        #expect(cache.memoryCache.containsObject(forKey: "k") == true)
        #expect(cache.diskCache.containsObject(forKey: "k") == true)
    }

    // MARK: - NSCodingBox

    @Test func nsCodingBoxPreservesValue() {
        let value = NSString(string: "boxed")
        let box = NSCodingBox(value)
        #expect((box.value as? NSString) == value)
    }

    @Test func multipleValueTypes() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        let string: NSString = "string-value"
        let number = NSNumber(value: 42)
        let data = NSData(data: Data("some data".utf8))
        let array = NSArray(array: [NSString(string: "a"), NSNumber(value: 1)])

        cache.setObject(string, forKey: "s")
        cache.setObject(number, forKey: "n")
        cache.setObject(data, forKey: "d")
        cache.setObject(array, forKey: "a")

        #expect((cache.object(forKey: "s") as? NSString) == string)
        #expect((cache.object(forKey: "n") as? NSNumber) == number)
        #expect((cache.object(forKey: "d") as? NSData) == data)
        #expect((cache.object(forKey: "a") as? NSArray) == array)
    }

    // MARK: - Description

    @Test func description() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }
        #expect(cache.description.contains("Cache"))
        #expect(cache.description.contains(cache.name))
    }

    // MARK: - Async (block-based) methods

    @Test func asyncContainsObjectMemoryHit() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
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

    @Test func asyncContainsObjectDiskHit() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "v"), forKey: "k")
        cache.memoryCache.removeAllObjects()

        let contains: Bool = await withCheckedContinuation { continuation in
            cache.containsObject(forKey: "k") { _, contains in
                continuation.resume(returning: contains)
            }
        }
        #expect(contains == true)
    }

    @Test func asyncContainsObjectMissing() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        let contains: Bool = await withCheckedContinuation { continuation in
            cache.containsObject(forKey: "missing") { _, contains in
                continuation.resume(returning: contains)
            }
        }
        #expect(contains == false)
    }

    @Test func asyncObjectForKeyMemoryHit() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
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

    @Test func asyncObjectForKeyPromotesToMemory() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "disk-value"), forKey: "k")
        cache.memoryCache.removeAllObjects()

        let retrieved: String? = await withCheckedContinuation { continuation in
            cache.object(forKey: "k") { _, object in
                continuation.resume(returning: (object as? NSString) as String?)
            }
        }
        #expect(retrieved == "disk-value")
        #expect(cache.memoryCache.containsObject(forKey: "k") == true)
    }

    @Test func asyncSetObject() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        await withCheckedContinuation { continuation in
            cache.setObject(NSString(string: "async"), forKey: "k") {
                continuation.resume()
            }
        }
        #expect(cache.memoryCache.containsObject(forKey: "k") == true)
        #expect(cache.diskCache.containsObject(forKey: "k") == true)
    }

    @Test func asyncSetNilRemovesObject() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.setObject(NSString(string: "v"), forKey: "k")

        await withCheckedContinuation { continuation in
            cache.setObject(nil, forKey: "k") {
                continuation.resume()
            }
        }
        #expect(cache.containsObject(forKey: "k") == false)
    }

    @Test func asyncRemoveObject() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
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
        guard let cache = Cache(path: dir) else {
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
        #expect(cache.memoryCache.totalCount == 0)
        #expect(cache.diskCache.totalCount() == 0)
    }

    @Test func asyncRemoveAllObjectsWithProgress() async {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
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
        #expect(cache.memoryCache.totalCount == 0)
        #expect(cache.diskCache.totalCount() == 0)
    }

    @Test func asyncCallbacksWithNilBlocksHaveNoEffect() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let cache = Cache(path: dir) else {
            Issue.record("Failed to create cache")
            return
        }

        cache.containsObject(forKey: "k", block: nil)
        cache.object(forKey: "k", block: nil)
        cache.setObject(NSString(string: "v"), forKey: "k", block: nil)
        cache.removeObject(forKey: "k", block: nil)
        cache.removeAllObjects(block: nil)
    }
}
