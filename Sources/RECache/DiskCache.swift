//
//  Copyright © 2015 ibireme.
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
//

#if canImport(UIKit)
import UIKit
#endif
@preconcurrency import Foundation
import CryptoKit
import ObjectiveC.runtime

// MARK: - Associated object key

/// Key for the extended data associated object.
nonisolated(unsafe) private var kExtendedDataKey: UInt8 = 0

// MARK: - Helpers

/// Free disk space in bytes.
private func diskSpaceFree() -> Int64 {
    do {
        let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        guard let size = attrs[.systemFreeSize] as? NSNumber else { return -1 }
        let space = size.int64Value
        return space < 0 ? -1 : space
    } catch {
        return -1
    }
}

/// String's md5 hash. Used only to generate a stable file name from a key;
/// not used in a security context.
private func stringMD5(_ string: String) -> String {
    let digest = Insecure.MD5.hash(data: Data(string.utf8))
    return digest.reduce(into: "") { $0 += String(format: "%02x", $1) }
}

// MARK: - Global instances (weak)

/// Weakly-referenced cache of all live `DiskCache` instances, keyed by path.
/// Using file-level `let` gives us thread-safe lazy initialization, equivalent
/// to the `dispatch_once` pattern used by `YYDiskCache`.
private let globalInstancesLock = DispatchSemaphore(value: 1)
nonisolated(unsafe) private let globalInstances: NSMapTable<NSString, DiskCache> = NSMapTable(
    keyOptions: .strongMemory,
    valueOptions: .weakMemory
)

private func diskCacheGetGlobal(_ path: String) -> DiskCache? {
    if path.isEmpty { return nil }
    globalInstancesLock.wait()
    defer { globalInstancesLock.signal() }
    return globalInstances.object(forKey: path as NSString)
}

private func diskCacheSetGlobal(_ cache: DiskCache) {
    if cache.path.isEmpty { return }
    globalInstancesLock.wait()
    defer { globalInstancesLock.signal() }
    globalInstances.setObject(cache, forKey: cache.path as NSString)
}

// MARK: - DiskCache

/// DiskCache is a thread-safe cache that stores key-value pairs backed by SQLite
/// and file system (similar to NSURLCache's disk cache).
///
/// DiskCache has these features:
///
/// * It use LRU (least-recently-used) to remove objects.
/// * It can be controlled by cost, count, and age.
/// * It can be configured to automatically evict objects when there's no free disk space.
/// * It can automatically decide the storage type (sqlite/file) for each object to get
///      better performance.
///
/// You may compile the latest version of sqlite and ignore the libsqlite3.dylib in
/// iOS system to get 2x~4x speed up.
public final class DiskCache: @unchecked Sendable {

    // MARK: - Attribute

    /// The name of the cache. Default is nil.
    public var name: String?

    /// The path of the cache (read-only).
    public let path: String

    /// If the object's data size (in bytes) is larger than this value, then object will
    /// be stored as a file, otherwise the object will be stored in sqlite.
    ///
    /// 0 means all objects will be stored as separated files, `UInt.max` means all
    /// objects will be stored in sqlite.
    ///
    /// The default value is 20480 (20KB).
    public let inlineThreshold: UInt

    /// If this block is not nil, then the block will be used to archive object instead
    /// of NSKeyedArchiver. You can use this block to support the objects which do not
    /// conform to the `NSCoding` protocol.
    ///
    /// The default value is nil.
    public var customArchiveBlock: ((Any) -> Data?)?

    /// If this block is not nil, then the block will be used to unarchive object instead
    /// of NSKeyedUnarchiver. You can use this block to support the objects which do not
    /// conform to the `NSCoding` protocol.
    ///
    /// The default value is nil.
    public var customUnarchiveBlock: ((Data) -> Any?)?

    /// When an object needs to be saved as a file, this block will be invoked to generate
    /// a file name for a specified key. If the block is nil, the cache use md5(key) as
    /// default file name.
    ///
    /// The default value is nil.
    public var customFileNameBlock: ((String) -> String?)?

