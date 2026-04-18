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
//

#if canImport(UIKit)
import UIKit
#endif
import Foundation
import QuartzCore
import SQLite3

// MARK: - KVStorageItem

/// KVStorageItem is used by `KVStorage` to store key-value pair and meta data.
/// Typically, you should not use this class directly.
final class KVStorageItem: @unchecked Sendable {
    /// key
    var key: String = ""
    /// value
    var value: Data = Data()
    /// filename (nil if inline)
    var filename: String?
    /// value's size in bytes
    var size: Int32 = 0
    /// modification unix timestamp
    var modTime: Int32 = 0
    /// last access unix timestamp
    var accessTime: Int32 = 0
    /// extended data (nil if no extended data)
    var extendedData: Data?
}

// MARK: - KVStorageType

/// Storage type, indicated where the `KVStorageItem.value` stored.
///
/// Typically, write data to sqlite is faster than extern file, but
/// reading performance is dependent on data size. In my test (on iPhone 6 64G),
/// read data from extern file is faster than from sqlite when the data is larger
/// than 20KB.
///
/// * If you want to store large number of small datas (such as contacts cache),
///   use `KVStorageType.sqlite` to get better performance.
/// * If you want to store large files (such as image cache),
///   use `KVStorageType.file` to get better performance.
/// * You can use `KVStorageType.mixed` and choice your storage type for each item.
///
/// See <http://www.sqlite.org/intern-v-extern-blob.html> for more information.
enum KVStorageType: UInt, Sendable {
    /// The `value` is stored as a file in file system.
    case file = 0

    /// The `value` is stored in sqlite with blob type.
    case sqlite = 1

    /// The `value` is stored in file system or sqlite based on your choice.
    case mixed = 2
}

// MARK: - Constants

private let kMaxErrorRetryCount: Int = 8
private let kMinRetryTimeInterval: TimeInterval = 2.0
private let kPathLengthMax: Int = Int(PATH_MAX) - 64
private let kDBFileName = "manifest.sqlite"
private let kDBShmFileName = "manifest.sqlite-shm"
private let kDBWalFileName = "manifest.sqlite-wal"
private let kDataDirectoryName = "data"
private let kTrashDirectoryName = "trash"

/*
 File:
 /path/
      /manifest.sqlite
      /manifest.sqlite-shm
      /manifest.sqlite-wal
      /data/
           /e10adc3949ba59abbe56e057f20f883e
           /e10adc3949ba59abbe56e057f20f883e
      /trash/
            /unused_file_or_folder

 SQL:
 create table if not exists manifest (
    key                 text,
    filename            text,
    size                integer,
    inline_data         blob,
    modification_time   integer,
    last_access_time    integer,
    extended_data       blob,
    primary key(key)
 );
 create index if not exists last_access_time_idx on manifest(last_access_time);
 */

// MARK: - Shared Application Helper

#if canImport(UIKit)
private let isAppExtension: Bool = {
    guard let cls = NSClassFromString("UIApplication"),
          cls.responds(to: NSSelectorFromString("sharedApplication")) else {
        return true
    }
    return Bundle.main.bundlePath.hasSuffix(".appex")
}()

/// Returns nil in App Extension.
private func sharedApplication() -> UIApplication? {
    if isAppExtension { return nil }
    let selector = NSSelectorFromString("sharedApplication")
    return UIApplication.perform(selector)?.takeUnretainedValue() as? UIApplication
}
#endif

// MARK: - SQLite helpers

/// SQLite's `SQLITE_TRANSIENT` macro rebuilt for Swift. Passed as the
/// destructor argument of `sqlite3_bind_text` / `sqlite3_bind_blob` to have
/// SQLite immediately copy the bound bytes, so the original pointer only
/// needs to be valid for the duration of the bind call. This is required
/// when the pointer comes from `withCString` / `withUnsafeBytes`, because
/// those pointers expire as soon as the closure returns.
private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

// MARK: - KVStorage

/// KVStorage is a key-value storage based on sqlite and file system.
/// Typically, you should not use this class directly.
///
/// The designated initializer for KVStorage is `init(path:type:)`.
/// After initialized, a directory is created based on the `path` to hold key-value data.
/// Once initialized you should not read or write this directory without the instance.
///
/// You may compile the latest version of sqlite and ignore the libsqlite3.dylib in
/// iOS system to get 2x~4x speed up.
///
/// - Warning: The instance of this class is *NOT* thread safe, you need to make sure
///   that there's only one thread to access the instance at the same time. If you really
///   need to process large amounts of data in multi-thread, you should split the data
///   to multiple KVStorage instance (sharding).
final class KVStorage {

    // MARK: - Attribute

    /// The path of this storage.
    let path: String
    /// The type of this storage.
    let type: KVStorageType
    /// Set `true` to enable error logs for debug.
    var errorLogsEnabled: Bool = true

    // MARK: - Private Properties

    private let trashQueue: DispatchQueue

    private let dbPath: String
    private let dataPath: String
    private let trashPath: String

    private var db: OpaquePointer?
    private var dbStmtCache: [String: OpaquePointer]?
    private var dbLastOpenErrorTime: TimeInterval = 0
    private var dbOpenErrorCount: UInt8 = 0

    // MARK: - Initializer

