# RECache

[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2013%2B%20%7C%20tvOS%2013%2B%20%7C%20macOS%2010.15%2B%20%7C%20watchOS%206%2B-blue.svg)](https://developer.apple.com/swift/)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Language**: **English** · [简体中文](README_CN.md)

---

RECache is a modern, generic, **memory + disk** two-tier key-value cache for Swift. It was originally ported from [YYCache](https://github.com/ibireme/YYCache) but **v2 breaks API compatibility** to embrace a fully generic, `Codable`-friendly, `async/await`-native Swift design. The SQLite + file-system storage engine and LRU algorithms that made YYCache fast are preserved verbatim — only the interface layer was rewritten.

---

## ✨ Features

- **Full generics** — `MemoryCache<Key, Value>`, `DiskCache<Key, Value>`, `Cache<Key, Value>` with `Key: Hashable & Sendable`, `Value: Sendable`
- **`Transformer<Value>` serialization** — built-in factories for `Data`, `Codable` (JSON / binary plist), and `UIImage` / `NSImage`; or bring your own
- **Per-entry `Expiration`** — `.never`, `.seconds(_:)`, `.date(_:)`; resolution down to milliseconds on disk
- **Two-tier architecture** — a lock-free(ish) LRU linked-list memory layer on top of a SQLite + file-system disk layer that automatically picks the best storage medium per value
- **LRU eviction** — automatic trimming by count, cost, expiration, and free-disk-space
- **Smart storage selection** — values smaller than `inlineThreshold` (default 20KB) live as SQLite blobs; larger values spill to standalone files
- **Sync **and** `async`/`await` APIs** — every access method has a matching `asyncXxx` variant that dispatches off your thread
- **`extendedData`** — attach opaque metadata (ETag, source URL, decoding hints) to any cached entry without it affecting the `Transformer`
- **System event handling** — automatic response to memory warnings, backgrounding, and app termination
- **Swift 6 concurrency ready** — all public types are `Sendable`; every `@unchecked Sendable` carries a documented safety invariant

---

## 📦 Installation

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/reers/RECache.git", from: "2.0.0")
]
```

Then add `RECache` to your target's dependencies.

---

## 🚀 Quick Start

### A two-tier cache of `Codable` values

```swift
import RECache

struct Article: Codable, Sendable {
    let id: Int
    let title: String
    let body: String
}

let cache = Cache<Int, Article>(
    name: "articles",
    transformer: Transformers.codable()
)!

// Sync
try cache.set(article, forKey: 42)
let fetched = try cache.value(forKey: 42)   // memory first, disk fallback

// Async
try await cache.asyncSet(article, forKey: 42)
let fetched2 = try await cache.asyncValue(forKey: 42)

cache.remove(forKey: 42)
cache.removeAll()
```

### Raw `Data` (no encoding overhead)

```swift
let blobs = DiskCache<String, Data>(
    path: "/tmp/blobs",
    transformer: Transformers.data()
)!

try blobs.set(Data(...), forKey: "thumbnail")
let data = try blobs.value(forKey: "thumbnail")
```

### Images

```swift
#if canImport(UIKit)
let images = DiskCache<URL, UIImage>(
    path: NSTemporaryDirectory() + "images",
    transformer: Transformers.image()
)!
#endif
```

### Custom `Transformer`

```swift
let lz4: Transformer<MyModel> = Transformer(
    encode: { try compress(JSONEncoder().encode($0)) },
    decode: { try JSONDecoder().decode(MyModel.self, from: decompress($0)) }
)
```

---

## ⏳ Expiration

```swift
// Cache-level default
cache.memoryCache.expiration = .seconds(300)
cache.diskCache.expiration = .seconds(60 * 60 * 24)

// Per-entry override (applied to both layers)
try cache.set(article, forKey: 42, expiration: .seconds(30))
try cache.set(token, forKey: "auth", expiration: .date(expiresAt))

// Manual sweep
cache.memoryCache.removeExpired()
```

Semantics: expiration is measured from the **write time**. Reading an entry moves it to the head of the LRU list but does **not** refresh the write time. `set` always refreshes.

---

## 🧊 LRU limits

```swift
cache.memoryCache.countLimit = 500        // max number of entries
cache.memoryCache.costLimit = 50 * 1024 * 1024  // max total "cost" units

cache.diskCache.countLimit = 10_000
cache.diskCache.costLimit = 500 * 1024 * 1024   // max bytes on disk
cache.diskCache.freeDiskSpaceLimit = 100 * 1024 * 1024  // trim when disk free < 100MB

// Manual trim
cache.memoryCache.trim(toCount: 100)
cache.diskCache.trim(toCost: 50 * 1024 * 1024)
```

The background auto-trim timer runs every `autoTrimInterval` seconds (`5` for memory, `60` for disk by default).

---

## 🏷 Extended data

`extendedData` is opaque `Data` persisted **alongside** a cached value but **outside** the `Transformer` — useful for things like HTTP `ETag`, decode hints, or cache provenance that you don't want inside your `Codable` struct.

```swift
try cache.set(
    image,
    forKey: url,
    extendedData: "etag=abc123".data(using: .utf8)
)

if let meta = cache.extendedData(forKey: url) {
    // ...
}

// Fetch both in one round-trip
if let (value, meta) = try cache.diskCache.valueWithExtendedData(forKey: url) {
    // ...
}
```

---

## 🧵 Concurrency

- `MemoryCache`, `DiskCache`, and `Cache` are all `@unchecked Sendable`.
- `MemoryCache` is protected by `os_unfair_lock`; `DiskCache` by a `DispatchSemaphore`.
- `async` methods dispatch onto an internal `DispatchQueue` so they never block the caller's thread.
- `Transformer<Value>` is `Sendable` — encode / decode closures must be `@Sendable`.

### Concurrent key access

Reading and writing the same key from multiple concurrent tasks is safe — operations are serialized by the lock. If you need to make multiple reads / writes atomic with respect to each other, protect them at the call site.

---

## 🗺 Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Cache<Key, Value>                        │
│    (coordinates memory + disk, Transformer is shared)       │
└────────────────────────┬────────────────────────────────────┘
                         │
        ┌────────────────┴────────────────┐
        │                                 │
┌───────▼─────────┐              ┌────────▼────────────┐
│ MemoryCache     │              │ DiskCache           │
│  <Key, Value>   │              │  <Key, Value>       │
│ ─────────────── │              │ ─────────────────── │
│ LRU linked list │              │ entry = 18B header  │
│ os_unfair_lock  │              │       + transformer │
│ UIKit warnings  │              │ DispatchSemaphore   │
└─────────────────┘              └──────────┬──────────┘
                                            │
                                   ┌────────▼────────┐
                                   │  KVStorage      │
                                   │ (internal)      │
                                   │ ─────────────── │
                                   │ SQLite manifest │
                                   │ + data files    │
                                   │ + trash folder  │
                                   └─────────────────┘
```

`KVStorage` is kept **internal**; app code talks to it only via `DiskCache` or `Cache`. Every disk blob is prefixed with an 18-byte `EntryHeader` carrying the entry's expiration policy and high-resolution write date — the header is transparent to the `Transformer`.

---

## 🔑 Keys

Any `Hashable & Sendable` type works as a key. On disk, keys are converted to stable strings via `String(describing:)`; override `CustomStringConvertible.description` to control the on-disk representation:

```swift
struct ItemKey: Hashable, CustomStringConvertible {
    let userID: Int
    let scope: String
    var description: String { "\(scope)-\(userID)" }
}
```

For file names (used when values spill to standalone files on disk), override via `DiskCache.fileNameProvider`:

```swift
diskCache.fileNameProvider = { key in "item-\(key.userID)" }
```

---

## 📄 License

RECache is released under the MIT license. Portions derive from YYCache, also MIT. See [LICENSE](LICENSE).

---

## 🙏 Credits

- [YYCache](https://github.com/ibireme/YYCache) by ibireme — the SQLite + file-system storage engine and the LRU designs this library builds on.
- [hyperoslo/Cache](https://github.com/hyperoslo/Cache) — inspiration for the modern Swift-native API surface (`Transformer`, `Expiration`, generics).
