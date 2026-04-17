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

#if canImport(UIKit)
import UIKit
#endif
import Foundation
import SQLite3

// MARK: - KVStorageType

public enum KVStorageType: Int, Sendable {
    case file = 0
    case sqlite = 1
    case mixed = 2
}

// MARK: - KVStorageItem

public final class KVStorageItem: @unchecked Sendable {
    public var key: String = ""
    public var value: Data = Data()
    public var filename: String?
    public var size: Int32 = 0
    public var modTime: Int32 = 0
    public var accessTime: Int32 = 0
    public var extendedData: Data?
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

// MARK: - Shared Application Helper

#if canImport(UIKit) && !os(watchOS)
private func sharedApplication() -> UIApplication? {
    let isAppExtension: Bool = {
        guard let cls = NSClassFromString("UIApplication"),
              cls.responds(to: NSSelectorFromString("sharedApplication")) else {
            return true
        }
        if Bundle.main.bundlePath.hasSuffix(".appex") {
            return true
        }
        return false
    }()
    if isAppExtension { return nil }
    return UIApplication.value(forKey: "sharedApplication") as? UIApplication
}
#endif

// MARK: - SQLITE_TRANSIENT helper

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - KVStorage

public final class KVStorage {

    // MARK: - Public Properties

    public let path: String
    public let type: KVStorageType
    public var errorLogsEnabled: Bool = true

    // MARK: - Private Properties

    private let trashQueue: DispatchQueue

    private let dbPath: String
    private let dataPath: String
    private let trashPath: String

    private var db: OpaquePointer?
    private var dbStmtCache: [String: OpaquePointer]?
    private var dbLastOpenErrorTime: TimeInterval = 0
    private var dbOpenErrorCount: Int = 0

    // MARK: - Initialization

    public init?(path: String, type: KVStorageType) {
        guard !path.isEmpty, path.count <= kPathLengthMax else {
            NSLog("KVStorage init error: invalid path: [%@].", path)
            return nil
        }

        self.path = path
        self.type = type
        self.dataPath = (path as NSString).appendingPathComponent(kDataDirectoryName)
        self.trashPath = (path as NSString).appendingPathComponent(kTrashDirectoryName)
        self.trashQueue = DispatchQueue(label: "com.ibireme.cache.disk.trash")
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
            dbClose()
            reset()
            if !dbOpen() || !dbInitialize() {
                dbClose()
                NSLog("KVStorage init error: fail to open sqlite db.")
                return nil
            }
        }
        fileEmptyTrashInBackground()
    }