    /// The designated initializer. Returns a new storage object, or nil if an error occurs.
    ///
    /// - Parameters:
    ///   - path: Full path of a directory in which the storage will write data. If
    ///     the directory is not exists, it will try to create one, otherwise it will
    ///     read the data in this directory.
    ///   - type: The storage type. After first initialized you should not change the
    ///     type of the specified path.
    /// - Warning: Multiple instances with the same path will make the storage unstable.
    init?(path: String, type: KVStorageType) {
        guard !path.isEmpty, path.count <= kPathLengthMax else {
            NSLog("KVStorage init error: invalid path: [%@].", path)
            return nil
        }

        self.path = path
        self.type = type
        self.dataPath = (path as NSString).appendingPathComponent(kDataDirectoryName)
        self.trashPath = (path as NSString).appendingPathComponent(kTrashDirectoryName)
        self.trashQueue = DispatchQueue(label: "com.reers.cache.disk.trash")
        self.dbPath = (path as NSString).appendingPathComponent(kDBFileName)

        let manager = FileManager.default
        do {
            try manager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: nil)
            try manager.createDirectory(atPath: dataPath, withIntermediateDirectories: true, attributes: nil)
            try manager.createDirectory(atPath: trashPath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            NSLog("KVStorage init error: %@", error.localizedDescription)
            return nil
        }

        if !dbOpen() || !dbInitialize() {
            // db file may broken...
            dbClose()
            reset() // rebuild
            if !dbOpen() || !dbInitialize() {
                dbClose()
                NSLog("KVStorage init error: fail to open sqlite db.")
                return nil
            }
        }
        fileEmptyTrashInBackground() // empty the trash if failed at last time
    }

    deinit {
        #if canImport(UIKit)
        let taskID = sharedApplication()?.beginBackgroundTask(expirationHandler: {}) ?? .invalid
        dbClose()
        if taskID != .invalid {
            sharedApplication()?.endBackgroundTask(taskID)
        }
        #else
        dbClose()
        #endif
    }

    // MARK: - Save Items

    /// Save an item or update the item with 'key' if it already exists.
    ///
    /// This method will save the `item.key`, `item.value`, `item.filename` and
    /// `item.extendedData` to disk or sqlite, other properties will be ignored. `item.key`
    /// and `item.value` should not be empty (nil or zero length).
    ///
    /// If the `type` is `KVStorageType.file`, then the `item.filename` should not be empty.
    /// If the `type` is `KVStorageType.sqlite`, then the `item.filename` will be ignored.
    /// It the `type` is `KVStorageType.mixed`, then the `item.value` will be saved to file
    /// system if the `item.filename` is not empty, otherwise it will be saved to sqlite.
    ///
    /// - Parameter item: An item.
    /// - Returns: Whether succeed.
    @discardableResult
    func saveItem(_ item: KVStorageItem) -> Bool {
        return saveItem(withKey: item.key, value: item.value, filename: item.filename, extendedData: item.extendedData)
    }

    /// Save an item or update the item with 'key' if it already exists.
    ///
    /// This method will save the key-value pair to sqlite. If the `type` is
    /// `KVStorageType.file`, then this method will failed.
    ///
    /// - Parameters:
    ///   - key: The key, should not be empty (nil or zero length).
    ///   - value: The key, should not be empty (nil or zero length).
    /// - Returns: Whether succeed.
    @discardableResult
    func saveItem(withKey key: String, value: Data) -> Bool {
        return saveItem(withKey: key, value: value, filename: nil, extendedData: nil)
    }

    /// Save an item or update the item with 'key' if it already exists.
    ///
    /// If the `type` is `KVStorageType.file`, then the `filename` should not be empty.
    /// If the `type` is `KVStorageType.sqlite`, then the `filename` will be ignored.
    /// It the `type` is `KVStorageType.mixed`, then the `value` will be saved to file
    /// system if the `filename` is not empty, otherwise it will be saved to sqlite.
    ///
    /// - Parameters:
    ///   - key: The key, should not be empty (nil or zero length).
    ///   - value: The key, should not be empty (nil or zero length).
    ///   - filename: The filename.
    ///   - extendedData: The extended data for this item (pass nil to ignore it).
    /// - Returns: Whether succeed.
    @discardableResult
    func saveItem(withKey key: String, value: Data, filename: String?, extendedData: Data?) -> Bool {
        if key.isEmpty || value.isEmpty { return false }
        if type == .file && (filename == nil || filename!.isEmpty) {
            return false
        }

        if let filename = filename, !filename.isEmpty {
            if !fileWrite(withName: filename, data: value) {
                return false
            }
            if !dbSave(withKey: key, value: value, fileName: filename, extendedData: extendedData) {
                fileDelete(withName: filename)
                return false
            }
            return true
        } else {
            if type != .sqlite {
                let existingFilename = dbGetFilename(withKey: key)
                if let existingFilename = existingFilename {
                    fileDelete(withName: existingFilename)
                }
            }
            return dbSave(withKey: key, value: value, fileName: nil, extendedData: extendedData)
        }
    }

    // MARK: - Remove Items

    /// Remove an item with 'key'.
    ///
    /// - Parameter key: The item's key.
    /// - Returns: Whether succeed.
    @discardableResult
    func removeItem(forKey key: String) -> Bool {
        if key.isEmpty { return false }
        switch type {
        case .sqlite:
            return dbDeleteItem(withKey: key)
        case .file, .mixed:
            let filename = dbGetFilename(withKey: key)
            if let filename = filename {
                fileDelete(withName: filename)
            }
            return dbDeleteItem(withKey: key)
        }
    }

    /// Remove items with an array of keys.
    ///
    /// - Parameter keys: An array of specified keys.
    /// - Returns: Whether succeed.
    @discardableResult
    func removeItem(forKeys keys: [String]) -> Bool {
        if keys.isEmpty { return false }
        switch type {
        case .sqlite:
            return dbDeleteItem(withKeys: keys)
        case .file, .mixed:
            let filenames = dbGetFilename(withKeys: keys)
            if let filenames = filenames {
                for name in filenames {
                    fileDelete(withName: name)
                }
            }
            return dbDeleteItem(withKeys: keys)
        }
    }

    /// Remove all items which `value` is larger than a specified size.
    ///
    /// - Parameter size: The maximum size in bytes.
    /// - Returns: Whether succeed.
    @discardableResult
    func removeItemsLargerThanSize(_ size: Int32) -> Bool {
        if size == Int32.max { return true }
        if size <= 0 { return removeAllItems() }

        switch type {
        case .sqlite:
            if dbDeleteItems(withSizeLargerThan: size) {
                dbCheckpoint()
                return true
            }
        case .file, .mixed:
            let filenames = dbGetFilenames(withSizeLargerThan: size)
            if let filenames = filenames {
                for name in filenames {
                    fileDelete(withName: name)
                }
            }
            if dbDeleteItems(withSizeLargerThan: size) {
                dbCheckpoint()
                return true
            }
        }
        return false
    }

