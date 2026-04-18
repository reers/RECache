import Testing
import Foundation
@testable import RECache

@Suite("DiskCache")
struct DiskCacheTests {

    // MARK: - Fixtures

    private static func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "DiskCacheTests/\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    struct User: Codable, Sendable, Equatable {
        let id: Int
        let name: String
        let tags: [String]
    }

    // MARK: - Basic CRUD with Codable transformer

    @Test func codableRoundtrip() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, User>(path: dir, transformer: .codable())!
        let user = User(id: 1, name: "Alice", tags: ["a", "b"])
        try cache.set(user, forKey: "u1")
        #expect(cache.contains("u1"))
        let fetched = try cache.value(forKey: "u1")
        #expect(fetched == user)
    }

    @Test func codableBinaryPlistRoundtrip() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, User>(
            path: dir,
            transformer: .codable(format: .binaryPlist)
        )!
        let user = User(id: 2, name: "Bob", tags: [])
        try cache.set(user, forKey: "u2")
        let fetched = try cache.value(forKey: "u2")
        #expect(fetched == user)
    }

    @Test func dataTransformer() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Data>(path: dir, transformer: .data())!
        let payload = Data((0..<256).map { UInt8($0 & 0xff) })
        try cache.set(payload, forKey: "blob")
        let back = try cache.value(forKey: "blob")
        #expect(back == payload)
    }

    @Test func missReturnsNil() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        #expect(try cache.value(forKey: "missing") == nil)
    }

    @Test func setNilRemoves() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try cache.set(1, forKey: "a")
        try cache.set(nil, forKey: "a")
        #expect(try cache.value(forKey: "a") == nil)
    }

    @Test func remove() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try cache.set(1, forKey: "a")
        cache.remove(forKey: "a")
        #expect(try cache.value(forKey: "a") == nil)
    }

    @Test func removeAll() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        for i in 0..<20 { try cache.set(i, forKey: "k\(i)") }
        cache.removeAll()
        #expect(cache.totalCount() == 0)
    }

    // MARK: - Extended data

    @Test func extendedDataRoundtrip() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, User>(path: dir, transformer: .codable())!
        let meta = "etag:abc123".data(using: .utf8)!
        let user = User(id: 3, name: "Carol", tags: ["x"])
        try cache.set(user, forKey: "u3", extendedData: meta)
        #expect(cache.extendedData(forKey: "u3") == meta)
        let pair = try cache.valueWithExtendedData(forKey: "u3")
        #expect(pair?.value == user)
        #expect(pair?.extendedData == meta)
    }

    @Test func extendedDataNilAfterRemove() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        let meta = Data([1, 2, 3])
        try cache.set(42, forKey: "k", extendedData: meta)
        cache.remove(forKey: "k")
        #expect(cache.extendedData(forKey: "k") == nil)
    }

    // MARK: - Expiration

    @Test func cacheLevelExpirationSeconds() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        cache.expiration = .seconds(1)
        try await cache.set(1, forKey: "a")
        #expect(try await cache.value(forKey: "a") == 1)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(try await cache.value(forKey: "a") == nil)
    }

    @Test func cacheLevelExpirationDatePast() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try cache.set(1, forKey: "a")
        #expect(try cache.value(forKey: "a") == 1)
        cache.expiration = .date(Date(timeIntervalSinceNow: -10))
        #expect(try cache.value(forKey: "a") == nil)
    }

    @Test func cacheLevelExpirationNeverKeepsEntries() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try await cache.set(1, forKey: "a")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(try await cache.value(forKey: "a") == 1)
    }

    // MARK: - Large values land in files (mixed type)

    @Test func largeValueGoesToFile() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Data>(
            path: dir,
            transformer: .data(),
            inlineThreshold: 100
        )!
        let bigBlob = Data(count: 2048)
        try cache.set(bigBlob, forKey: "big")
        let back = try cache.value(forKey: "big")
        #expect(back?.count == 2048)
    }

    // MARK: - Async API

    @Test func asyncRoundtrip() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, User>(path: dir, transformer: .codable())!
        let user = User(id: 10, name: "Dan", tags: [])
        try await cache.set(user, forKey: "u")
        #expect(await cache.contains("u"))
        let fetched = try await cache.value(forKey: "u")
        #expect(fetched == user)
        await cache.remove(forKey: "u")
        #expect(!(await cache.contains("u")))
    }

    @Test func asyncExtendedData() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try await cache.set(1, forKey: "k", extendedData: Data([9, 9, 9]))
        let ed = await cache.extendedData(forKey: "k")
        #expect(ed == Data([9, 9, 9]))
    }

    // MARK: - Int keys

    @Test func intKeyRoundtrip() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<Int, String>(path: dir, transformer: .codable())!
        try cache.set("one", forKey: 1)
        try cache.set("two", forKey: 2)
        #expect(try cache.value(forKey: 1) == "one")
        #expect(try cache.value(forKey: 2) == "two")
    }

    // MARK: - Trim

    @Test func trimToCount() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        for i in 0..<20 { try cache.set(i, forKey: "k\(i)") }
        cache.trim(toCount: 5)
        #expect(cache.totalCount() <= 5)
    }

    @Test func persistsAcrossInstances() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        do {
            let cache = DiskCache<String, User>(path: dir, transformer: .codable())!
            try cache.set(User(id: 1, name: "X", tags: []), forKey: "u")
        }
        let cache2 = DiskCache<String, User>(path: dir, transformer: .codable())!
        let u = try cache2.value(forKey: "u")
        #expect(u?.id == 1)
    }

    // MARK: - Init failures / explicit storage types

    @Test func initFailsOnEmptyPath() {
        let cache = DiskCache<String, Int>(path: "", transformer: .codable())
        #expect(cache == nil)
    }

    @Test func initSQLiteMode() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Data>(
            path: dir,
            transformer: .data(),
            inlineThreshold: .max
        )!
        try cache.set(Data([1, 2, 3]), forKey: "k")
        #expect(try cache.value(forKey: "k") == Data([1, 2, 3]))
    }

    @Test func initFileMode() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Data>(
            path: dir,
            transformer: .data(),
            inlineThreshold: 0
        )!
        try cache.set(Data([9, 8, 7]), forKey: "k")
        #expect(try cache.value(forKey: "k") == Data([9, 8, 7]))
    }

    // MARK: - isLoggingEnabled

    @Test func loggingFlagRoundtrip() {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        #expect(cache.isLoggingEnabled == false)
        cache.isLoggingEnabled = true
        #expect(cache.isLoggingEnabled == true)
        cache.isLoggingEnabled = false
        #expect(cache.isLoggingEnabled == false)
    }

    // MARK: - fileNameProvider

    @Test func customFileNameProviderUsed() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Data>(
            path: dir,
            transformer: .data(),
            inlineThreshold: 10
        )!
        cache.fileNameProvider = { key in "provided-\(key).bin" }
        try cache.set(Data(repeating: 0xAB, count: 256), forKey: "large")
        let expectedPath = (dir as NSString)
            .appendingPathComponent("data") as NSString
        let filePath = expectedPath.appendingPathComponent("provided-large.bin")
        #expect(FileManager.default.fileExists(atPath: filePath))
    }

    @Test func fileNameProviderReturningEmptyFallsBack() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Data>(
            path: dir,
            transformer: .data(),
            inlineThreshold: 10
        )!
        cache.fileNameProvider = { _ in "" }
        try cache.set(Data(repeating: 0x01, count: 200), forKey: "k")
        #expect(try cache.value(forKey: "k")?.count == 200)
    }

    // MARK: - Trim / removeExpired / totalCost

    @Test func trimToCost() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Data>(path: dir, transformer: .data())!
        for i in 0..<10 {
            try cache.set(Data(repeating: UInt8(i), count: 100), forKey: "k\(i)")
        }
        #expect(cache.totalCost() == 1000)
        cache.trim(toCost: 300)
        #expect(cache.totalCost() <= 300)
    }

    @Test func trimToCostIntMaxIsNoOp() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try cache.set(1, forKey: "a")
        cache.trim(toCost: .max)
        #expect(try cache.value(forKey: "a") == 1)
    }

    @Test func trimToCountIntMaxIsNoOp() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try cache.set(1, forKey: "a")
        cache.trim(toCount: .max)
        #expect(try cache.value(forKey: "a") == 1)
    }

    @Test func removeExpiredNeverIsNoOp() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try cache.set(1, forKey: "a")
        cache.removeExpired()
        #expect(try cache.value(forKey: "a") == 1)
    }

    @Test func removeExpiredDatePastWipes() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try cache.set(1, forKey: "a")
        cache.expiration = .date(Date(timeIntervalSinceNow: -5))
        cache.removeExpired()
        #expect(cache.totalCount() == 0)
    }

    @Test func removeExpiredDateFutureKeeps() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try cache.set(1, forKey: "a")
        cache.expiration = .date(Date(timeIntervalSinceNow: 60))
        cache.removeExpired()
        #expect(cache.totalCount() == 1)
    }

    @Test func removeExpiredSeconds() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try await cache.set(1, forKey: "a")
        // Large-but-reasonable window so we exercise the code path without
        // actually deleting the row (otherwise we wait ≥2s real time).
        cache.expiration = .seconds(3600)
        await cache.removeExpired()
        #expect(try await cache.value(forKey: "a") == 1)
    }

    // MARK: - Async API

    @Test func asyncValueWithExtendedData() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try await cache.set(42, forKey: "k", extendedData: Data([1, 2]))
        let pair = try await cache.valueWithExtendedData(forKey: "k")
        #expect(pair?.value == 42)
        #expect(pair?.extendedData == Data([1, 2]))
        let miss = try await cache.valueWithExtendedData(forKey: "nope")
        #expect(miss == nil)
    }

    @Test func asyncRemoveAll() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        for i in 0..<5 { try await cache.set(i, forKey: "k\(i)") }
        await cache.removeAll()
        #expect(cache.totalCount() == 0)
    }

    @Test func asyncRemoveExpired() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try await cache.set(1, forKey: "a")
        cache.expiration = .date(Date(timeIntervalSinceNow: -5))
        await cache.removeExpired()
        #expect(cache.totalCount() == 0)
    }

    @Test func asyncSetNilRemoves() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try await cache.set(1, forKey: "a")
        try await cache.set(nil, forKey: "a")
        #expect(try await cache.value(forKey: "a") == nil)
    }

    @Test func asyncSetEmptyStringKeyIsNoop() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try await cache.set(1, forKey: "")
        #expect(try await cache.value(forKey: "") == nil)
        let hit = await cache.contains("")
        #expect(hit == false)
        let ed = await cache.extendedData(forKey: "")
        #expect(ed == nil)
    }

    @Test func asyncRemoveAllWithProgress() async {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        for i in 0..<5 { try? await cache.set(i, forKey: "k\(i)") }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            cache.asyncRemoveAll(progress: { _, _ in }) { error in
                #expect(error == false)
                cont.resume()
            }
        }
        #expect(cache.totalCount() == 0)
    }

    // MARK: - Description

    @Test func descriptionIncludesPath() {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        #expect(cache.description.contains(dir))
    }

    @Test func descriptionIncludesName() {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        cache.name = "named"
        #expect(cache.description.contains("named"))
    }

    // MARK: - Sync expiration cleanup

    /// Exercises the lazy-removal branch inside synchronous `contains(_:)`
    /// when the stored entry is past its expiration date.
    @Test func syncContainsRemovesExpired() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try cache.set(1, forKey: "a")
        cache.expiration = .date(Date(timeIntervalSinceNow: -5))
        #expect(cache.contains("a") == false)
        #expect(cache.totalCount() == 0)
    }

    /// Exercises the lazy-removal branch inside synchronous
    /// `valueWithExtendedData(forKey:)` when the entry is expired.
    @Test func syncValueWithExtendedDataRemovesExpired() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        try cache.set(1, forKey: "a", extendedData: Data([0x01]))
        cache.expiration = .date(Date(timeIntervalSinceNow: -5))
        let pair = try cache.valueWithExtendedData(forKey: "a")
        #expect(pair == nil)
        #expect(cache.totalCount() == 0)
    }

    // MARK: - Configuration smoke

    /// Smoke test for the tunables. The auto-trim background loop is scheduled
    /// with the `autoTrimInterval` captured at `init` (default 60s), so we
    /// can't reliably reduce it at runtime inside a unit test. We verify that
    /// assigning these knobs doesn't disturb normal operation.
    @Test func tunablesSmoke() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: .codable())!
        cache.countLimit = 100
        cache.costLimit = 10_000
        cache.expiration = .never
        cache.freeDiskSpaceLimit = 1
        cache.autoTrimInterval = 0.1
        try await cache.set(1, forKey: "a")
        #expect(try await cache.value(forKey: "a") == 1)
    }
}
