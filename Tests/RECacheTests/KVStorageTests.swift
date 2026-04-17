import Testing
import Foundation
@testable import RECache

@Suite("KVStorage")
struct KVStorageTests {

    private func makeTempDir() -> String {
        let dir = NSTemporaryDirectory() + "KVStorageTests/\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Initialization

    @Test func initSQLite() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let storage = KVStorage(path: dir, type: .sqlite)
        #expect(storage != nil)
        #expect(storage?.type == .sqlite)
        #expect(storage?.path == dir)
    }

    @Test func initFile() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let storage = KVStorage(path: dir, type: .file)
        #expect(storage != nil)
        #expect(storage?.type == .file)
    }

    @Test func initMixed() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        let storage = KVStorage(path: dir, type: .mixed)
        #expect(storage != nil)
        #expect(storage?.type == .mixed)
    }

    @Test func initCreatesDirectories() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        _ = KVStorage(path: dir, type: .sqlite)

        let fm = FileManager.default
        var isDir: ObjCBool = false
        #expect(fm.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue)
        #expect(fm.fileExists(atPath: (dir as NSString).appendingPathComponent("data"), isDirectory: &isDir) && isDir.boolValue)
        #expect(fm.fileExists(atPath: (dir as NSString).appendingPathComponent("trash"), isDirectory: &isDir) && isDir.boolValue)
    }

    @Test func initWithEmptyPathFails() {
        let storage = KVStorage(path: "", type: .sqlite)
        #expect(storage == nil)
    }

    @Test func initWithTooLongPathFails() {
        let longPath = String(repeating: "a", count: 1024)
        let storage = KVStorage(path: longPath, type: .sqlite)
        #expect(storage == nil)
    }

    // MARK: - Save & Get (SQLite mode)

    @Test func saveAndGetSQLite() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        let key = "testKey"
        let value = Data("hello world".utf8)
        #expect(storage.saveItem(withKey: key, value: value))

        let item = storage.getItem(forKey: key)
        #expect(item != nil)
        #expect(item?.key == key)
        #expect(item?.value == value)
    }

    @Test func getValueSQLite() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        let key = "k1"
        let value = Data("data123".utf8)
        storage.saveItem(withKey: key, value: value)

        let retrieved = storage.getItemValue(forKey: key)
        #expect(retrieved == value)
    }

    @Test func getItemInfoSQLite() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        let key = "infoKey"
        let value = Data("infoValue".utf8)
        storage.saveItem(withKey: key, value: value)

        let info = storage.getItemInfo(forKey: key)
        #expect(info != nil)
        #expect(info?.key == key)
        #expect(info?.size == Int32(value.count))
    }

    // MARK: - Save & Get (File mode)

    @Test func saveAndGetFile() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .file) else {
            Issue.record("Failed to create storage")
            return
        }

        let key = "fileKey"
        let value = Data("file data content".utf8)
        let filename = "testfile.dat"

        #expect(storage.saveItem(withKey: key, value: value, filename: filename, extendedData: nil))

        let dataPath = (dir as NSString).appendingPathComponent("data")
        let filePath = (dataPath as NSString).appendingPathComponent(filename)
        #expect(FileManager.default.fileExists(atPath: filePath))

        let item = storage.getItem(forKey: key)
        #expect(item != nil)
        #expect(item?.value == value)
        #expect(item?.filename == filename)
    }

    @Test func fileModeSaveWithoutFilenameFails() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .file) else {
            Issue.record("Failed to create storage")
            return
        }

        let result = storage.saveItem(withKey: "k", value: Data("v".utf8))
        #expect(result == false)
    }

    // MARK: - Save & Get (Mixed mode)

    @Test func mixedModeWithFilename() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .mixed) else {
            Issue.record("Failed to create storage")
            return
        }

        let key = "mixedFileKey"
        let value = Data("mixed file data".utf8)
        let filename = "mixed.dat"
        #expect(storage.saveItem(withKey: key, value: value, filename: filename, extendedData: nil))

        let item = storage.getItem(forKey: key)
        #expect(item?.value == value)
        #expect(item?.filename == filename)
    }

    @Test func mixedModeWithoutFilename() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .mixed) else {
            Issue.record("Failed to create storage")
            return
        }

        let key = "mixedSQLiteKey"
        let value = Data("mixed sqlite data".utf8)
        #expect(storage.saveItem(withKey: key, value: value))

        let retrieved = storage.getItemValue(forKey: key)
        #expect(retrieved == value)
    }

    // MARK: - Remove Operations

    @Test func removeSingleKey() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        storage.saveItem(withKey: "k1", value: Data("v1".utf8))
        #expect(storage.itemExists(forKey: "k1") == true)
        #expect(storage.removeItem(forKey: "k1") == true)
        #expect(storage.itemExists(forKey: "k1") == false)
    }

    @Test func removeMultipleKeys() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        storage.saveItem(withKey: "a", value: Data("1".utf8))
        storage.saveItem(withKey: "b", value: Data("2".utf8))
        storage.saveItem(withKey: "c", value: Data("3".utf8))
        #expect(storage.getItemsCount() == 3)

        #expect(storage.removeItem(forKeys: ["a", "b"]) == true)
        #expect(storage.getItemsCount() == 1)
        #expect(storage.itemExists(forKey: "c") == true)
    }

    @Test func removeItemsLargerThanSize() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        let small = Data("sm".utf8)
        let large = Data(repeating: 0x41, count: 1000)
        storage.saveItem(withKey: "small", value: small)
        storage.saveItem(withKey: "large", value: large)

        #expect(storage.removeItemsLargerThanSize(100) == true)
        #expect(storage.itemExists(forKey: "small") == true)
        #expect(storage.itemExists(forKey: "large") == false)
    }

    @Test func removeItemsEarlierThanTime() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        storage.saveItem(withKey: "k1", value: Data("v1".utf8))

        let futureTime = Int32(time(nil)) + 100
        #expect(storage.removeItemsEarlierThanTime(futureTime) == true)
        #expect(storage.getItemsCount() == 0)
    }

    @Test func removeFileItems() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .mixed) else {
            Issue.record("Failed to create storage")
            return
        }

        let filename = "toremove.dat"
        storage.saveItem(withKey: "fk", value: Data("file data".utf8), filename: filename, extendedData: nil)
        #expect(storage.itemExists(forKey: "fk") == true)

        let dataPath = (dir as NSString).appendingPathComponent("data")
        let filePath = (dataPath as NSString).appendingPathComponent(filename)
        #expect(FileManager.default.fileExists(atPath: filePath))

        #expect(storage.removeItem(forKey: "fk") == true)
        #expect(storage.itemExists(forKey: "fk") == false)
        #expect(FileManager.default.fileExists(atPath: filePath) == false)
    }

    // MARK: - Trim Operations

    @Test func removeItemsToFitSize() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        for i in 0..<10 {
            storage.saveItem(withKey: "key\(i)", value: Data(repeating: UInt8(i), count: 100))
        }

        #expect(storage.getItemsSize() == 1000)
        #expect(storage.removeItemsToFitSize(500) == true)
        #expect(storage.getItemsSize() <= 500)
    }

    @Test func removeItemsToFitCount() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        for i in 0..<10 {
            storage.saveItem(withKey: "key\(i)", value: Data("value\(i)".utf8))
        }

        #expect(storage.getItemsCount() == 10)
        #expect(storage.removeItemsToFitCount(5) == true)
        #expect(storage.getItemsCount() <= 5)
    }

    // MARK: - Remove All

    @Test func removeAllItems() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        for i in 0..<20 {
            storage.saveItem(withKey: "key\(i)", value: Data("val\(i)".utf8))
        }
        #expect(storage.getItemsCount() == 20)

        #expect(storage.removeAllItems() == true)
        #expect(storage.getItemsCount() == 0)
    }

    @Test func removeAllItemsWithProgress() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        for i in 0..<10 {
            storage.saveItem(withKey: "key\(i)", value: Data("val\(i)".utf8))
        }

        var progressCalled = false
        var endCalled = false
        var endError = true

        storage.removeAllItems(progress: { removedCount, totalCount in
            progressCalled = true
            #expect(totalCount == 10)
            #expect(removedCount >= 0)
            #expect(removedCount <= totalCount)
        }, end: { error in
            endCalled = true
            endError = error
        })

        #expect(progressCalled == true)
        #expect(endCalled == true)
        #expect(endError == false)
        #expect(storage.getItemsCount() == 0)
    }

    @Test func removeAllThenSaveAgain() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        storage.saveItem(withKey: "before", value: Data("data".utf8))
        #expect(storage.removeAllItems() == true)

        storage.saveItem(withKey: "after", value: Data("new data".utf8))
        #expect(storage.getItemsCount() == 1)
        #expect(storage.getItemValue(forKey: "after") == Data("new data".utf8))
    }

    // MARK: - Status Queries

    @Test func itemExistsForKey() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        #expect(storage.itemExists(forKey: "nope") == false)
        storage.saveItem(withKey: "yes", value: Data("v".utf8))
        #expect(storage.itemExists(forKey: "yes") == true)
    }

    @Test func getItemsCount() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        #expect(storage.getItemsCount() == 0)
        storage.saveItem(withKey: "a", value: Data("1".utf8))
        storage.saveItem(withKey: "b", value: Data("2".utf8))
        #expect(storage.getItemsCount() == 2)
    }

    @Test func getItemsSize() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        #expect(storage.getItemsSize() == 0)
        let data = Data(repeating: 0xFF, count: 256)
        storage.saveItem(withKey: "k", value: data)
        #expect(storage.getItemsSize() == 256)
    }

    // MARK: - Extended Data

    @Test func saveAndRetrieveExtendedData() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        let key = "extKey"
        let value = Data("main value".utf8)
        let extData = Data("extended info".utf8)
        storage.saveItem(withKey: key, value: value, filename: nil, extendedData: extData)

        let item = storage.getItem(forKey: key)
        #expect(item != nil)
        #expect(item?.extendedData == extData)
    }

    @Test func extendedDataWithFile() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .mixed) else {
            Issue.record("Failed to create storage")
            return
        }

        let key = "extFileKey"
        let value = Data("file value".utf8)
        let extData = Data("ext for file".utf8)
        let filename = "ext_test.dat"
        storage.saveItem(withKey: key, value: value, filename: filename, extendedData: extData)

        let item = storage.getItem(forKey: key)
        #expect(item?.extendedData == extData)
        #expect(item?.value == value)
    }

    // MARK: - Edge Cases

    @Test func emptyKeyReturnsNil() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        #expect(storage.saveItem(withKey: "", value: Data("v".utf8)) == false)
        #expect(storage.getItem(forKey: "") == nil)
        #expect(storage.getItemValue(forKey: "") == nil)
        #expect(storage.itemExists(forKey: "") == false)
        #expect(storage.removeItem(forKey: "") == false)
    }

    @Test func emptyValueFails() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        #expect(storage.saveItem(withKey: "k", value: Data()) == false)
    }

    @Test func veryLargeData() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        let bigData = Data(repeating: 0xAB, count: 100_000)
        storage.saveItem(withKey: "big", value: bigData)
        let retrieved = storage.getItemValue(forKey: "big")
        #expect(retrieved == bigData)
    }

    @Test func nonExistentKey() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        #expect(storage.getItem(forKey: "nokey") == nil)
        #expect(storage.getItemValue(forKey: "nokey") == nil)
        #expect(storage.getItemInfo(forKey: "nokey") == nil)
    }

    @Test func removeEmptyKeysFails() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        #expect(storage.removeItem(forKeys: []) == false)
    }

    // MARK: - Update Behavior

    @Test func saveKeyTwiceUpdates() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        let key = "dup"
        storage.saveItem(withKey: key, value: Data("first".utf8))
        storage.saveItem(withKey: key, value: Data("second".utf8))

        #expect(storage.getItemsCount() == 1)
        let value = storage.getItemValue(forKey: key)
        #expect(value == Data("second".utf8))
    }

    @Test func updateFileToSQLiteInMixed() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .mixed) else {
            Issue.record("Failed to create storage")
            return
        }

        let key = "switchKey"
        let filename = "switch.dat"
        storage.saveItem(withKey: key, value: Data("file data".utf8), filename: filename, extendedData: nil)
        #expect(storage.getItem(forKey: key)?.filename == filename)

        storage.saveItem(withKey: key, value: Data("sqlite data".utf8))
        let item = storage.getItem(forKey: key)
        #expect(item?.filename == nil)
        #expect(item?.value == Data("sqlite data".utf8))

        let dataPath = (dir as NSString).appendingPathComponent("data")
        let filePath = (dataPath as NSString).appendingPathComponent(filename)
        #expect(FileManager.default.fileExists(atPath: filePath) == false)
    }

    // MARK: - Access Time

    @Test func getUpdatesAccessTime() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        let key = "timeKey"
        storage.saveItem(withKey: key, value: Data("v".utf8))

        let info1 = storage.getItemInfo(forKey: key)
        let accessTime1 = info1?.accessTime ?? 0

        Thread.sleep(forTimeInterval: 1.1)
        _ = storage.getItemValue(forKey: key)

        let info2 = storage.getItemInfo(forKey: key)
        let accessTime2 = info2?.accessTime ?? 0
        #expect(accessTime2 >= accessTime1)
    }

    // MARK: - SaveItem API

    @Test func saveItemObject() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        let item = KVStorageItem()
        item.key = "itemKey"
        item.value = Data("itemValue".utf8)
        #expect(storage.saveItem(item))

        let retrieved = storage.getItem(forKey: "itemKey")
        #expect(retrieved?.value == Data("itemValue".utf8))
    }

    // MARK: - Multi-key Get

    @Test func getMultipleItemsSQLite() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        storage.saveItem(withKey: "m1", value: Data("v1".utf8))
        storage.saveItem(withKey: "m2", value: Data("v2".utf8))
        storage.saveItem(withKey: "m3", value: Data("v3".utf8))

        let items = storage.getItem(forKeys: ["m1", "m2", "m3"])
        #expect(items?.count == 3)
    }

    @Test func getMultipleItemInfos() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        storage.saveItem(withKey: "i1", value: Data("v1".utf8))
        storage.saveItem(withKey: "i2", value: Data("v2".utf8))

        let infos = storage.getItemInfo(forKeys: ["i1", "i2"])
        #expect(infos?.count == 2)
    }

    @Test func getMultipleItemValues() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        storage.saveItem(withKey: "v1", value: Data("data1".utf8))
        storage.saveItem(withKey: "v2", value: Data("data2".utf8))

        let values = storage.getItemValue(forKeys: ["v1", "v2"])
        #expect(values?.count == 2)
        #expect(values?["v1"] == Data("data1".utf8))
        #expect(values?["v2"] == Data("data2".utf8))
    }

    @Test func getEmptyKeyArrayReturnsNil() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        #expect(storage.getItem(forKeys: []) == nil)
        #expect(storage.getItemInfo(forKeys: []) == nil)
        #expect(storage.getItemValue(forKeys: []) == nil)
    }

    // MARK: - Error Logs Flag

    @Test func errorLogsEnabledDefault() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }
        #expect(storage.errorLogsEnabled == true)
        storage.errorLogsEnabled = false
        #expect(storage.errorLogsEnabled == false)
    }

    // MARK: - Remove edge cases

    @Test func removeItemsLargerThanIntMax() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        storage.saveItem(withKey: "k", value: Data("v".utf8))
        #expect(storage.removeItemsLargerThanSize(Int32.max) == true)
        #expect(storage.getItemsCount() == 1)
    }

    @Test func removeItemsToFitSizeIntMax() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        storage.saveItem(withKey: "k", value: Data("v".utf8))
        #expect(storage.removeItemsToFitSize(Int32.max) == true)
        #expect(storage.getItemsCount() == 1)
    }

    @Test func removeItemsToFitCountIntMax() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        storage.saveItem(withKey: "k", value: Data("v".utf8))
        #expect(storage.removeItemsToFitCount(Int32.max) == true)
        #expect(storage.getItemsCount() == 1)
    }

    @Test func removeItemsToFitSizeZero() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        storage.saveItem(withKey: "k", value: Data("v".utf8))
        #expect(storage.removeItemsToFitSize(0) == true)
        #expect(storage.getItemsCount() == 0)
    }

    @Test func removeItemsToFitCountZero() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        storage.saveItem(withKey: "k", value: Data("v".utf8))
        #expect(storage.removeItemsToFitCount(0) == true)
        #expect(storage.getItemsCount() == 0)
    }

    @Test func removeEarlierThanTimeZero() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        storage.saveItem(withKey: "k", value: Data("v".utf8))
        #expect(storage.removeItemsEarlierThanTime(0) == true)
        #expect(storage.getItemsCount() == 1)
    }

    @Test func removeEarlierThanTimeIntMax() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .sqlite) else {
            Issue.record("Failed to create storage")
            return
        }

        storage.saveItem(withKey: "k", value: Data("v".utf8))
        #expect(storage.removeItemsEarlierThanTime(Int32.max) == true)
        #expect(storage.getItemsCount() == 0)
    }

    // MARK: - File mode trim operations

    @Test func removeItemsLargerThanSizeFileMode() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .file) else {
            Issue.record("Failed to create storage")
            return
        }

        storage.saveItem(withKey: "small", value: Data("sm".utf8), filename: "small.dat", extendedData: nil)
        storage.saveItem(withKey: "large", value: Data(repeating: 0x41, count: 1000), filename: "large.dat", extendedData: nil)

        #expect(storage.removeItemsLargerThanSize(100) == true)
        #expect(storage.itemExists(forKey: "small") == true)
        #expect(storage.itemExists(forKey: "large") == false)
    }

    @Test func removeItemsToFitCountFileMode() {
        let dir = makeTempDir()
        defer { cleanup(dir) }
        guard let storage = KVStorage(path: dir, type: .file) else {
            Issue.record("Failed to create storage")
            return
        }

        for i in 0..<5 {
            storage.saveItem(withKey: "key\(i)", value: Data("val\(i)".utf8), filename: "file\(i).dat", extendedData: nil)
        }

        #expect(storage.getItemsCount() == 5)
        #expect(storage.removeItemsToFitCount(2) == true)
        #expect(storage.getItemsCount() <= 2)
    }
}
