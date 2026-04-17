# RECache

[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2013%2B%20%7C%20tvOS%2013%2B-blue.svg)](https://developer.apple.com/swift/)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Language**: **English** · [简体中文](README_CN.md)

---

RECache is a strict Swift port of [YYCache](https://github.com/ibireme/YYCache). It preserves 1:1 API semantics and behavior of the original library while adapting to Swift 6's strict concurrency model.

It is designed for high-performance **memory + disk** two-tier key-value caching on iOS / tvOS (images, JSON payloads, archived objects, etc.).

---

## ✨ Features

- **Two-tier architecture** — a fast LRU doubly-linked-list memory layer on top of a SQLite + file-system disk layer that automatically picks the best storage medium per value
- **LRU eviction** — automatic trimming along four axes: count, cost, age, and free-disk-space
- **Smart storage selection** — values smaller than `inlineThreshold` (default 20KB) are stored as SQLite blobs; larger values are written as standalone files, balancing read and write performance
- **Sync & async APIs** — every access method ships with both a blocking variant and a background-queue block variant
- **System event handling** — automatic response to memory warnings, backgrounding, and app termination notifications
- **Swift 6 concurrency ready** — all public types satisfy `Sendable`; every `@unchecked Sendable` carries an explicit safety invariant and a documented evolution plan
- **Automatic trimming** — built-in background timer periodically enforces all configured limits
- **Extended metadata** — each cached object can carry auxiliary `extendedData` (e.g. image decoding info)

---

## 📦 Installation

### Swift Package Manager

Add the dependency to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/reers/RECache.git", from: "0.1.0")
]
```

Then add `RECache` to the `dependencies` list of your target.

Or in Xcode: `File > Add Package Dependencies...` and enter `https://github.com/reers/RECache.git`.

---

## 🚀 Quick Start

### Top-level `Cache` (memory + disk)

The most common entry point — internally coordinates `MemoryCache` and `DiskCache`:

```swift
import RECache

guard let cache = Cache(name: "ImageCache") else { return }

cache.setObject("Hello, World!" as NSString, forKey: "greeting")

if let value = cache.object(forKey: "greeting") as? NSString {
    print(value)
}

cache.object(forKey: "greeting") { key, object in
    print("async get \(key) -> \(object ?? "")")
}

cache.removeObject(forKey: "greeting")
cache.removeAllObjects()
```

### `MemoryCache` only

A generic cache where `Key: Hashable & Sendable` and `Value: Sendable`:

```swift
let memCache = MemoryCache<String, UIImage>()
memCache.countLimit = 100
memCache.costLimit = 50 * 1024 * 1024
memCache.ageLimit = 300

memCache.setObject(image, forKey: "avatar", cost: image.diskByteCount)

if let cached = memCache.object(forKey: "avatar") {
    imageView.image = cached
}
```

### `DiskCache` only

```swift
let path = NSSearchPathForDirectoriesInDomains(.cachesDirectory, .userDomainMask, true)[0]
    + "/MyDiskCache"

guard let diskCache = DiskCache.shared(path: path) else { return }

diskCache.countLimit = 10_000
diskCache.costLimit = 500 * 1024 * 1024
diskCache.freeDiskSpaceLimit = 100 * 1024 * 1024

diskCache.setObject(largeData as NSData, forKey: "payload") {
    print("saved to disk")
}
```

### Custom archiving & filenames

For types that don't conform to `NSCoding`, plug in your own archive / unarchive closures:

```swift
diskCache.customArchiveBlock = { object in
    try? JSONEncoder().encode(object as? MyCodable)
}
diskCache.customUnarchiveBlock = { data in
    try? JSONDecoder().decode(MyCodable.self, from: data)
}
diskCache.customFileNameBlock = { key in
    key.replacingOccurrences(of: "/", with: "_")
}
```

---

## 🏗️ Architecture

```
┌──────────────────────────────────────┐
│              Cache                   │   Facade: memory + disk coordination
├────────────────┬─────────────────────┤
│  MemoryCache   │     DiskCache       │
│  (LRU list)    │  (archive + LRU)    │
│                ├─────────────────────┤
│                │      KVStorage      │   SQLite + file-system backend
└────────────────┴─────────────────────┘
```

| Type | Responsibility |
| --- | --- |
| `Cache` | Top-level API — reads hit memory first, falling back to disk and repopulating memory on miss |
| `MemoryCache<Key, Value>` | Thread-safe LRU memory cache backed by a doubly-linked list + hash map; supports count / cost / age eviction |
| `DiskCache` | `KVStorage`-backed disk cache that adds archiving, LRU eviction, and free-space management |
| `KVStorage` | Low-level key-value store; `KVStorageType` (`.sqlite` / `.file` / `.mixed`) controls where each value is placed |
| `NSCodingBox` | `Sendable` wrapper around `any NSCoding`, used to safely pass values through Swift 6 concurrency boundaries |

Disk layout produced by `KVStorage`:

```
/path/
  ├── manifest.sqlite          # metadata & small inline blobs
  ├── manifest.sqlite-shm
  ├── manifest.sqlite-wal
  ├── data/                    # standalone files for large values
  │   └── e10adc3949ba59abbe56e057f20f883e
  └── trash/                   # removal staging (emptied asynchronously)
```

---

## ⚙️ Configuration

### MemoryCache

| Property | Description | Default |
| --- | --- | --- |
| `countLimit` | Maximum number of objects | `Int.max` |
| `costLimit` | Maximum total cost (bytes) | `Int.max` |
| `ageLimit` | Maximum age of an object (seconds) | `.greatestFiniteMagnitude` |
| `autoTrimInterval` | Auto-trim check interval | `5.0` seconds |
| `shouldRemoveAllObjectsOnMemoryWarning` | Flush on memory warning | `true` |
| `shouldRemoveAllObjectsWhenEnteringBackground` | Flush when entering background | `true` |

### DiskCache

| Property | Description | Default |
| --- | --- | --- |
| `inlineThreshold` | Values larger than this are stored as separate files; smaller ones go into SQLite | `20480` (20KB) |
| `countLimit` | Maximum number of objects | `UInt.max` |
| `costLimit` | Maximum total bytes | `UInt.max` |
| `ageLimit` | Maximum age of an object (seconds) | `.greatestFiniteMagnitude` |
| `freeDiskSpaceLimit` | Minimum free disk space to maintain; eviction triggers below this threshold | `0` |
| `autoTrimInterval` | Auto-trim check interval | `60` seconds |

---

## 🧵 Concurrency Model

- `MemoryCache` uses `os_unfair_lock` to protect its internal linked list
- `DiskCache` uses a `DispatchSemaphore` to serialize access to the underlying `KVStorage`
- `KVStorage` is **not** thread-safe on its own — all access must happen inside the `DiskCache` lock
- To keep binary compatibility with `YYCache`'s synchronous API, `Cache` / `DiskCache` use `@unchecked Sendable`. Every such use is annotated in source with its safety invariant and a future migration plan toward an `actor`-based API.

---

## 🧪 Testing

The project uses [Swift Testing](https://developer.apple.com/documentation/testing) and provides unit tests for `MemoryCache`, `DiskCache`, `KVStorage`, and `Cache`:

```bash
swift test
```

---

## 📋 Requirements

- Swift 6.0+
- iOS 13.0+ / tvOS 13.0+
- Xcode 16.0+

---

## 📝 Credits

RECache is a Swift port of [ibireme/YYCache](https://github.com/ibireme/YYCache). Huge thanks to the original author **ibireme** for the outstanding work.

---

## 📄 License

RECache is released under the MIT License. See [LICENSE](LICENSE) for details.

The underlying algorithms, disk layout, and API design originate from YYCache (MIT License, © 2015 ibireme).