    /// Remove all items which last access time is earlier than a specified timestamp.
    ///
    /// - Parameter time: The specified unix timestamp.
    /// - Returns: Whether succeed.
    @discardableResult
    func removeItemsEarlierThanTime(_ time: Int32) -> Bool {
        if time <= 0 { return true }
        if time == Int32.max { return removeAllItems() }

        switch type {
        case .sqlite:
            if dbDeleteItems(withTimeEarlierThan: time) {
                dbCheckpoint()
                return true
            }
        case .file, .mixed:
            let filenames = dbGetFilenames(withTimeEarlierThan: time)
            if let filenames = filenames {
                for name in filenames {
                    fileDelete(withName: name)
                }
            }
            if dbDeleteItems(withTimeEarlierThan: time) {
                dbCheckpoint()
                return true
            }
        }
        return false
    }

    /// Remove items to make the total size not larger than a specified size.
    /// The least recently used (LRU) items will be removed first.
    ///
    /// - Parameter maxSize: The specified size in bytes.
    /// - Returns: Whether succeed.
    @discardableResult
    func removeItemsToFitSize(_ maxSize: Int32) -> Bool {
        if maxSize == Int32.max { return true }
        if maxSize <= 0 { return removeAllItems() }

        var total = dbGetTotalItemSize()
        if total < 0 { return false }
        if total <= maxSize { return true }

        var items: [KVStorageItem]?
        var suc = false
        repeat {
            let perCount: Int32 = 16
            items = dbGetItemSizeInfoOrderByTimeAsc(withLimit: perCount)
            if let items = items {
                for item in items {
                    if total > maxSize {
                        if let filename = item.filename {
                            fileDelete(withName: filename)
                        }
                        suc = dbDeleteItem(withKey: item.key)
                        total -= item.size
                    } else {
                        break
                    }
                    if !suc { break }
                }
            }
        } while total > maxSize && (items?.count ?? 0) > 0 && suc
        if suc { dbCheckpoint() }
        return suc
    }

    /// Remove items to make the total count not larger than a specified count.
    /// The least recently used (LRU) items will be removed first.
    ///
    /// - Parameter maxCount: The specified item count.
    /// - Returns: Whether succeed.
    @discardableResult
    func removeItemsToFitCount(_ maxCount: Int32) -> Bool {
        if maxCount == Int32.max { return true }
        if maxCount <= 0 { return removeAllItems() }

        var total = dbGetTotalItemCount()
        if total < 0 { return false }
        if total <= maxCount { return true }

        var items: [KVStorageItem]?
        var suc = false
        repeat {
            let perCount: Int32 = 16
            items = dbGetItemSizeInfoOrderByTimeAsc(withLimit: perCount)
            if let items = items {
                for item in items {
                    if total > maxCount {
                        if let filename = item.filename {
                            fileDelete(withName: filename)
                        }
                        suc = dbDeleteItem(withKey: item.key)
                        total -= 1
                    } else {
                        break
                    }
                    if !suc { break }
                }
            }
        } while total > maxCount && (items?.count ?? 0) > 0 && suc
        if suc { dbCheckpoint() }
        return suc
    }

    /// Remove all items in background queue.
    ///
    /// This method will remove the files and sqlite database to a trash
    /// folder, and then clear the folder in background queue. So this method is much
    /// faster than `removeAllItems(progress:end:)`.
    ///
    /// - Returns: Whether succeed.
    @discardableResult
    func removeAllItems() -> Bool {
        if !dbClose() { return false }
        reset()
        if !dbOpen() { return false }
        if !dbInitialize() { return false }
        return true
    }

    /// Remove all items.
    ///
    /// - Parameters:
    ///   - progress: This block will be invoked during removing, pass nil to ignore.
    ///   - end: This block will be invoked at the end, pass nil to ignore.
    /// - Warning: You should not send message to this instance in these blocks.
    func removeAllItems(
        progress: ((_ removedCount: Int32, _ totalCount: Int32) -> Void)?,
        end: ((_ error: Bool) -> Void)?
    ) {
        let total = dbGetTotalItemCount()
        if total <= 0 {
            end?(total < 0)
        } else {
            var left = total
            let perCount: Int32 = 32
            var items: [KVStorageItem]?
            var suc = false
            repeat {
                items = dbGetItemSizeInfoOrderByTimeAsc(withLimit: perCount)
                if let items = items {
                    for item in items {
                        if left > 0 {
                            if let filename = item.filename {
                                fileDelete(withName: filename)
                            }
                            suc = dbDeleteItem(withKey: item.key)
                            left -= 1
                        } else {
                            break
                        }
                        if !suc { break }
                    }
                }
                progress?(total - left, total)
            } while left > 0 && (items?.count ?? 0) > 0 && suc
            if suc { dbCheckpoint() }
            end?(!suc)
        }
    }

    // MARK: - Get Items

    /// Get item with a specified key.
    ///
    /// - Parameter key: A specified key.
    /// - Returns: Item for the key, or nil if not exists / error occurs.
    func getItem(forKey key: String) -> KVStorageItem? {
        if key.isEmpty { return nil }
        var item = dbGetItem(withKey: key, excludeInlineData: false)
        if let theItem = item {
            dbUpdateAccessTime(withKey: key)
            if let filename = theItem.filename {
                theItem.value = fileRead(withName: filename) ?? Data()
                if theItem.value.isEmpty {
                    dbDeleteItem(withKey: key)
                    item = nil
                }
            }
        }
        return item
    }

    /// Get item information with a specified key.
    /// The `value` in this item will be ignored.
    ///
    /// - Parameter key: A specified key.
    /// - Returns: Item information for the key, or nil if not exists / error occurs.
    func getItemInfo(forKey key: String) -> KVStorageItem? {
        if key.isEmpty { return nil }
        return dbGetItem(withKey: key, excludeInlineData: true)
    }

