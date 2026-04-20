# RECache

[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2013%2B%20%7C%20tvOS%2013%2B%20%7C%20macOS%2011%2B%20%7C%20visionOS%201%2B-blue.svg)](https://developer.apple.com/swift/)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**语言**: [English](README.md) · **简体中文**

---

RECache 是一个现代化的、泛型化的 **内存 + 磁盘** 两级键值缓存。最初从 [YYCache](https://github.com/ibireme/YYCache) 移植而来，采用全面泛型 + `Codable` + `async/await` 的 Swift 原生设计。底层 SQLite + 文件系统存储引擎和 LRU 算法都原样保留 —— 只重写了接口层。

---

## ✨ 特性

- **完整泛型** — `MemoryCache<Key, Value>` / `DiskCache<Key, Value>` / `Cache<Key, Value>`，`Key: Hashable & Sendable`，`Value: Sendable`
- **`Transformer<Value>` 序列化** — 内置 `Data`、`Codable`（JSON / 二进制 plist）、`UIImage` / `NSImage` 几种工厂；也可以自定义
- **缓存级 `Expiration`** — `.never`、`.seconds(_:)`、`.date(_:)`，读取时以每条记录的写入时间为基准判定
- **两级架构** — 内存层是 LRU 双向链表，磁盘层是 SQLite + 文件系统，按条目大小自动选择存储介质
- **LRU 淘汰** — 按 count、cost、expiration、可用磁盘空间四个维度自动裁剪
- **智能存储选择** — 小于 `inlineThreshold`（默认 20KB）的值存为 SQLite blob，大值独立落盘
- **同步 + `async`/`await` 双 API** — 每个访问方法都有对应的 `asyncXxx` 版本，不会阻塞调用线程
- **`extendedData`** — 可以给任意缓存条目附加不透明的元数据（ETag、来源 URL、解码提示等），独立于 `Transformer`
- **系统事件响应** — 自动处理内存警告、切后台、应用终止
- **Swift 6 并发就绪** — 所有公开类型都是 `Sendable`，每处 `@unchecked Sendable` 都有明确的线程安全不变量注释

---

## 📦 安装

### Swift Package Manager

```swift
dependencies: [
    .package(url: "https://github.com/reers/RECache.git", from: "2.0.0")
]
```

然后把 `RECache` 加到你的 target 依赖里。

---

## 🚀 快速上手

### `Codable` 值的两级缓存

```swift
import RECache

struct Article: Codable, Sendable {
    let id: Int
    let title: String
    let body: String
}

let cache = Cache<Int, Article>(
    name: "articles",
    transformer: .codable()
)!

// 同步
try cache.set(article, forKey: 42)
let fetched = try cache.value(forKey: 42)   // 先查内存，命中不了回退到磁盘

// 异步 —— 同名，直接加 `await`。同步版本标了
// `@available(*, noasync)`，async 上下文里忘加 await 会警告
// （Swift 6 strict concurrency 下直接报错）。
try await cache.set(article, forKey: 42)
let fetched2 = try await cache.value(forKey: 42)

cache.remove(forKey: 42)
cache.removeAll()
```

### 裸 `Data`（零编码开销）

```swift
let blobs = DiskCache<String, Data>(
    path: "/tmp/blobs",
    transformer: .data()
)!

try blobs.set(Data(...), forKey: "thumbnail")
let data = try blobs.value(forKey: "thumbnail")
```

### 图片

```swift
#if canImport(UIKit)
let images = DiskCache<URL, UIImage>(
    path: NSTemporaryDirectory() + "images",
    transformer: .image()
)!
#endif
```

### 自定义 `Transformer`

```swift
let lz4: Transformer<MyModel> = Transformer(
    encode: { try compress(JSONEncoder().encode($0)) },
    decode: { try JSONDecoder().decode(MyModel.self, from: decompress($0)) }
)
```

---

## ⏳ 过期策略

```swift
// 分层配置 —— 内存和磁盘各自一个过期策略。
cache.memoryCache.expiration = .seconds(300)
cache.diskCache.expiration = .seconds(60 * 60 * 24)

// 也可以用绝对时间。
cache.memoryCache.expiration = .date(futureDate)

// 主动清理
cache.memoryCache.removeExpired()
cache.diskCache.removeExpired()
```

语义：过期判断基于每条记录的 **写入时间**。读取会把条目移到 LRU 头部，但 **不会** 刷新写入时间；`set` 会刷新。过期条目等价于 miss，在访问时惰性清除。磁盘层的写入时间精度为秒级。

---

## 🧊 LRU 限制

```swift
cache.memoryCache.countLimit = 500        // 条目数上限
cache.memoryCache.costLimit = 50 * 1024 * 1024  // cost 总和上限

cache.diskCache.countLimit = 10_000
cache.diskCache.costLimit = 500 * 1024 * 1024   // 磁盘字节数上限
cache.diskCache.freeDiskSpaceLimit = 100 * 1024 * 1024  // 可用空间少于 100MB 时开始裁剪

// 手动触发
cache.memoryCache.trim(toCount: 100)
cache.diskCache.trim(toCost: 50 * 1024 * 1024)
```

后台自动裁剪定时器默认每 `autoTrimInterval` 秒运行一次（内存 5 秒，磁盘 60 秒）。

---

## 🏷 扩展数据

`extendedData` 是和缓存值一起持久化的不透明 `Data`，但**在 `Transformer` 之外** —— 适合用来存 HTTP `ETag`、解码提示、数据来源这类不想写进你业务 `Codable` 结构里的信息。

```swift
try cache.set(
    image,
    forKey: url,
    extendedData: "etag=abc123".data(using: .utf8)
)

if let meta = cache.extendedData(forKey: url) {
    // ...
}

// 一次 round-trip 同时取值和元数据
if let (value, meta) = try cache.diskCache.valueWithExtendedData(forKey: url) {
    // ...
}
```

---

## 🧵 并发

- `MemoryCache`、`DiskCache`、`Cache` 都是 `@unchecked Sendable`
- `MemoryCache` 用 `os_unfair_lock` 保护；`DiskCache` 用 `DispatchSemaphore`
- `async` 方法派发到内部 `DispatchQueue`，不会阻塞调用线程
- `Transformer<Value>` 是 `Sendable`，`encode`/`decode` 闭包都需要 `@Sendable`

### 并发访问同一个 key

多个并发任务读写同一个 key 是安全的 —— 操作被锁串行化。如果需要"多次读写之间原子"的语义，请在调用方自行加锁。

---

## 🗺 架构

```
┌─────────────────────────────────────────────────────────────┐
│                    Cache<Key, Value>                        │
│    （协调内存 + 磁盘，共享同一个 Transformer）              │
└────────────────────────┬────────────────────────────────────┘
                         │
        ┌────────────────┴────────────────┐
        │                                 │
┌───────▼─────────┐              ┌────────▼────────────┐
│ MemoryCache     │              │ DiskCache           │
│  <Key, Value>   │              │  <Key, Value>       │
│ ─────────────── │              │ ─────────────────── │
│ LRU 双向链表    │              │ transformer 原始    │
│ os_unfair_lock  │              │       payload       │
│ UIKit 内存警告  │              │ DispatchSemaphore   │
└─────────────────┘              └──────────┬──────────┘
                                            │
                                   ┌────────▼────────┐
                                   │  KVStorage      │
                                   │（internal）     │
                                   │ ─────────────── │
                                   │ SQLite manifest │
                                   │ + 数据文件      │
                                   │ + trash 目录    │
                                   └─────────────────┘
```

`KVStorage` 对外 **internal**，业务代码只通过 `DiskCache` / `Cache` 访问它。磁盘上的每条记录就是 `Transformer` 的原始输出，没有任何额外的头部或封装；写入时间由 SQLite manifest 的 `modTime`（秒级精度）维护，供缓存级过期判定使用。

---

## 🔑 Key

任何满足 `Hashable & Sendable` 的类型都能做 Key。磁盘层会通过 `String(describing:)` 得到稳定的字符串表示；如果想自定义磁盘上的字符串形式，实现 `CustomStringConvertible`：

```swift
struct ItemKey: Hashable, CustomStringConvertible {
    let userID: Int
    let scope: String
    var description: String { "\(scope)-\(userID)" }
}
```

如果是值溢出到独立文件存储的场景，还可以用 `DiskCache.fileNameProvider` 自定义文件名：

```swift
diskCache.fileNameProvider = { key in "item-\(key.userID)" }
```

---

## 📊 性能测试

测试设备：**iPhone 15 Pro**，内存测试 200,000 条键值对，磁盘测试 1,000 条键值对。单位 **毫秒**（越低越好）。

### 内存缓存

| 测试项 | YYMemoryCache | RECache | NSCache | Swift Dict | Dict + Lock |
|------|:---:|:---:|:---:|:---:|:---:|
| **set**（20 万条） | 61.78 | **27.08** | 55.69 | 9.43 | 9.07 |
| **set**（无扩容） | 31.52 | **18.80** | 34.81 | 2.63 | 4.43 |
| **get**（顺序） | 20.95 | **17.11** | 21.56 | 2.72 | 2.95 |
| **get**（随机） | 31.09 | 32.29 | 31.97 | 5.05 | 5.00 |
| **get**（混合命中/未命中） | 28.49 | **27.86** | 24.93 | 6.32 | 6.68 |

> Swift Dict / Dict + Lock 作为基准参考，不含 LRU、淘汰、线程安全开销。

各列按 **文件模式 · SQLite 模式 · 混合模式（默认）** 分组。`YY (file)` / `YY (SQLite)` 直接调用 `YYKVStorage` 的文件模式/SQLite 模式；`YYDiskCache` 是其默认的混合模式。对应地，`RECache (file)` / `RECache (SQLite)` 把 `DiskCache` 强制固定为 `inlineThreshold: 0` / `.max`；**`RECache`** 是默认混合模式：小负载走 SQLite，大负载落文件。

### 磁盘缓存 — 写入

| 测试项 | YY (file) | RECache (file) | YY (SQLite) | RECache (SQLite) | YYDiskCache | **RECache** |
|------|:---:|:---:|:---:|:---:|:---:|:---:|
| **set** NSNumber | 322.54 | 386.41 | 49.23 | 57.36 | 49.96 | **51.14** |
| **set** Data (100KB) | 461.79 | **396.86** | 624.43 | 542.96 | 523.38 | **414.73** |
| **replace** NSNumber | 189.90 | 173.06 | 72.14 | 70.53 | 75.20 | **74.62** |
| **replace** Data (100KB) | 305.61 | 227.51 | 546.03 | 562.34 | 296.51 | **215.49** |

### 磁盘缓存 — 读取

| 测试项 | YY (file) | RECache (file) | YY (SQLite) | RECache (SQLite) | YYDiskCache | **RECache** |
|------|:---:|:---:|:---:|:---:|:---:|:---:|
| **get** NSNumber（随机，冷） | 152.90 | 154.20 | 29.78 | 31.28 | 28.66 | 37.55 |
| **get** Data 100KB（随机，冷） | 252.16 | 252.30 | 525.05 | 519.32 | 289.61 | **247.95** |
| **get** NSNumber（随机，热） | 149.28 | 148.06 | 36.82 | 36.59 | 32.48 | **32.09** |
| **get** Data 100KB（随机，热） | 246.95 | 249.26 | 539.86 | 537.50 | 279.30 | **243.34** |
| **get** 不存在（小值） | 1.94 | 1.95 | 1.98 | 1.98 | 2.00 | 1.95 |
| **get** 不存在（大值） | 1.84 | 1.81 | 1.87 | 1.83 | 1.86 | **1.83** |

> `RECache` 每次读写多走一层 ``Transformer`` / `Codable` 往返，会产生一个小的固定开销（NSNumber 写 `49.96 → 51.14`，NSNumber 读 `28.66 → 37.55`）。作为交换，默认混合模式在真正高频的场景上全面领先 —— 100 KB `Data` 的写入、读取，冷热两种状态均最快。

---

## 📄 许可证

RECache 采用 MIT 许可证，部分代码源自同为 MIT 许可证的 YYCache。详见 [LICENSE](LICENSE)。

---

## 🙏 致谢

- [YYCache](https://github.com/ibireme/YYCache)（作者 ibireme）—— 本库 SQLite + 文件系统存储引擎和 LRU 设计的基石