    deinit {
        #if canImport(UIKit) && !os(watchOS)
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

    @discardableResult
    public func saveItem(_ item: KVStorageItem) -> Bool {
        return saveItem(withKey: item.key, value: item.value, filename: item.filename, extendedData: item.extendedData)
    }

    @discardableResult
    public func saveItem(withKey key: String, value: Data) -> Bool {
        return saveItem(withKey: key, value: value, filename: nil, extendedData: nil)
    }

    @discardableResult
    public func saveItem(withKey key: String, value: Data, filename: String?, extendedData: Data?) -> Bool {
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

    @discardableResult
    public func removeItem(forKey key: String) -> Bool {
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

    @discardableResult
    public func removeItem(forKeys keys: [String]) -> Bool {
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

    @discardableResult
    public func removeItemsLargerThanSize(_ size: Int32) -> Bool {
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

    @discardableResult
    public func removeItemsEarlierThanTime(_ time: Int32) -> Bool {
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

    @discardableResult
    public func removeItemsToFitSize(_ maxSize: Int32) -> Bool {
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

    @discardableResult
    public func removeItemsToFitCount(_ maxCount: Int32) -> Bool {
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

    @discardableResult
    public func removeAllItems() -> Bool {
        if !dbClose() { return false }
        reset()
        if !dbOpen() { return false }
        if !dbInitialize() { return false }
        return true
    }

    public func removeAllItems(progress: ((_ removedCount: Int32, _ totalCount: Int32) -> Void)?,
                               end: ((_ error: Bool) -> Void)?) {
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

    public func getItem(forKey key: String) -> KVStorageItem? {
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

    public func getItemInfo(forKey key: String) -> KVStorageItem? {
        if key.isEmpty { return nil }
        return dbGetItem(withKey: key, excludeInlineData: true)
    }

    public func getItemValue(forKey key: String) -> Data? {
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

    public func getItem(forKeys keys: [String]) -> [KVStorageItem]? {
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

    public func getItemInfo(forKeys keys: [String]) -> [KVStorageItem]? {
        if keys.isEmpty { return nil }
        return dbGetItem(withKeys: keys, excludeInlineData: true)
    }

    public func getItemValue(forKeys keys: [String]) -> [String: Data]? {
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

    public func itemExists(forKey key: String) -> Bool {
        if key.isEmpty { return false }
        return dbGetItemCount(withKey: key) > 0
    }

    public func getItemsCount() -> Int32 {
        return dbGetTotalItemCount()
    }

    public func getItemsSize() -> Int32 {
        return dbGetTotalItemSize()
    }

    // MARK: - Private DB Methods

    @discardableResult
    private func dbOpen() -> Bool {
        if db != nil { return true }

        let result = sqlite3_open(dbPath, &db)
        if result == SQLITE_OK {
            dbStmtCache = [:]
            dbLastOpenErrorTime = 0
            dbOpenErrorCount = 0
            return true
        } else {
            db = nil
            if let cache = dbStmtCache {
                for (_, stmt) in cache {
                    sqlite3_finalize(stmt)
                }
            }
            dbStmtCache = nil
            dbLastOpenErrorTime = CACurrentMediaTime()
            dbOpenErrorCount += 1

            if errorLogsEnabled {
                NSLog("KVStorage dbOpen failed (%d).", result)
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
                    var stmt: OpaquePointer?
                    while true {
                        stmt = sqlite3_next_stmt(database, nil)
                        guard let s = stmt else { break }
                        sqlite3_finalize(s)
                        retry = true
                    }
                }
            } else if result != SQLITE_OK {
                if errorLogsEnabled {
                    NSLog("KVStorage dbClose failed (%d).", result)
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
        sqlite3_wal_checkpoint(db, nil)
    }

    @discardableResult
    private func dbExecute(_ sql: String) -> Bool {
        if sql.isEmpty { return false }
        if !dbCheck() { return false }

        var error: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &error)
        if let error = error {
            if errorLogsEnabled {
                NSLog("KVStorage dbExecute error (%d): %s", result, error)
            }
            sqlite3_free(error)
        }
        return result == SQLITE_OK
    }

    private func dbPrepareStmt(_ sql: String) -> OpaquePointer? {
        if !dbCheck() || sql.isEmpty || dbStmtCache == nil { return nil }

        if let stmt = dbStmtCache?[sql] {
            sqlite3_reset(stmt)
            return stmt
        }

        var stmt: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if result != SQLITE_OK {
            if errorLogsEnabled {
                NSLog("KVStorage dbPrepareStmt error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
            }
            return nil
        }
        dbStmtCache?[sql] = stmt
        return stmt
    }

    private func dbJoinedKeys(_ keys: [String]) -> String {
        return keys.map { _ in "?" }.joined(separator: ",")
    }

    private func dbBindJoinedKeys(_ keys: [String], stmt: OpaquePointer, fromIndex index: Int32) {
        for i in 0..<Int32(keys.count) {
            let key = keys[Int(i)]
            sqlite3_bind_text(stmt, index + i, key, -1, SQLITE_TRANSIENT)
        }
    }

    @discardableResult
    private func dbSave(withKey key: String, value: Data, fileName: String?, extendedData: Data?) -> Bool {
        let sql = "insert or replace into manifest (key, filename, size, inline_data, modification_time, last_access_time, extended_data) values (?1, ?2, ?3, ?4, ?5, ?6, ?7);"
        guard let stmt = dbPrepareStmt(sql) else { return false }

        let timestamp = Int32(time(nil))
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, fileName, -1, SQLITE_TRANSIENT)
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
        if let extendedData = extendedData, !extendedData.isEmpty {
            extendedData.withUnsafeBytes { rawBuffer in
                _ = sqlite3_bind_blob(stmt, 7, rawBuffer.baseAddress, Int32(rawBuffer.count), SQLITE_TRANSIENT)
            }
        } else {
            sqlite3_bind_blob(stmt, 7, nil, 0, nil)
        }

        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE {
            if errorLogsEnabled {
                NSLog("KVStorage dbSave error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
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
        sqlite3_bind_text(stmt, 2, key, -1, SQLITE_TRANSIENT)
        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE {
            if errorLogsEnabled {
                NSLog("KVStorage dbUpdateAccessTime error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
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
        let result = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if result != SQLITE_OK {
            if errorLogsEnabled {
                NSLog("KVStorage dbUpdateAccessTimeWithKeys prepare error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
            }
            return false
        }

        dbBindJoinedKeys(keys, stmt: stmt!, fromIndex: 1)
        let stepResult = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if stepResult != SQLITE_DONE {
            if errorLogsEnabled {
                NSLog("KVStorage dbUpdateAccessTimeWithKeys step error (%d): %s", stepResult, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
            }
            return false
        }
        return true
    }

    @discardableResult
    private func dbDeleteItem(withKey key: String) -> Bool {
        let sql = "delete from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql) else { return false }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)

        let result = sqlite3_step(stmt)
        if result != SQLITE_DONE {
            if errorLogsEnabled {
                NSLog("KVStorage dbDeleteItem error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
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
        let result = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if result != SQLITE_OK {
            if errorLogsEnabled {
                NSLog("KVStorage dbDeleteItemWithKeys prepare error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
            }
            return false
        }

        dbBindJoinedKeys(keys, stmt: stmt!, fromIndex: 1)
        let stepResult = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        if stepResult == SQLITE_ERROR {
            if errorLogsEnabled {
                NSLog("KVStorage dbDeleteItemWithKeys step error (%d): %s", stepResult, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
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
        if result != SQLITE_DONE {
            if errorLogsEnabled {
                NSLog("KVStorage dbDeleteItemsWithSizeLargerThan error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
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
        if result != SQLITE_DONE {
            if errorLogsEnabled {
                NSLog("KVStorage dbDeleteItemsWithTimeEarlierThan error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
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
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)

        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW {
            return dbGetItem(fromStmt: stmt, excludeInlineData: excludeInlineData)
        } else {
            if result != SQLITE_DONE {
                if errorLogsEnabled {
                    NSLog("KVStorage dbGetItemWithKey error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
                }
            }
            return nil
        }
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
        let result = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if result != SQLITE_OK {
            if errorLogsEnabled {
                NSLog("KVStorage dbGetItemWithKeys prepare error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
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
                    NSLog("KVStorage dbGetItemWithKeys step error (%d): %s", stepResult, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
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
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)

        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW {
            let inlineData = sqlite3_column_blob(stmt, 0)
            let inlineDataBytes = sqlite3_column_bytes(stmt, 0)
            if inlineData == nil || inlineDataBytes <= 0 { return nil }
            return Data(bytes: inlineData!, count: Int(inlineDataBytes))
        } else {
            if result != SQLITE_DONE {
                if errorLogsEnabled {
                    NSLog("KVStorage dbGetValueWithKey error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
                }
            }
            return nil
        }
    }

    private func dbGetFilename(withKey key: String) -> String? {
        let sql = "select filename from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql) else { return nil }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        let result = sqlite3_step(stmt)
        if result == SQLITE_ROW {
            if let filename = sqlite3_column_text(stmt, 0) {
                let name = String(cString: filename)
                if !name.isEmpty { return name }
            }
        } else {
            if result != SQLITE_DONE {
                if errorLogsEnabled {
                    NSLog("KVStorage dbGetFilenameWithKey error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
                }
            }
        }
        return nil
    }

    private func dbGetFilename(withKeys keys: [String]) -> [String]? {
        if !dbCheck() { return nil }
        let sql = "select filename from manifest where key in (\(dbJoinedKeys(keys)));"
        var stmt: OpaquePointer?
        let result = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if result != SQLITE_OK {
            if errorLogsEnabled {
                NSLog("KVStorage dbGetFilenameWithKeys prepare error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
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
                    NSLog("KVStorage dbGetFilenameWithKeys step error (%d): %s", stepResult, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
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
                    NSLog("KVStorage dbGetFilenamesWithSizeLargerThan error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
                }
                filenames = nil
                break
            }
        }
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
                    NSLog("KVStorage dbGetFilenamesWithTimeEarlierThan error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
                }
                filenames = nil
                break
            }
        }
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
                    NSLog("KVStorage dbGetItemSizeInfoOrderByTimeAsc error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
                }
                items = nil
                break
            }
        }
        return items
    }

    private func dbGetItemCount(withKey key: String) -> Int32 {
        let sql = "select count(key) from manifest where key = ?1;"
        guard let stmt = dbPrepareStmt(sql) else { return -1 }
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        let result = sqlite3_step(stmt)
        if result != SQLITE_ROW {
            if errorLogsEnabled {
                NSLog("KVStorage dbGetItemCountWithKey error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
            }
            return -1
        }
        return sqlite3_column_int(stmt, 0)
    }

    private func dbGetTotalItemSize() -> Int32 {
        let sql = "select sum(size) from manifest;"
        guard let stmt = dbPrepareStmt(sql) else { return -1 }
        let result = sqlite3_step(stmt)
        if result != SQLITE_ROW {
            if errorLogsEnabled {
                NSLog("KVStorage dbGetTotalItemSize error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
            }
            return -1
        }
        return sqlite3_column_int(stmt, 0)
    }

    private func dbGetTotalItemCount() -> Int32 {
        let sql = "select count(*) from manifest;"
        guard let stmt = dbPrepareStmt(sql) else { return -1 }
        let result = sqlite3_step(stmt)
        if result != SQLITE_ROW {
            if errorLogsEnabled {
                NSLog("KVStorage dbGetTotalItemCount error (%d): %s", result, sqlite3_errmsg(db).flatMap { String(cString: $0) } ?? "")
            }
            return -1
        }
        return sqlite3_column_int(stmt, 0)
    }

    // MARK: - Private File Methods

    @discardableResult
    private func fileWrite(withName filename: String, data: Data) -> Bool {
        let filePath = (dataPath as NSString).appendingPathComponent(filename)
        do {
            try data.write(to: URL(fileURLWithPath: filePath), options: [])
            return true
        } catch {
            return false
        }
    }

    private func fileRead(withName filename: String) -> Data? {
        let filePath = (dataPath as NSString).appendingPathComponent(filename)
        return try? Data(contentsOf: URL(fileURLWithPath: filePath))
    }

    @discardableResult
    private func fileDelete(withName filename: String) -> Bool {
        let filePath = (dataPath as NSString).appendingPathComponent(filename)
        do {
            try FileManager.default.removeItem(atPath: filePath)
            return true
        } catch {
            return false
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

    // MARK: - Private Reset

    private func reset() {
        try? FileManager.default.removeItem(atPath: (path as NSString).appendingPathComponent(kDBFileName))
        try? FileManager.default.removeItem(atPath: (path as NSString).appendingPathComponent(kDBShmFileName))
        try? FileManager.default.removeItem(atPath: (path as NSString).appendingPathComponent(kDBWalFileName))
        fileMoveAllToTrash()
        fileEmptyTrashInBackground()
    }
}