    /// Get item value with a specified key.
    ///
    /// - Parameter key: A specified key.
    /// - Returns: Item's value, or nil if not exists / error occurs.
    func getItemValue(forKey key: String) -> Data? {
        if key.isEmpty { return nil }
        var value: Data?
        switch type {
        case .file:
            let filename = dbGetFilename(withKey: key)
            if let filename = filename {
                value = fileRead(withName: filename)
                if value == nil {
                    dbDeleteItem(withKey: key)
                    value = nil
                }
            }
        case .sqlite:
            value = dbGetValue(withKey: key)
        case .mixed:
            let filename = dbGetFilename(withKey: key)
            if let filename = filename {
                value = fileRead(withName: filename)
                if value == nil {
                    dbDeleteItem(withKey: key)
                    value = nil
                }
            } else {
                value = dbGetValue(withKey: key)
            }
        }
        if value != nil {
            dbUpdateAccessTime(withKey: key)
        }
        return value
    }

    /// Get items with an array of keys.
    ///
    /// - Parameter keys: An array of specified keys.
    /// - Returns: An array of `KVStorageItem`, or nil if not exists / error occurs.
    func getItem(forKeys keys: [String]) -> [KVStorageItem]? {
        if keys.isEmpty { return nil }
        guard var items = dbGetItem(withKeys: keys, excludeInlineData: false) else { return nil }
        if type != .sqlite {
            var i = 0
            while i < items.count {
                let item = items[i]
                if let filename = item.filename {
                    if let data = fileRead(withName: filename) {
                        item.value = data
                        i += 1
                    } else {
                        dbDeleteItem(withKey: item.key)
                        items.remove(at: i)
                    }
                } else {
                    i += 1
                }
            }
        }
        if !items.isEmpty {
            dbUpdateAccessTime(withKeys: keys)
        }
        return items.isEmpty ? nil : items
    }

    /// Get item infomartions with an array of keys.
    /// The `value` in items will be ignored.
    ///
    /// - Parameter keys: An array of specified keys.
    /// - Returns: An array of `KVStorageItem`, or nil if not exists / error occurs.
    func getItemInfo(forKeys keys: [String]) -> [KVStorageItem]? {
        if keys.isEmpty { return nil }
        return dbGetItem(withKeys: keys, excludeInlineData: true)
    }

    /// Get items value with an array of keys.
    ///
    /// - Parameter keys: An array of specified keys.
    /// - Returns: A dictionary which key is 'key' and value is 'value', or nil if not
    ///   exists / error occurs.
    func getItemValue(forKeys keys: [String]) -> [String: Data]? {
        guard let items = getItem(forKeys: keys) else { return nil }
        var kv: [String: Data] = [:]
        for item in items {
            if !item.key.isEmpty, !item.value.isEmpty {
                kv[item.key] = item.value
            }
        }
        return kv.isEmpty ? nil : kv
    }

    // MARK: - Get Storage Status

    /// Whether an item exists for a specified key.
    ///
    /// - Parameter key: A specified key.
    /// - Returns: `true` if there's an item exists for the key, `false` if not exists or an error occurs.
    func itemExists(forKey key: String) -> Bool {
        if key.isEmpty { return false }
        return dbGetItemCount(withKey: key) > 0
    }

    /// Get total item count.
    ///
    /// - Returns: Total item count, -1 when an error occurs.
    func getItemsCount() -> Int32 {
        return dbGetTotalItemCount()
    }

    /// Get item value's total size in bytes.
    ///
    /// - Returns: Total size in bytes, -1 when an error occurs.
    func getItemsSize() -> Int32 {
        return dbGetTotalItemSize()
    }

    // MARK: - db

    @discardableResult
    private func dbOpen() -> Bool {
        if db != nil { return true }

        let result = dbPath.withCString { sqlite3_open($0, &db) }
        if result == SQLITE_OK {
            dbStmtCache = [:]
            dbLastOpenErrorTime = 0
            dbOpenErrorCount = 0
            return true
        } else {
            db = nil
            dbStmtCache = nil
            dbLastOpenErrorTime = CACurrentMediaTime()
            dbOpenErrorCount += 1

            if errorLogsEnabled {
                NSLog("\(#function) line:\(#line) sqlite open failed (\(result)).")
            }
            return false
        }
    }

    @discardableResult
    private func dbClose() -> Bool {
        guard let database = db else { return true }

        var result: Int32 = 0
        var retry = false
        var stmtFinalized = false

        if let cache = dbStmtCache {
            for (_, stmt) in cache {
                sqlite3_finalize(stmt)
            }
        }
        dbStmtCache = nil

        repeat {
            retry = false
            result = sqlite3_close(database)
            if result == SQLITE_BUSY || result == SQLITE_LOCKED {
                if !stmtFinalized {
                    stmtFinalized = true
                    while let stmt = sqlite3_next_stmt(database, nil) {
                        sqlite3_finalize(stmt)
                        retry = true
                    }
                }
            } else if result != SQLITE_OK {
                if errorLogsEnabled {
                    NSLog("\(#function) line:\(#line) sqlite close failed (\(result)).")
                }
            }
        } while retry
        db = nil
        return true
    }

    private func dbCheck() -> Bool {
        if db == nil {
            if dbOpenErrorCount < kMaxErrorRetryCount &&
                CACurrentMediaTime() - dbLastOpenErrorTime > kMinRetryTimeInterval {
                return dbOpen() && dbInitialize()
            } else {
                return false
            }
        }
        return true
    }

    @discardableResult
    private func dbInitialize() -> Bool {
        let sql = "pragma journal_mode = wal; pragma synchronous = normal; create table if not exists manifest (key text, filename text, size integer, inline_data blob, modification_time integer, last_access_time integer, extended_data blob, primary key(key)); create index if not exists last_access_time_idx on manifest(last_access_time);"
        return dbExecute(sql)
    }

