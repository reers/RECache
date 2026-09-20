# RECache

[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2013%2B%20%7C%20tvOS%2013%2B%20%7C%20macOS%2011%2B%20%7C%20visionOS%201%2B-blue.svg)](https://developer.apple.com/swift/)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**语言**: [English](README.md) · **简体中文**

---

RECache 是一个现代化的、泛型化的 **内存 + 磁盘** 两级键值缓存。最初从 [YYCache](https://github.com/ibireme/YYCache) 移植而来，采用全面泛型 + `Codable` + `async/await` 的 Swift 原生设计。底层 SQLite + 文件系统存储引擎和 LRU 算法都原样保留 —— 只重写了接口层。另外合并了 YYCache 上游若干长期未合入的社区修复：[`f874dd0`](https://github.com/reers/RECache/commit/f874dd07d8dbe5a8825bf4e08eeed9adb8fb4871) · [`ef9755b`](https://github.com/reers/RECache/commit/ef9755b093b8621503b13ab625507ce8731c9c8c) · [`c7efac0`](https://github.com/reers/RECache/commit/c7efac02fc6a24059d051808522fd4b194ef9101)。

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
    .package(url: "https://github.com/reers/RECache.git", from: "1.0.2")
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

let cache = Cache<Int, Article>(name: "articles")!

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
let blobs = DiskCache<String, Data>(path: "/tmp/blobs")!

try blobs.set(Data(...), forKey: "thumbnail")
let data = try blobs.value(forKey: "thumbnail")
```

### 图片

```swift
#if canImport(UIKit)
let images = DiskCache<URL, UIImage>(path: NSTemporaryDirectory() + "images")!
#endif
```

> 当 `Value` 是 `Codable`、`Data` 或 `UIImage`/`NSImage` 时，初始化器会 **自动选择** 内置 `Transformer`，无需手动指定。详见 [Transformer](#-transformer) 章节。

---

## ⏳ 过期策略

```swift
// 分层配置 —— 内存和磁盘各自一个过期策略。
cache.memoryCache.expiration = .seconds(300)
cache.diskCache.expiration = .days(10)

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

## 🔄 Transformer

`DiskCache` 需要 `Transformer<Value>` 把值和 `Data` 互转。省略时库会根据 `Value` 类型自动选择：

| `Value` 类型 | 自动选择的 Transformer | 备注 |
|---|---|---|
| 任何 `Codable` | `.codable()`（JSON） | 若负载 `Data` 字段多，可传 `format: .binaryPlist` |
| `Data` | `.data()` | 零拷贝透传 |
| `UIImage` / `NSImage` | `.image()` | 有 alpha 用 PNG，否则 JPEG |

也可以显式传入自定义 `Transformer` —— 适用于压缩、加密等非标准场景：

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

| 测试项 | YYMemoryCache | PINCache | RECache | NSCache | Swift Dict | Dict + Lock |
|------|:---:|:---:|:---:|:---:|:---:|:---:|
| **set**（20 万条） | 43.69 | 128.21 | **24.88** | 58.40 | 8.50 | 9.15 |
| **set**（无扩容） | 26.94 | 67.68 | **17.95** | 38.51 | 2.40 | 4.69 |
| **get**（顺序） | 20.55 | 35.82 | **17.15** | 25.02 | 2.74 | 2.92 |
| **get**（随机） | 33.14 | 48.42 | **33.05** | 33.83 | 5.07 | 5.31 |
| **get**（混合命中/未命中） | 29.72 | 38.46 | 29.93 | 26.74 | 6.34 | 6.42 |

> Swift Dict / Dict + Lock 作为基准参考，不含 LRU、淘汰、线程安全开销。

各列按 **文件模式 · SQLite 模式 · 混合模式（默认）** 分组。`YY (file)` / `YY (SQLite)` 直接调用 `YYKVStorage` 的文件模式/SQLite 模式；`YYDiskCache` 是其默认的混合模式。`PINCache` 对应 `PINDiskCache`。对应地，`RECache (file)` / `RECache (SQLite)` 把 `DiskCache` 强制固定为 `inlineThreshold: 0` / `.max`；**`RECache`** 是默认混合模式：小负载走 SQLite，大负载落文件。

### 磁盘缓存 — 写入

| 测试项 | YY (file) | RECache (file) | YY (SQLite) | RECache (SQLite) | YYDiskCache | PINCache | **RECache** |
|------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **set** NSNumber | 144.09 | 142.27 | 36.66 | **32.46** | 37.87 | 576.34 | 49.04 |
| **set** Data (100KB) | 178.35 | **146.24** | 540.13 | 372.18 | 192.06 | 636.85 | **146.09** |
| **replace** NSNumber | 163.63 | 144.92 | 63.95 | 63.97 | 64.23 | 554.22 | **59.36** |
| **replace** Data (100KB) | 234.06 | **168.69** | 580.18 | 578.35 | 240.14 | 629.44 | 197.52 |

### 磁盘缓存 — 读取

| 测试项 | YY (file) | RECache (file) | YY (SQLite) | RECache (SQLite) | YYDiskCache | PINCache | **RECache** |
|------|:---:|:---:|:---:|:---:|:---:|:---:|:---:|
| **get** NSNumber（随机，冷） | 160.39 | 153.76 | 39.97 | 41.01 | 39.24 | 204.82 | **38.01** |
| **get** Data 100KB（随机，冷） | 248.20 | **242.64** | 514.17 | 502.30 | 251.09 | 302.33 | 247.16 |
| **get** NSNumber（随机，热） | 161.85 | 156.78 | 42.62 | 40.99 | 41.22 | 205.64 | **39.55** |
| **get** Data 100KB（随机，热） | 243.25 | 245.09 | 532.42 | 513.66 | 246.29 | 302.12 | **245.85** |
| **get** 不存在（小值） | 1.96 | 1.95 | 1.99 | **1.95** | 2.01 | 30.21 | 2.03 |
| **get** 不存在（大值） | 2.03 | 1.95 | 1.95 | **1.83** | 1.98 | 30.81 | 1.96 |

> `RECache` 每次读写多走一层 ``Transformer`` / `Codable` 往返，会产生一个小的固定开销（NSNumber 写 `37.87 → 49.04`）。作为交换，默认混合模式在真正高频的场景上领先 —— 100 KB `Data` 写入明显更快，读取与 `YYDiskCache` 持平。

---

## 📄 许可证

RECache 采用 MIT 许可证，部分代码源自同为 MIT 许可证的 YYCache。详见 [LICENSE](LICENSE)。

---

## 🙏 致谢

- [YYCache](https://github.com/ibireme/YYCache)（作者 ibireme）—— 本库 SQLite + 文件系统存储引擎和 LRU 设计的基石
