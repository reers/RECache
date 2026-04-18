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
        let cache = DiskCache<String, User>(path: dir, transformer: Transformers.codable())!
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
            transformer: Transformers.codable(format: .binaryPlist)
        )!
        let user = User(id: 2, name: "Bob", tags: [])
        try cache.set(user, forKey: "u2")
        let fetched = try cache.value(forKey: "u2")
        #expect(fetched == user)
    }

    @Test func dataTransformer() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Data>(path: dir, transformer: Transformers.data())!
        let payload = Data((0..<256).map { UInt8($0 & 0xff) })
        try cache.set(payload, forKey: "blob")
        let back = try cache.value(forKey: "blob")
        #expect(back == payload)
    }

    @Test func missReturnsNil() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: Transformers.codable())!
        #expect(try cache.value(forKey: "missing") == nil)
    }

    @Test func setNilRemoves() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: Transformers.codable())!
        try cache.set(1, forKey: "a")
        try cache.set(nil, forKey: "a")
        #expect(try cache.value(forKey: "a") == nil)
    }

    @Test func remove() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: Transformers.codable())!
        try cache.set(1, forKey: "a")
        cache.remove(forKey: "a")
        #expect(try cache.value(forKey: "a") == nil)
    }

    @Test func removeAll() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: Transformers.codable())!
        for i in 0..<20 { try cache.set(i, forKey: "k\(i)") }
        cache.removeAll()
        #expect(cache.totalCount() == 0)
    }

    // MARK: - Extended data

    @Test func extendedDataRoundtrip() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, User>(path: dir, transformer: Transformers.codable())!
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
        let cache = DiskCache<String, Int>(path: dir, transformer: Transformers.codable())!
        let meta = Data([1, 2, 3])
        try cache.set(42, forKey: "k", extendedData: meta)
        cache.remove(forKey: "k")
        #expect(cache.extendedData(forKey: "k") == nil)
    }

    // MARK: - Expiration

    @Test func cacheLevelExpirationSeconds() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: Transformers.codable())!
        cache.expiration = .seconds(1)
        try await cache.set(1, forKey: "a")
        #expect(try await cache.value(forKey: "a") == 1)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(try await cache.value(forKey: "a") == nil)
    }

    @Test func cacheLevelExpirationDatePast() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: Transformers.codable())!
        try cache.set(1, forKey: "a")
        #expect(try cache.value(forKey: "a") == 1)
        cache.expiration = .date(Date(timeIntervalSinceNow: -10))
        #expect(try cache.value(forKey: "a") == nil)
    }

    @Test func cacheLevelExpirationNeverKeepsEntries() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: Transformers.codable())!
        try await cache.set(1, forKey: "a")
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(try await cache.value(forKey: "a") == 1)
    }

    // MARK: - Large values land in files (mixed type)

    @Test func largeValueGoesToFile() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Data>(
            path: dir,
            transformer: Transformers.data(),
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
        let cache = DiskCache<String, User>(path: dir, transformer: Transformers.codable())!
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
        let cache = DiskCache<String, Int>(path: dir, transformer: Transformers.codable())!
        try await cache.set(1, forKey: "k", extendedData: Data([9, 9, 9]))
        let ed = await cache.extendedData(forKey: "k")
        #expect(ed == Data([9, 9, 9]))
    }

    // MARK: - Int keys

    @Test func intKeyRoundtrip() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<Int, String>(path: dir, transformer: Transformers.codable())!
        try cache.set("one", forKey: 1)
        try cache.set("two", forKey: 2)
        #expect(try cache.value(forKey: 1) == "one")
        #expect(try cache.value(forKey: 2) == "two")
    }

    // MARK: - Trim

    @Test func trimToCount() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Int>(path: dir, transformer: Transformers.codable())!
        for i in 0..<20 { try cache.set(i, forKey: "k\(i)") }
        cache.trim(toCount: 5)
        #expect(cache.totalCount() <= 5)
    }

    @Test func persistsAcrossInstances() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        do {
            let cache = DiskCache<String, User>(path: dir, transformer: Transformers.codable())!
            try cache.set(User(id: 1, name: "X", tags: []), forKey: "u")
        }
        let cache2 = DiskCache<String, User>(path: dir, transformer: Transformers.codable())!
        let u = try cache2.value(forKey: "u")
        #expect(u?.id == 1)
    }
}
