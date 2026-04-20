import Testing
import Foundation
@testable import RECache

@Suite("Cache")
struct CacheTests {

    private static func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "CacheTests/\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    struct Profile: Codable, Sendable, Equatable {
        let id: Int
        let handle: String
    }

    // MARK: - Init

    @Test func initWithName() {
        let cache = Cache<String, Profile>(name: "RECacheTests-\(UUID().uuidString)",
                                           transformer: .codable())
        #expect(cache != nil)
        cache?.removeAll()
    }

    @Test func initWithPath() {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir, transformer: .codable())
        #expect(cache != nil)
    }

    // MARK: - Auto Transformer

    /// Enumerate exactly one blob under `<cachePath>/data`. Requires the
    /// surrounding ``DiskCache`` to be built with `inlineThreshold: 0` so
    /// values never go through SQLite.
    private static func onlyBlob(in cachePath: String) throws -> Data {
        let dataDir = (cachePath as NSString).appendingPathComponent("data")
        let files = try FileManager.default.contentsOfDirectory(atPath: dataDir)
        #expect(files.count == 1)
        let url = URL(fileURLWithPath: (dataDir as NSString).appendingPathComponent(files[0]))
        return try Data(contentsOf: url)
    }

    /// `DiskCache<_, Data>(path:)` resolves to the identity
    /// ``Transformer/data()`` — overload resolution prefers the same-type
    /// constraint (`Value == Data`) over the `Value: Codable` overload.
    /// Verified by reading the on-disk blob byte-for-byte.
    @Test func autoInitPicksDataTransformer() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Data>(path: dir, inlineThreshold: 0)
        try #require(cache != nil)

        let bytes = Data([0x00, 0xFF, 0x10, 0x20, 0xAB])
        try cache!.set(bytes, forKey: "k")

        let blob = try Self.onlyBlob(in: dir)
        #expect(blob == bytes)
    }

    /// `DiskCache<_, Codable>(path:)` resolves to ``Transformer/codable()``
    /// with `.json` as the default format. Verified by decoding the raw blob.
    @Test func autoInitPicksCodableTransformer() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Profile>(path: dir, inlineThreshold: 0)
        try #require(cache != nil)

        let value = Profile(id: 42, handle: "foo")
        try cache!.set(value, forKey: "k")

        let blob = try Self.onlyBlob(in: dir)
        let decoded = try JSONDecoder().decode(Profile.self, from: blob)
        #expect(decoded == value)
    }

    /// Passing `format:` on the Codable overload selects binary plist.
    @Test func autoInitCodableBinaryPlist() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = DiskCache<String, Profile>(path: dir, format: .binaryPlist, inlineThreshold: 0)
        try #require(cache != nil)

        let value = Profile(id: 7, handle: "plist")
        try cache!.set(value, forKey: "k")

        let blob = try Self.onlyBlob(in: dir)
        let decoded = try PropertyListDecoder().decode(Profile.self, from: blob)
        #expect(decoded == value)
    }

    /// End-to-end round-trip for the top-level ``Cache`` using the auto
    /// initializer, confirming the Codable overload is selected and functional.
    @Test func autoInitCacheRoundTripsCodable() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir)
        try #require(cache != nil)

        let value = Profile(id: 99, handle: "auto")
        try cache!.set(value, forKey: "k")
        #expect(try cache!.value(forKey: "k") == value)
    }

    @Test func initFailsOnEmptyPath() {
        let cache = Cache<String, Profile>(path: "", transformer: .codable())
        #expect(cache == nil)
    }

    // MARK: - Two-tier behavior

    @Test func setGoesToBothLayers() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir, transformer: .codable())!
        let p = Profile(id: 1, handle: "alice")
        try cache.set(p, forKey: "a")
        #expect(cache.memoryCache.contains("a"))
        #expect(cache.diskCache.contains("a"))
    }

    @Test func diskHitRepopulatesMemory() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir, transformer: .codable())!
        let p = Profile(id: 2, handle: "bob")
        try cache.set(p, forKey: "b")
        cache.memoryCache.removeAll()
        #expect(!cache.memoryCache.contains("b"))
        let fetched = try cache.value(forKey: "b")
        #expect(fetched == p)
        #expect(cache.memoryCache.contains("b"))
    }

    @Test func removeAffectsBothLayers() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir, transformer: .codable())!
        try cache.set(Profile(id: 3, handle: "carol"), forKey: "c")
        cache.remove(forKey: "c")
        #expect(!cache.memoryCache.contains("c"))
        #expect(!cache.diskCache.contains("c"))
    }

    @Test func removeAllAffectsBothLayers() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir, transformer: .codable())!
        for i in 0..<10 {
            try cache.set(Profile(id: i, handle: "h\(i)"), forKey: "k\(i)")
        }
        cache.removeAll()
        #expect(cache.memoryCache.totalCount == 0)
        #expect(cache.diskCache.totalCount() == 0)
    }

    // MARK: - setNil

    @Test func setNilRemoves() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir, transformer: .codable())!
        try cache.set(Profile(id: 1, handle: "x"), forKey: "k")
        try cache.set(nil, forKey: "k")
        #expect(!cache.contains("k"))
    }

    // MARK: - Extended data bubbles through

    @Test func extendedDataPersisted() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir, transformer: .codable())!
        let meta = "v=1".data(using: .utf8)!
        try cache.set(Profile(id: 1, handle: "e"), forKey: "k", extendedData: meta)
        #expect(cache.extendedData(forKey: "k") == meta)
    }

    // MARK: - Expiration

    @Test func cacheLevelExpirationAppliesToBothLayers() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir, transformer: .codable())!
        cache.memoryCache.expiration = .seconds(0.1)
        cache.diskCache.expiration = .seconds(1)
        try await cache.set(Profile(id: 1, handle: "e"), forKey: "k")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        #expect(await cache.memoryCache.value(forKey: "k") == nil)
        #expect(try await cache.diskCache.value(forKey: "k") == nil)
        #expect(try await cache.value(forKey: "k") == nil)
    }

    // MARK: - Async

    @Test func asyncRoundtrip() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir, transformer: .codable())!
        let p = Profile(id: 9, handle: "z")
        try await cache.set(p, forKey: "k")
        let fetched = try await cache.value(forKey: "k")
        #expect(fetched == p)
        await cache.remove(forKey: "k")
        #expect(!(await cache.contains("k")))
    }

    // MARK: - Int keys

    @Test func intKeyRoundtrip() throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<Int, String>(path: dir, transformer: .codable())!
        try cache.set("hello", forKey: 1)
        #expect(try cache.value(forKey: 1) == "hello")
    }

    // MARK: - Async disk-hit repopulates memory

    @Test func asyncDiskHitRepopulatesMemory() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir, transformer: .codable())!
        let p = Profile(id: 7, handle: "async-disk")
        try await cache.set(p, forKey: "k")
        await cache.memoryCache.removeAll()
        #expect(!(await cache.memoryCache.contains("k")))
        let fetched = try await cache.value(forKey: "k")
        #expect(fetched == p)
        #expect(await cache.memoryCache.contains("k"))
    }

    @Test func asyncValueMissReturnsNil() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir, transformer: .codable())!
        #expect(try await cache.value(forKey: "absent") == nil)
    }

    // MARK: - Async removeAll / setNil / contains miss

    @Test func asyncRemoveAllClearsBothLayers() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir, transformer: .codable())!
        for i in 0..<5 {
            try await cache.set(Profile(id: i, handle: "h\(i)"), forKey: "k\(i)")
        }
        await cache.removeAll()
        #expect(cache.memoryCache.totalCount == 0)
        #expect(cache.diskCache.totalCount() == 0)
    }

    @Test func asyncSetNilRemovesFromBothLayers() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir, transformer: .codable())!
        try await cache.set(Profile(id: 1, handle: "x"), forKey: "k")
        try await cache.set(nil, forKey: "k")
        #expect(!(await cache.contains("k")))
    }

    @Test func asyncContainsMiss() async {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir, transformer: .codable())!
        #expect(!(await cache.contains("nope")))
    }

    // MARK: - asyncRemoveAll (progress + completion)

    @Test func asyncRemoveAllWithProgressCallbacks() async throws {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir, transformer: .codable())!
        for i in 0..<4 {
            try await cache.set(Profile(id: i, handle: "h\(i)"), forKey: "k\(i)")
        }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            cache.asyncRemoveAll(progress: { _, _ in }) { error in
                #expect(error == false)
                cont.resume()
            }
        }
        #expect(cache.diskCache.totalCount() == 0)
        #expect(cache.memoryCache.totalCount == 0)
    }

    // MARK: - Description

    @Test func descriptionIncludesName() {
        let dir = Self.makeTempDir(); defer { Self.cleanup(dir) }
        let cache = Cache<String, Profile>(path: dir, transformer: .codable())!
        #expect(cache.description.contains(cache.name))
    }
}