    // MARK: - Limit

    /// The maximum number of objects the cache should hold.
    ///
    /// The default value is `UInt.max`, which means no limit.
    /// This is not a strict limit — if the cache goes over the limit, some objects in the
    /// cache could be evicted later in background queue.
    public var countLimit: UInt = .max

    /// The maximum total cost that the cache can hold before it starts evicting objects.
    ///
    /// The default value is `UInt.max`, which means no limit.
    /// This is not a strict limit — if the cache goes over the limit, some objects in the
    /// cache could be evicted later in background queue.
    public var costLimit: UInt = .max

    /// The maximum expiry time of objects in cache.
    ///
    /// The default value is `.greatestFiniteMagnitude`, which means no limit.
    /// This is not a strict limit — if an object goes over the limit, the objects could
    /// be evicted later in background queue.
    public var ageLimit: TimeInterval = .greatestFiniteMagnitude

    /// The minimum free disk space (in bytes) which the cache should kept.
    ///
    /// The default value is 0, which means no limit.
    /// If the free disk space is lower than this value, the cache will remove objects
    /// to free some disk space. This is not a strict limit—if the free disk space goes
    /// over the limit, the objects could be evicted later in background queue.
    public var freeDiskSpaceLimit: UInt = 0

    /// The auto trim check time interval in seconds. Default is 60 (1 minute).
    ///
    /// The cache holds an internal timer to check whether the cache reaches
    /// its limits, and if the limit is reached, it begins to evict objects.
    public var autoTrimInterval: TimeInterval = 60

    /// Set `true` to enable error logs for debug.
    public var errorLogsEnabled: Bool {
        get {
            lock.wait()
            defer { lock.signal() }
            return kv?.errorLogsEnabled ?? false
        }
        set {
            lock.wait()
            defer { lock.signal() }
            kv?.errorLogsEnabled = newValue
        }
    }

    // MARK: - Private Properties

    private var kv: KVStorage?
    private let lock = DispatchSemaphore(value: 1)
    private let queue: DispatchQueue
    #if canImport(UIKit) && !os(watchOS)
    private var terminateObserver: (any NSObjectProtocol)?
    #endif

    // MARK: - Initializer

    /// Create a new cache based on the specified path.
    ///
    /// - Parameter path: Full path of a directory in which the cache will write data.
    ///   Once initialized you should not read and write to this directory.
    /// - Warning: If the cache instance for the specified path already exists in memory,
    ///   prefer `DiskCache.shared(path:)` so you can reuse the existing instance. Swift
    ///   initializers cannot substitute `self` with an already-created instance the way
    ///   `YYDiskCache` does in Objective-C.
    public convenience init?(path: String) {
        self.init(path: path, inlineThreshold: 1024 * 20)
    }

