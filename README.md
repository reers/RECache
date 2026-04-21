# RECache

[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2013%2B%20%7C%20tvOS%2013%2B%20%7C%20macOS%2011%2B%20%7C%20visionOS%201%2B-blue.svg)](https://developer.apple.com/swift/)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Language**: **English** · [简体中文](README_CN.md)

---

RECache is a modern, generic, **memory + disk** two-tier key-value cache for Swift. It was originally ported from [YYCache](https://github.com/ibireme/YYCache) and redesigned to embrace a fully generic, `Codable`-friendly, `async/await`-native Swift design. The SQLite + file-system storage engine and LRU algorithms that made YYCache fast are preserved verbatim — only the interface layer was rewritten. A few long-standing community fixes from stalled YYCache pull requests are also merged in: [`f874dd0`](https://github.com/reers/RECache/commit/f874dd07d8dbe5a8825bf4e08eeed9adb8fb4871) · [`ef9755b`](https://github.com/reers/RECache/commit/ef9755b093b8621503b13ab625507ce8731c9c8c) · [`c7efac0`](https://github.com/reers/RECache/commit/c7efac02fc6a24059d051808522fd4b194ef9101).

---

## ✨ Features

- **Full generics** — `MemoryCache<Key, Value>`, `DiskCache<Key, Value>`, `Cache<Key, Value>` with `Key: Hashable & Sendable`, `Value: Sendable`
- **`Transformer<Value>` serialization** — built-in factories for `Data`, `Codable` (JSON / binary plist), and `UIImage` / `NSImage`; or bring your own
- **Cache-level `Expiration`** — `.never`, `.seconds(_:)`, `.date(_:)`, evaluated at read time against each entry's write time
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
    .package(url: "https://github.com/reers/RECache.git", from: "1.0.0")
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

let cache = Cache<Int, Article>(name: "articles")!

// Sync
try cache.set(article, forKey: 42)
let fetched = try cache.value(forKey: 42)   // memory first, disk fallback

// Async — same names, just add `await`. Sync versions are marked
// `@available(*, noasync)`, so calling them from an async context
// warns (or errors under Swift 6 strict concurrency).
try await cache.set(article, forKey: 42)
let fetched2 = try await cache.value(forKey: 42)

cache.remove(forKey: 42)
cache.removeAll()
```

### Raw `Data` (no encoding overhead)

```swift
let blobs = DiskCache<String, Data>(path: "/tmp/blobs")!

try blobs.set(Data(...), forKey: "thumbnail")
let data = try blobs.value(forKey: "thumbnail")
```

### Images

```swift
#if canImport(UIKit)
let images = DiskCache<URL, UIImage>(path: NSTemporaryDirectory() + "images")!
#endif
```

> When `Value` is `Codable`, `Data`, or `UIImage`/`NSImage`, the initializer **automatically picks** the matching built-in `Transformer` — no need to specify one. See [Transformer](#-transformer) for details and customization.

---

## ⏳ Expiration

```swift
// Configured per layer — memory and disk have independent policies.
cache.memoryCache.expiration = .seconds(300)
cache.diskCache.expiration = .days(10)

// Or with an absolute deadline.
cache.memoryCache.expiration = .date(futureDate)

// Manual sweep
cache.memoryCache.removeExpired()
cache.diskCache.removeExpired()
```

Semantics: expiration is measured from each entry's **write time**. Reading an entry moves it to the head of the LRU list but does **not** refresh the write time. `set` always refreshes. Expired entries are treated as misses and removed lazily on access; the disk layer tracks write time at second-level precision.

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

## 🔄 Transformer

`DiskCache` needs a `Transformer<Value>` to convert values to/from `Data`. When you omit it from the initializer, the library auto-selects one based on `Value`:

| `Value` type | Auto-selected transformer | Notes |
|---|---|---|
| Any `Codable` | `.codable()` (JSON) | Pass `format: .binaryPlist` if your payload is `Data`-heavy |
| `Data` | `.data()` | Zero-copy pass-through |
| `UIImage` / `NSImage` | `.image()` | PNG for alpha, JPEG otherwise |

You can always pass a `Transformer` explicitly — useful for compressed, encrypted, or otherwise non-standard payloads:

```swift
let cache = Cache<String, MyModel>(
    name: "compressed",
    transformer: Transformer(
        encode: { try compress(JSONEncoder().encode($0)) },
        decode: { try JSONDecoder().decode(MyModel.self, from: decompress($0)) }
    )
)!
```

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
│ LRU linked list │              │ raw transformer     │
│ os_unfair_lock  │              │       payload       │
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

`KVStorage` is kept **internal**; app code talks to it only via `DiskCache` or `Cache`. Each disk entry is exactly what the `Transformer` produces — no header, no envelope — and its write time comes from the SQLite manifest's `modTime` (second-level precision) used for cache-level expiration checks.

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

## 📊 Benchmark

Tested on **iPhone 15 Pro**, 200,000 key-value pairs for memory, 1,000 key-value pairs for disk. All times in **milliseconds** (lower is better).

### Memory Cache

| Test | YYMemoryCache | RECache | NSCache | Swift Dict | Dict + Lock |
|------|:---:|:---:|:---:|:---:|:---:|
| **set** (200k pairs) | 61.78 | **27.08** | 55.69 | 9.43 | 9.07 |
| **set** (no resize) | 31.52 | **18.80** | 34.81 | 2.63 | 4.43 |
| **get** (sequential) | 20.95 | **17.11** | 21.56 | 2.72 | 2.95 |
| **get** (random) | 31.09 | 32.29 | 31.97 | 5.05 | 5.00 |
| **get** (mixed hit/miss) | 28.49 | **27.86** | 24.93 | 6.32 | 6.68 |

> Swift Dict / Dict + Lock are baselines without LRU, eviction, or thread safety overhead.

Columns are grouped **file mode · SQLite mode · mixed (default)**. `YY (file)` / `YY (SQLite)` talk to `YYKVStorage` directly; `YYDiskCache` is the default `YYDiskCache` (mixed mode). Likewise, `RECache (file)` / `RECache (SQLite)` pin `DiskCache` with `inlineThreshold: 0` / `.max`; **`RECache`** is the default mixed mode that auto-routes small payloads to SQLite and large ones to the file store.

### Disk Cache — Write

| Test | YY (file) | RECache (file) | YY (SQLite) | RECache (SQLite) | YYDiskCache | **RECache** |
|------|:---:|:---:|:---:|:---:|:---:|:---:|
| **set** NSNumber | 322.54 | 386.41 | 49.23 | 57.36 | 49.96 | **51.14** |
| **set** Data (100KB) | 461.79 | **396.86** | 624.43 | 542.96 | 523.38 | **414.73** |
| **replace** NSNumber | 189.90 | 173.06 | 72.14 | 70.53 | 75.20 | **74.62** |
| **replace** Data (100KB) | 305.61 | 227.51 | 546.03 | 562.34 | 296.51 | **215.49** |

### Disk Cache — Read

| Test | YY (file) | RECache (file) | YY (SQLite) | RECache (SQLite) | YYDiskCache | **RECache** |
|------|:---:|:---:|:---:|:---:|:---:|:---:|
| **get** NSNumber (random, cold) | 152.90 | 154.20 | 29.78 | 31.28 | 28.66 | 37.55 |
| **get** Data 100KB (random, cold) | 252.16 | 252.30 | 525.05 | 519.32 | 289.61 | **247.95** |
| **get** NSNumber (random, warm) | 149.28 | 148.06 | 36.82 | 36.59 | 32.48 | **39** |
| **get** Data 100KB (random, warm) | 246.95 | 249.26 | 539.86 | 537.50 | 279.30 | **243.34** |
| **get** none exist (small) | 1.94 | 1.95 | 1.98 | 1.98 | 2.00 | 1.95 |
| **get** none exist (large) | 1.84 | 1.81 | 1.87 | 1.83 | 1.86 | **1.83** |

> `RECache` pays a small fixed overhead per lookup to apply the ``Transformer`` / `Codable` round-trip (`49.96 → 51.14` for NSNumber writes, `28.66 → 37.55` for NSNumber reads). In exchange, the default mixed mode wins on the workloads that actually dominate in practice — 100 KB `Data` payloads, both write and read, cold and warm.

---

## 📄 License

RECache is released under the MIT license. Portions derive from YYCache, also MIT. See [LICENSE](LICENSE).

---

## 🙏 Credits

- [YYCache](https://github.com/ibireme/YYCache) by ibireme — the SQLite + file-system storage engine and the LRU designs this library builds on.