    private func dbCheckpoint() {
        if !dbCheck() { return }
        // Cause a checkpoint to occur, merge `sqlite-wal` file to `sqlite` file.
        let result = sqlite3_wal_checkpoint(db, nil)
        if result != SQLITE_OK && errorLogsEnabled {
            NSLog("\(#function) line:\(#line) sqlite WAL checkpoint error (\(result))")
        }
    }

    @discardableResult
    private func dbExecute(_ sql: String) -> Bool {
        if sql.isEmpty { return false }
        if !dbCheck() { return false }

        var error: UnsafeMutablePointer<CChar>?
        let result = sql.withCString { sqlite3_exec(db, $0, nil, nil, &error) }
        if let error = error {
            if errorLogsEnabled {
                NSLog("\(#function) line:\(#line) sqlite exec error (\(result)): \(String(cString: error))")
            }
            sqlite3_free(error)
        }
        return result == SQLITE_OK
    }

    private func dbPrepareStmt(_ sql: String) -> OpaquePointer? {
        if !dbCheck() || sql.isEmpty || dbStmtCache == nil { return nil }
        var stmt: OpaquePointer? = dbStmtCache?[sql]
        if stmt == nil {
            let result = sql.withCString { sqlite3_prepare_v2(db, $0, -1, &stmt, nil) }
            if result != SQLITE_OK {
                if errorLogsEnabled {
                    NSLog("\(#function) line:\(#line) sqlite stmt prepare error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
                }
                return nil
            }
            dbStmtCache?[sql] = stmt
        } else {
            if sqlite3_stmt_busy(stmt) != 0 {
                // just in case someone will forget to sqlite3_reset cached statement
                // causing WAL file lock
                if errorLogsEnabled {
                    NSLog("\(#function) line:\(#line) WARN: cached statement for query \"\(sql)\" was not reset.")
                }
                sqlite3_reset(stmt)
            }
        }
        return stmt
    }

    private func dbJoinedKeys(_ keys: [String]) -> String {
        var string = ""
        let max = keys.count
        for i in 0..<max {
            string += "?"
            if i + 1 != max {
                string += ","
            }
        }
        return string
    }

    private func dbBindJoinedKeys(_ keys: [String], stmt: OpaquePointer, fromIndex index: Int32) {
        for i in 0..<Int32(keys.count) {
            _ = keys[Int(i)].withCString { sqlite3_bind_text(stmt, index + i, $0, -1, SQLITE_TRANSIENT) }
        }
    }

    @discardableResult
    private func dbSave(withKey key: String, value: Data, fileName: String?, extendedData: Data?) -> Bool {
        let sql = "insert or replace into manifest (key, filename, size, inline_data, modification_time, last_access_time, extended_data) values (?1, ?2, ?3, ?4, ?5, ?6, ?7);"
        guard let stmt = dbPrepareStmt(sql) else { return false }

        let timestamp = Int32(time(nil))
        _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
        if let fileName = fileName {
            _ = fileName.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
        } else {
            sqlite3_bind_null(stmt, 2)
        }
        sqlite3_bind_int(stmt, 3, Int32(value.count))
        if fileName == nil || fileName!.isEmpty {
            value.withUnsafeBytes { rawBuffer in
                _ = sqlite3_bind_blob(stmt, 4, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_blob(stmt, 4, nil, 0, nil)
        }
        sqlite3_bind_int(stmt, 5, timestamp)
        sqlite3_bind_int(stmt, 6, timestamp)
        if let extendedData = extendedData {
            extendedData.withUnsafeBytes { rawBuffer in
                _ = sqlite3_bind_blob(stmt, 7, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_blob(stmt, 7, nil, 0, nil)
        }

        let result = sqlite3_step(stmt)
        sqlite3_reset(stmt)
        if result != SQLITE_DONE {
            if errorLogsEnabled {
                NSLog("\(#function) line:\(#line) sqlite insert error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
            }
            return false
        }
        return true
    }

    @discardableResult
    private func dbUpdateAccessTime(withKey key: String) -> Bool {
        let sql = "update manifest set last_access_time = ?1 where key = ?2;"
        guard let stmt = dbPrepareStmt(sql) else { return false }
        sqlite3_bind_int(stmt, 1, Int32(time(nil)))
        _ = key.withCString { sqlite3_bind_text(stmt, 2, $0, -1, SQLITE_TRANSIENT) }
        let result = sqlite3_step(stmt)
        sqlite3_reset(stmt)
        if result != SQLITE_DONE {
            if errorLogsEnabled {
                NSLog("\(#function) line:\(#line) sqlite update error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
            }
            return false
        }
        return true
    }

    @discardableResult
    private func dbUpdateAccessTime(withKeys keys: [String]) -> Bool {
        if !dbCheck() { return false }
        let t = Int32(time(nil))
        let sql = "update manifest set last_access_time = \(t) where key in (\(dbJoinedKeys(keys)));"

        var stmt: OpaquePointer?
        let result = sql.withCString { sqlite3_prepare_v2(db, $0, -1, &stmt, nil) }
        if result != SQLITE_OK {
            if errorLogsEnabled {
                NSLog("\(#function) line:\(#line) sqlite stmt prepare error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
            }
            return false
        }

        dbBindJoinedKeys(keys, stmt: stmt!, fromIndex: 1)
        let stepResult = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if stepResult != SQLITE_DONE {
            if errorLogsEnabled {
                NSLog("\(#function) line:\(#line) sqlite update error (\(stepResult)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
            }
            return false
        }
        return true
    }

    @discardableResult
    private func dbDeleteItem(withKey key: String) -> Bool {
        let sql = "delete from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql) else { return false }
        _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }

        let result = sqlite3_step(stmt)
        sqlite3_reset(stmt)
        if result != SQLITE_DONE {
            if errorLogsEnabled {
                NSLog("\(#function) line:\(#line) db delete error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
            }
            return false
        }
        return true
    }

    @discardableResult
    private func dbDeleteItem(withKeys keys: [String]) -> Bool {
        if !dbCheck() { return false }
        let sql = "delete from manifest where key in (\(dbJoinedKeys(keys)));"
        var stmt: OpaquePointer?
        let result = sql.withCString { sqlite3_prepare_v2(db, $0, -1, &stmt, nil) }
        if result != SQLITE_OK {
            if errorLogsEnabled {
                NSLog("\(#function) line:\(#line) sqlite stmt prepare error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
            }
            return false
        }

        dbBindJoinedKeys(keys, stmt: stmt!, fromIndex: 1)
        let stepResult = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if stepResult == SQLITE_ERROR {
            if errorLogsEnabled {
                NSLog("\(#function) line:\(#line) sqlite delete error (\(stepResult)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
            }
            return false
        }
        return true
    }

    @discardableResult
    private func dbDeleteItems(withSizeLargerThan size: Int32) -> Bool {
        let sql = "delete from manifest where size > ?1;"
        guard let stmt = dbPrepareStmt(sql) else { return false }
        sqlite3_bind_int(stmt, 1, size)
        let result = sqlite3_step(stmt)
        sqlite3_reset(stmt)
        if result != SQLITE_DONE {
            if errorLogsEnabled {
                NSLog("\(#function) line:\(#line) sqlite delete error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
            }
            return false
        }
        return true
    }

    @discardableResult
    private func dbDeleteItems(withTimeEarlierThan time: Int32) -> Bool {
        let sql = "delete from manifest where last_access_time < ?1;"
        guard let stmt = dbPrepareStmt(sql) else { return false }
        sqlite3_bind_int(stmt, 1, time)
        let result = sqlite3_step(stmt)
        sqlite3_reset(stmt)
        if result != SQLITE_DONE {
            if errorLogsEnabled {
                NSLog("\(#function) line:\(#line) sqlite delete error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
            }
            return false
        }
        return true
    }

    private func dbGetItem(fromStmt stmt: OpaquePointer, excludeInlineData: Bool) -> KVStorageItem {
        var i: Int32 = 0
        let key = sqlite3_column_text(stmt, i).flatMap { String(cString: $0) }
        i += 1
        let filename = sqlite3_column_text(stmt, i).flatMap { String(cString: $0) }
        i += 1
        let size = sqlite3_column_int(stmt, i)
        i += 1
        let inlineData: UnsafeRawPointer? = excludeInlineData ? nil : sqlite3_column_blob(stmt, i)
        let inlineDataBytes: Int32 = excludeInlineData ? 0 : sqlite3_column_bytes(stmt, i)
        if !excludeInlineData { i += 1 }
        let modificationTime = sqlite3_column_int(stmt, i)
        i += 1
        let lastAccessTime = sqlite3_column_int(stmt, i)
        i += 1
        let extData: UnsafeRawPointer? = sqlite3_column_blob(stmt, i)
        let extDataBytes = sqlite3_column_bytes(stmt, i)

        let item = KVStorageItem()
        if let key = key { item.key = key }
        if let filename = filename, !filename.isEmpty { item.filename = filename }
        item.size = size
        if inlineDataBytes > 0, let inlineData = inlineData {
            item.value = Data(bytes: inlineData, count: Int(inlineDataBytes))
        }
        item.modTime = modificationTime
        item.accessTime = lastAccessTime
        if extDataBytes > 0, let extData = extData {
            item.extendedData = Data(bytes: extData, count: Int(extDataBytes))
        }
        return item
    }

    private func dbGetItem(withKey key: String, excludeInlineData: Bool) -> KVStorageItem? {
        let sql = excludeInlineData
            ? "select key, filename, size, modification_time, last_access_time, extended_data from manifest where key = ?1;"
            : "select key, filename, size, inline_data, modification_time, last_access_time, extended_data from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql) else { return nil }
        _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }

        let result = sqlite3_step(stmt)
        var item: KVStorageItem?
        if result == SQLITE_ROW {
            item = dbGetItem(fromStmt: stmt, excludeInlineData: excludeInlineData)
        } else {
            if result != SQLITE_DONE {
                if errorLogsEnabled {
                    NSLog("\(#function) line:\(#line) sqlite query error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
                }
            }
        }
        sqlite3_reset(stmt)
        return item
    }

    private func dbGetItem(withKeys keys: [String], excludeInlineData: Bool) -> [KVStorageItem]? {
        if !dbCheck() { return nil }
        let sql: String
        if excludeInlineData {
            sql = "select key, filename, size, modification_time, last_access_time, extended_data from manifest where key in (\(dbJoinedKeys(keys)));"
        } else {
            sql = "select key, filename, size, inline_data, modification_time, last_access_time, extended_data from manifest where key in (\(dbJoinedKeys(keys)));"
        }

        var stmt: OpaquePointer?
        let result = sql.withCString { sqlite3_prepare_v2(db, $0, -1, &stmt, nil) }
        if result != SQLITE_OK {
            if errorLogsEnabled {
                NSLog("\(#function) line:\(#line) sqlite stmt prepare error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
            }
            return nil
        }

        dbBindJoinedKeys(keys, stmt: stmt!, fromIndex: 1)
        var items: [KVStorageItem]? = []
        while true {
            let stepResult = sqlite3_step(stmt)
            if stepResult == SQLITE_ROW {
                let item = dbGetItem(fromStmt: stmt!, excludeInlineData: excludeInlineData)
                items?.append(item)
            } else if stepResult == SQLITE_DONE {
                break
            } else {
                if errorLogsEnabled {
                    NSLog("\(#function) line:\(#line) sqlite query error (\(stepResult)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
                }
                items = nil
                break
            }
        }
        sqlite3_finalize(stmt)
        return items
    }

    private func dbGetValue(withKey key: String) -> Data? {
        let sql = "select inline_data from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql) else { return nil }
        _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }

        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW {
            let inlineData = sqlite3_column_blob(stmt, 0)
            let inlineDataBytes = sqlite3_column_bytes(stmt, 0)
            // IMPORTANT: copy the blob into Data BEFORE `sqlite3_reset`, otherwise
            // the pointer returned by `sqlite3_column_blob` is invalidated and we'd
            // copy garbage. See https://sqlite.org/c3ref/column_blob.html.
            let copied: Data?
            if inlineData == nil || inlineDataBytes <= 0 {
                copied = nil
            } else {
                copied = Data(bytes: inlineData!, count: Int(inlineDataBytes))
            }
            sqlite3_reset(stmt)
            return copied
        } else {
            if result != SQLITE_DONE {
                if errorLogsEnabled {
                    NSLog("\(#function) line:\(#line) sqlite query error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
                }
            }
            sqlite3_reset(stmt)
            return nil
        }
    }

    private func dbGetFilename(withKey key: String) -> String? {
        let sql = "select filename from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql) else { return nil }
        _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW {
            if let filename = sqlite3_column_text(stmt, 0) {
                let name = String(cString: filename)
                if !name.isEmpty {
                    sqlite3_reset(stmt)
                    return name
                }
            }
        } else {
            if result != SQLITE_DONE {
                if errorLogsEnabled {
                    NSLog("\(#function) line:\(#line) sqlite query error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
                }
            }
        }
        sqlite3_reset(stmt)
        return nil
    }

    private func dbGetFilename(withKeys keys: [String]) -> [String]? {
        if !dbCheck() { return nil }
        let sql = "select filename from manifest where key in (\(dbJoinedKeys(keys)));"
        var stmt: OpaquePointer?
        let result = sql.withCString { sqlite3_prepare_v2(db, $0, -1, &stmt, nil) }
        if result != SQLITE_OK {
            if errorLogsEnabled {
                NSLog("\(#function) line:\(#line) sqlite stmt prepare error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
            }
            return nil
        }

        dbBindJoinedKeys(keys, stmt: stmt!, fromIndex: 1)
        var filenames: [String]? = []
        while true {
            let stepResult = sqlite3_step(stmt)
            if stepResult == SQLITE_ROW {
                if let raw = sqlite3_column_text(stmt, 0) {
                    let name = String(cString: raw)
                    if !name.isEmpty {
                        filenames?.append(name)
                    }
                }
            } else if stepResult == SQLITE_DONE {
                break
            } else {
                if errorLogsEnabled {
                    NSLog("\(#function) line:\(#line) sqlite query error (\(stepResult)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
                }
                filenames = nil
                break
            }
        }
        sqlite3_finalize(stmt)
        return filenames
    }

    private func dbGetFilenames(withSizeLargerThan size: Int32) -> [String]? {
        let sql = "select filename from manifest where size > ?1 and filename is not null;"
        guard let stmt = dbPrepareStmt(sql) else { return nil }
        sqlite3_bind_int(stmt, 1, size)

        var filenames: [String]? = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                if let raw = sqlite3_column_text(stmt, 0) {
                    let name = String(cString: raw)
                    if !name.isEmpty {
                        filenames?.append(name)
                    }
                }
            } else if result == SQLITE_DONE {
                break
            } else {
                if errorLogsEnabled {
                    NSLog("\(#function) line:\(#line) sqlite query error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
                }
                filenames = nil
                break
            }
        }
        sqlite3_reset(stmt)
        return filenames
    }

    private func dbGetFilenames(withTimeEarlierThan time: Int32) -> [String]? {
        let sql = "select filename from manifest where last_access_time < ?1 and filename is not null;"
        guard let stmt = dbPrepareStmt(sql) else { return nil }
        sqlite3_bind_int(stmt, 1, time)

        var filenames: [String]? = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                if let raw = sqlite3_column_text(stmt, 0) {
                    let name = String(cString: raw)
                    if !name.isEmpty {
                        filenames?.append(name)
                    }
                }
            } else if result == SQLITE_DONE {
                break
            } else {
                if errorLogsEnabled {
                    NSLog("\(#function) line:\(#line) sqlite query error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
                }
                filenames = nil
                break
            }
        }
        sqlite3_reset(stmt)
        return filenames
    }

    private func dbGetItemSizeInfoOrderByTimeAsc(withLimit count: Int32) -> [KVStorageItem]? {
        let sql = "select key, filename, size from manifest order by last_access_time asc limit ?1;"
        guard let stmt = dbPrepareStmt(sql) else { return nil }
        sqlite3_bind_int(stmt, 1, count)

        var items: [KVStorageItem]? = []
        while true {
            let result = sqlite3_step(stmt)
            if result == SQLITE_ROW {
                if let rawKey = sqlite3_column_text(stmt, 0) {
                    let keyStr = String(cString: rawKey)
                    if !keyStr.isEmpty {
                        let item = KVStorageItem()
                        item.key = keyStr
                        if let rawFilename = sqlite3_column_text(stmt, 1) {
                            let fn = String(cString: rawFilename)
                            if !fn.isEmpty { item.filename = fn }
                        }
                        item.size = sqlite3_column_int(stmt, 2)
                        items?.append(item)
                    }
                }
            } else if result == SQLITE_DONE {
                break
            } else {
                if errorLogsEnabled {
                    NSLog("\(#function) line:\(#line) sqlite query error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
                }
                items = nil
                break
            }
        }
        sqlite3_reset(stmt)
        return items
    }

    private func dbGetItemCount(withKey key: String) -> Int32 {
        let sql = "select count(key) from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql) else { return -1 }
        _ = key.withCString { sqlite3_bind_text(stmt, 1, $0, -1, SQLITE_TRANSIENT) }
        let result = sqlite3_step(stmt)
        if result != SQLITE_ROW {
            if errorLogsEnabled {
                NSLog("\(#function) line:\(#line) sqlite query error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
            }
            sqlite3_reset(stmt)
            return -1
        }
        let count = sqlite3_column_int(stmt, 0)
        sqlite3_reset(stmt)
        return count
    }

    private func dbGetTotalItemSize() -> Int32 {
        let sql = "select sum(size) from manifest;"
        guard let stmt = dbPrepareStmt(sql) else { return -1 }
        let result = sqlite3_step(stmt)
        if result != SQLITE_ROW {
            if errorLogsEnabled {
                NSLog("\(#function) line:\(#line) sqlite query error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
            }
            sqlite3_reset(stmt)
            return -1
        }
        let size = sqlite3_column_int(stmt, 0)
        sqlite3_reset(stmt)
        return size
    }

    private func dbGetTotalItemCount() -> Int32 {
        let sql = "select count(*) from manifest;"
        guard let stmt = dbPrepareStmt(sql) else { return -1 }
        let result = sqlite3_step(stmt)
        if result != SQLITE_ROW {
            if errorLogsEnabled {
                NSLog("\(#function) line:\(#line) sqlite query error (\(result)): \(sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")")
            }
            sqlite3_reset(stmt)
            return -1
        }
        let count = sqlite3_column_int(stmt, 0)
        sqlite3_reset(stmt)
        return count
    }

    // MARK: - file
    //
    // These helpers sit on the hot path for `.file` / `.mixed` storage
    // (every large-value set/get goes through them). The earlier
    // Foundation-based implementations (`Data.write(to:options:)`,
    // `Data(contentsOf:)`, `FileManager.removeItem(atPath:)`) each carry
    // per-call URL / NSString / NSError bridging that costs ~50 µs on
    // current Apple platforms. For a 1 000-item benchmark that shows up
    // as a ~50 ms flat tax versus YYCache's ObjC `-[NSData
    // writeToFile:atomically:]` path. POSIX `open`/`read`/`write`/`close`/
    // `unlink` eliminate the bridging layer and close the gap.
    //
    // Notes:
    // * `filename` is produced upstream (DiskCache hashes keys) and is
    //   assumed to be a simple, relative, traversal-free path component —
    //   we intentionally skip `NSString.appendingPathComponent`'s
    //   normalisation (`//` collapsing, etc.) to avoid bridging.
    // * `read(2)` / `write(2)` are looped to handle short IO and EINTR.
    // * errno-based failure is swallowed (return nil / false) to preserve
    //   behavioural parity with the old implementations.

    @inline(__always)
    private func joinPath(_ filename: String) -> String {
        // `dataPath` already has no trailing slash (set via
        // `NSString.appendingPathComponent`); `filename` never starts with
        // one (it's a short identifier / hash / user-supplied leaf).
        return dataPath + "/" + filename
    }

    @discardableResult
    private func fileWrite(withName filename: String, data: Data) -> Bool {
        let filePath = joinPath(filename)
        return filePath.withCString { cpath -> Bool in
            let fd = open(cpath, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            if fd < 0 { return false }
            defer { close(fd) }

            let total = data.count
            if total == 0 { return true }

            return data.withUnsafeBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                var written = 0
                while written < total {
                    let n = write(fd, base.advanced(by: written), total - written)
                    if n > 0 {
                        written += n
                    } else if n < 0 && errno == EINTR {
                        continue
                    } else {
                        return false
                    }
                }
                return true
            }
        }
    }

    private func fileRead(withName filename: String) -> Data? {
        let filePath = joinPath(filename)
        return filePath.withCString { cpath -> Data? in
            let fd = open(cpath, O_RDONLY)
            if fd < 0 { return nil }
            defer { close(fd) }

            var st = stat()
            if fstat(fd, &st) != 0 { return nil }
            let size = Int(st.st_size)
            if size <= 0 { return Data() }

            var data = Data(count: size)
            let ok = data.withUnsafeMutableBytes { raw -> Bool in
                guard let base = raw.baseAddress else { return false }
                var readBytes = 0
                while readBytes < size {
                    let n = read(fd, base.advanced(by: readBytes), size - readBytes)
                    if n > 0 {
                        readBytes += n
                    } else if n == 0 {
                        // EOF before expected size — file truncated; return
                        // what we got so far (YYCache also tolerates this).
                        return true
                    } else if errno == EINTR {
                        continue
                    } else {
                        return false
                    }
                }
                return true
            }
            return ok ? data : nil
        }
    }

    @discardableResult
    private func fileDelete(withName filename: String) -> Bool {
        let filePath = joinPath(filename)
        return filePath.withCString { cpath in
            // Treat "already gone" (ENOENT) as success: callers use this
            // when dropping orphan rows etc., matching YYCache semantics.
            if unlink(cpath) == 0 { return true }
            return errno == ENOENT
        }
    }

    @discardableResult
    private func fileMoveAllToTrash() -> Bool {
        let uuid = UUID().uuidString
        let tmpPath = (trashPath as NSString).appendingPathComponent(uuid)
        do {
            try FileManager.default.moveItem(atPath: dataPath, toPath: tmpPath)
        } catch {
            return false
        }
        do {
            try FileManager.default.createDirectory(atPath: dataPath, withIntermediateDirectories: true, attributes: nil)
        } catch {
            return false
        }
        return true
    }

    private func fileEmptyTrashInBackground() {
        let trashPath = self.trashPath
        trashQueue.async {
            let manager = FileManager()
            if let directoryContents = try? manager.contentsOfDirectory(atPath: trashPath) {
                for path in directoryContents {
                    let fullPath = (trashPath as NSString).appendingPathComponent(path)
                    try? manager.removeItem(atPath: fullPath)
                }
            }
        }
    }

    // MARK: - private

    /// Delete all files and empty in background.
    /// Make sure the db is closed.
    private func reset() {
        try? FileManager.default.removeItem(atPath: (path as NSString).appendingPathComponent(kDBFileName))
        try? FileManager.default.removeItem(atPath: (path as NSString).appendingPathComponent(kDBShmFileName))
        try? FileManager.default.removeItem(atPath: (path as NSString).appendingPathComponent(kDBWalFileName))
        fileMoveAllToTrash()
        fileEmptyTrashInBackground()
    }
}