    /// The designated initializer. Returns a new cache object, or nil if an error occurs.
    ///
    /// - Parameters:
    ///   - path: Full path of a directory in which the cache will write data.
    ///     Once initialized you should not read and write to this directory.
    ///   - inlineThreshold: The data store inline threshold in bytes. If the object's
    ///     data size (in bytes) is larger than this value, then object will be stored
    ///     as a file, otherwise the object will be stored in sqlite. 0 means all objects
    ///     will be stored as separated files, `UInt.max` means all objects will be
    ///     stored in sqlite. If you don't know your object's size, 20480 is a good
    ///     choice. After first initialized you should not change this value of the
    ///     specified path.
    /// - Warning: If the cache instance for the specified path already exists in memory,
    ///   prefer `DiskCache.shared(path:inlineThreshold:)` so you can reuse the existing
    ///   instance. Swift initializers cannot substitute `self` with an already-created
    ///   instance the way `YYDiskCache` does in Objective-C.
    public init?(path: String, inlineThreshold: UInt) {
        let type: KVStorageType
        if inlineThreshold == 0 {
            type = .file
        } else if inlineThreshold == .max {
            type = .sqlite
        } else {
            type = .mixed
        }

        guard let kv = KVStorage(path: path, type: type) else { return nil }

        self.kv = kv
        self.path = path
        self.inlineThreshold = inlineThreshold
        self.queue = DispatchQueue(label: "com.reers.cache.disk", attributes: .concurrent)

        trimRecursively()
        diskCacheSetGlobal(self)

        #if canImport(UIKit) && !os(watchOS)
        terminateObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.appWillBeTerminated()
        }
        #endif
    }

    /// Returns an existing live `DiskCache` instance for the given path if one exists,
    /// otherwise creates and returns a new instance. This mirrors the deduplication
    /// behavior of `YYDiskCache`'s `initWithPath:` in a Swift-friendly way.
    ///
    /// - Parameter path: Full path of a directory in which the cache will write data.
    /// - Returns: A cache object, or nil if an error occurs.
    public static func shared(path: String) -> DiskCache? {
        return shared(path: path, inlineThreshold: 1024 * 20)
    }

    /// Returns an existing live `DiskCache` instance for the given path if one exists,
    /// otherwise creates and returns a new instance. This mirrors the deduplication
    /// behavior of `YYDiskCache`'s `initWithPath:inlineThreshold:` in a Swift-friendly
    /// way.
    ///
    /// - Parameters:
    ///   - path: Full path of a directory in which the cache will write data.
    ///   - inlineThreshold: The data store inline threshold in bytes.
    /// - Returns: A cache object, or nil if an error occurs.
    public static func shared(path: String, inlineThreshold: UInt) -> DiskCache? {
        if let existing = diskCacheGetGlobal(path) { return existing }
        return DiskCache(path: path, inlineThreshold: inlineThreshold)
    }

    deinit {
        #if canImport(UIKit) && !os(watchOS)
        if let observer = terminateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
    }

    // MARK: - Private Trim

    private func trimRecursively() {
        DispatchQueue
            .global(qos: .utility)
            .asyncAfter(deadline: .now() + autoTrimInterval) { [weak self] in
                guard let self else { return }
                trimInBackground()
                trimRecursively()
            }
    }

    private func trimInBackground() {
        queue.async { [weak self] in
            guard let self else { return }
            lock.wait()
            _trimToCost(costLimit)
            _trimToCount(countLimit)
            _trimToAge(ageLimit)
            _trimToFreeDiskSpace(freeDiskSpaceLimit)
            lock.signal()
        }
    }

    private func _trimToCost(_ costLimit: UInt) {
        if costLimit >= UInt(Int32.max) { return }
        kv?.removeItemsToFitSize(Int32(costLimit))
    }

    private func _trimToCount(_ countLimit: UInt) {
        if countLimit >= UInt(Int32.max) { return }
        kv?.removeItemsToFitCount(Int32(countLimit))
    }

    private func _trimToAge(_ ageLimit: TimeInterval) {
        if ageLimit <= 0 {
            kv?.removeAllItems()
            return
        }
        let timestamp = TimeInterval(time(nil))
        if timestamp <= ageLimit { return }
        let age = timestamp - ageLimit
        if age >= TimeInterval(Int32.max) { return }
        kv?.removeItemsEarlierThanTime(Int32(age))
    }

    private func _trimToFreeDiskSpace(_ targetFreeDiskSpace: UInt) {
        if targetFreeDiskSpace == 0 { return }
        let totalBytes = Int64(kv?.getItemsSize() ?? 0)
        if totalBytes <= 0 { return }
        let diskFreeBytes = diskSpaceFree()
        if diskFreeBytes < 0 { return }
        let needTrimBytes = Int64(targetFreeDiskSpace) - diskFreeBytes
        if needTrimBytes <= 0 { return }
        var costLimit = totalBytes - needTrimBytes
        if costLimit < 0 { costLimit = 0 }
        _trimToCost(UInt(costLimit))
    }

    private func filenameForKey(_ key: String) -> String {
        if let customFileNameBlock = customFileNameBlock,
           let filename = customFileNameBlock(key),
           !filename.isEmpty {
            return filename
        }
        return stringMD5(key)
    }

    private func appWillBeTerminated() {
        lock.wait()
        kv = nil
        lock.signal()
    }

    // MARK: - Access Methods

    /// Returns a boolean value that indicates whether a given key is in cache.
    /// This method may blocks the calling thread until file read finished.
    ///
    /// - Parameter key: A string identifying the value. If empty, just return `false`.
    /// - Returns: Whether the key is in cache.
    public func containsObject(forKey key: String) -> Bool {
        if key.isEmpty { return false }
        lock.wait()
        defer { lock.signal() }
        return kv?.itemExists(forKey: key) ?? false
    }

    /// Returns a boolean value with the block that indicates whether a given key is in cache.
    /// This method returns immediately and invoke the passed block in background queue
    /// when the operation finished.
    ///
    /// - Parameters:
    ///   - key: A string identifying the value. If empty, just return `false`.
    ///   - block: A block which will be invoked in background queue when finished.
    public func containsObject(forKey key: String, block: @escaping @Sendable (_ key: String, _ contains: Bool) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                block(key, false)
                return
            }
            let contains = containsObject(forKey: key)
            block(key, contains)
        }
    }

    /// Returns the value associated with a given key.
    /// This method may blocks the calling thread until file read finished.
    ///
    /// - Parameter key: A string identifying the value. If empty, just return nil.
    /// - Returns: The value associated with key, or nil if no value is associated with key.
    public func object(forKey key: String) -> NSCoding? {
        if key.isEmpty { return nil }
        lock.wait()
        let item = kv?.getItem(forKey: key)
        lock.signal()
        guard let item = item, !item.value.isEmpty else { return nil }

        var object: Any?
        if let customUnarchiveBlock = customUnarchiveBlock {
            object = customUnarchiveBlock(item.value)
        } else {
            do {
                let unarchiver = try NSKeyedUnarchiver(forReadingFrom: item.value)
                unarchiver.requiresSecureCoding = false
                object = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey)
                unarchiver.finishDecoding()
            } catch {
                // nothing to do...
            }
        }
        if let object = object as AnyObject?, let extendedData = item.extendedData {
            DiskCache.setExtendedData(extendedData, to: object)
        }
        return object as? NSCoding
    }

    /// Returns the value associated with a given key.
    /// This method returns immediately and invoke the passed block in background queue
    /// when the operation finished.
    ///
    /// - Parameters:
    ///   - key: A string identifying the value. If empty, just return nil.
    ///   - block: A block which will be invoked in background queue when finished.
    public func object(forKey key: String, block: @escaping @Sendable (_ key: String, _ object: NSCoding?) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                block(key, nil)
                return
            }
            let object = object(forKey: key)
            block(key, object)
        }
    }

    /// Sets the value of the specified key in the cache.
    /// This method may blocks the calling thread until file write finished.
    ///
    /// - Parameters:
    ///   - object: The object to be stored in the cache. If nil, it calls `removeObject(forKey:)`.
    ///   - key: The key with which to associate the value. If empty, this method has no effect.
    public func setObject(_ object: NSCoding?, forKey key: String) {
        if key.isEmpty { return }
        guard let object = object else {
            removeObject(forKey: key)
            return
        }

        let extendedData = DiskCache.getExtendedData(from: object)
        var value: Data?
        if let customArchiveBlock = customArchiveBlock {
            value = customArchiveBlock(object)
        } else {
            do {
                value = try NSKeyedArchiver.archivedData(withRootObject: object, requiringSecureCoding: false)
            } catch {
                // nothing to do...
            }
        }
        guard let value = value else { return }

        var filename: String?
        if kv?.type != .sqlite {
            if UInt(value.count) > inlineThreshold {
                filename = filenameForKey(key)
            }
        }

        lock.wait()
        kv?.saveItem(withKey: key, value: value, filename: filename, extendedData: extendedData)
        lock.signal()
    }

    /// Sets the value of the specified key in the cache.
    /// This method returns immediately and invoke the passed block in background queue
    /// when the operation finished.
    ///
    /// - Parameters:
    ///   - object: The object to be stored in the cache. If nil, it calls `removeObject(forKey:)`.
    ///   - key: The key with which to associate the value. If empty, this method has no effect.
    ///   - block: A block which will be invoked in background queue when finished.
    public func setObject(_ object: NSCoding?, forKey key: String, block: (@Sendable () -> Void)?) {
        queue.async { [weak self] in
            guard let self else {
                block?()
                return
            }
            setObject(object, forKey: key)
            block?()
        }
    }

    /// Removes the value of the specified key in the cache.
    /// This method may blocks the calling thread until file delete finished.
    ///
    /// - Parameter key: The key identifying the value to be removed. If empty, this method has no effect.
    public func removeObject(forKey key: String) {
        if key.isEmpty { return }
        lock.wait()
        kv?.removeItem(forKey: key)
        lock.signal()
    }

    /// Removes the value of the specified key in the cache.
    /// This method returns immediately and invoke the passed block in background queue
    /// when the operation finished.
    ///
    /// - Parameters:
    ///   - key: The key identifying the value to be removed. If empty, this method has no effect.
    ///   - block: A block which will be invoked in background queue when finished.
    public func removeObject(forKey key: String, block: (@Sendable (_ key: String) -> Void)?) {
        queue.async { [weak self] in
            guard let self else {
                block?(key)
                return
            }
            removeObject(forKey: key)
            block?(key)
        }
    }

    /// Empties the cache.
    /// This method may blocks the calling thread until file delete finished.
    public func removeAllObjects() {
        lock.wait()
        kv?.removeAllItems()
        lock.signal()
    }

    /// Empties the cache.
    /// This method returns immediately and invoke the passed block in background queue
    /// when the operation finished.
    ///
    /// - Parameter block: A block which will be invoked in background queue when finished.
    public func removeAllObjects(block: (@Sendable () -> Void)?) {
        queue.async { [weak self] in
            guard let self else {
                block?()
                return
            }
            removeAllObjects()
            block?()
        }
    }

    /// Empties the cache with block.
    /// This method returns immediately and executes the clear operation with block in background.
    ///
    /// - Parameters:
    ///   - progress: This block will be invoked during removing, pass nil to ignore.
    ///   - end: This block will be invoked at the end, pass nil to ignore.
    /// - Warning: You should not send message to this instance in these blocks.
    public func removeAllObjects(
        progress: (@Sendable (_ removedCount: Int32, _ totalCount: Int32) -> Void)?,
        end: (@Sendable (_ error: Bool) -> Void)?
    ) {
        queue.async { [weak self] in
            guard let self else {
                end?(true)
                return
            }
            lock.wait()
            kv?.removeAllItems(progress: progress, end: end)
            lock.signal()
        }
    }

    /// Returns the number of objects in this cache.
    /// This method may blocks the calling thread until file read finished.
    ///
    /// - Returns: The total objects count.
    public func totalCount() -> Int {
        lock.wait()
        defer { lock.signal() }
        return Int(kv?.getItemsCount() ?? 0)
    }

    /// Get the number of objects in this cache.
    /// This method returns immediately and invoke the passed block in background queue
    /// when the operation finished.
    ///
    /// - Parameter block: A block which will be invoked in background queue when finished.
    public func totalCount(block: @escaping @Sendable (_ totalCount: Int) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                block(0)
                return
            }
            block(totalCount())
        }
    }

    /// Returns the total cost (in bytes) of objects in this cache.
    /// This method may blocks the calling thread until file read finished.
    ///
    /// - Returns: The total objects cost in bytes.
    public func totalCost() -> Int {
        lock.wait()
        defer { lock.signal() }
        return Int(kv?.getItemsSize() ?? 0)
    }

    /// Get the total cost (in bytes) of objects in this cache.
    /// This method returns immediately and invoke the passed block in background queue
    /// when the operation finished.
    ///
    /// - Parameter block: A block which will be invoked in background queue when finished.
    public func totalCost(block: @escaping @Sendable (_ totalCost: Int) -> Void) {
        queue.async { [weak self] in
            guard let self else {
                block(0)
                return
            }
            block(totalCost())
        }
    }

    // MARK: - Trim

    /// Removes objects from the cache use LRU, until the `totalCount` is below the specified value.
    /// This method may blocks the calling thread until operation finished.
    ///
    /// - Parameter count: The total count allowed to remain after the cache has been trimmed.
    public func trimToCount(_ count: UInt) {
        lock.wait()
        _trimToCount(count)
        lock.signal()
    }

    /// Removes objects from the cache use LRU, until the `totalCount` is below the specified value.
    /// This method returns immediately and invoke the passed block in background queue
    /// when the operation finished.
    ///
    /// - Parameters:
    ///   - count: The total count allowed to remain after the cache has been trimmed.
    ///   - block: A block which will be invoked in background queue when finished.
    public func trimToCount(_ count: UInt, block: (@Sendable () -> Void)?) {
        queue.async { [weak self] in
            guard let self else {
                block?()
                return
            }
            trimToCount(count)
            block?()
        }
    }

    /// Removes objects from the cache use LRU, until the `totalCost` is below the specified value.
    /// This method may blocks the calling thread until operation finished.
    ///
    /// - Parameter cost: The total cost allowed to remain after the cache has been trimmed.
    public func trimToCost(_ cost: UInt) {
        lock.wait()
        _trimToCost(cost)
        lock.signal()
    }

    /// Removes objects from the cache use LRU, until the `totalCost` is below the specified value.
    /// This method returns immediately and invoke the passed block in background queue
    /// when the operation finished.
    ///
    /// - Parameters:
    ///   - cost: The total cost allowed to remain after the cache has been trimmed.
    ///   - block: A block which will be invoked in background queue when finished.
    public func trimToCost(_ cost: UInt, block: (@Sendable () -> Void)?) {
        queue.async { [weak self] in
            guard let self else {
                block?()
                return
            }
            trimToCost(cost)
            block?()
        }
    }

    /// Removes objects from the cache use LRU, until all expiry objects removed by the specified value.
    /// This method may blocks the calling thread until operation finished.
    ///
    /// - Parameter age: The maximum age of the object.
    public func trimToAge(_ age: TimeInterval) {
        lock.wait()
        _trimToAge(age)
        lock.signal()
    }

    /// Removes objects from the cache use LRU, until all expiry objects removed by the specified value.
    /// This method returns immediately and invoke the passed block in background queue
    /// when the operation finished.
    ///
    /// - Parameters:
    ///   - age: The maximum age of the object.
    ///   - block: A block which will be invoked in background queue when finished.
    public func trimToAge(_ age: TimeInterval, block: (@Sendable () -> Void)?) {
        queue.async { [weak self] in
            guard let self else {
                block?()
                return
            }
            trimToAge(age)
            block?()
        }
    }

    // MARK: - Extended Data

    /// Get extended data from an object.
    ///
    /// See `setExtendedData(_:to:)` for more information.
    ///
    /// - Parameter object: An object.
    /// - Returns: The extended data.
    public static func getExtendedData(from object: AnyObject) -> Data? {
        return objc_getAssociatedObject(object, &kExtendedDataKey) as? Data
    }

    /// Set extended data to an object.
    ///
    /// You can set any extended data to an object before you save the object
    /// to disk cache. The extended data will also be saved with this object. You can get
    /// the extended data later with `getExtendedData(from:)`.
    ///
    /// - Parameters:
    ///   - extendedData: The extended data (pass nil to remove).
    ///   - object: The object.
    public static func setExtendedData(_ extendedData: Data?, to object: AnyObject) {
        objc_setAssociatedObject(object, &kExtendedDataKey, extendedData, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }
}

// MARK: - CustomStringConvertible

extension DiskCache: CustomStringConvertible {
    public var description: String {
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        if let name = name {
            return "<\(type(of: self)): \(ptr)> (\(name):\(path))"
        } else {
            return "<\(type(of: self)): \(ptr)> (\(path))"
        }
    }
}
