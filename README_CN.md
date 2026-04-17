# RECache

[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2013%2B%20%7C%20tvOS%2013%2B-blue.svg)](https://developer.apple.com/swift/)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**语言 / Language**：[English](README.md) · **简体中文**

---

RECache 是对 [YYCache](https://github.com/ibireme/YYCache) 的 Swift 严格移植版本，保留与原库 1:1 对齐的 API 语义和行为，同时适配 Swift 6 的严格并发检查模型。

适用于在 iOS / tvOS 应用中做高性能的**内存 + 磁盘**双级键值缓存（图片、JSON、归档对象等）。

---

## ✨ 特性

- **双层缓存架构**：内存层使用 LRU 双向链表实现快速读写；磁盘层基于 SQLite + 文件系统，自动根据数据大小选择最优存储方式
- **LRU 淘汰策略**：按 count / cost / age / 空闲磁盘空间四个维度自动淘汰最久未访问项
- **智能存储选型**：小于 `inlineThreshold`（默认 20KB）的数据直接存 SQLite blob，大数据落地为独立文件，兼顾读写性能
- **同步 & 异步 API**：每个访问方法都提供阻塞版本和基于 block 的后台队列版本
- **系统事件响应**：内存警告、进入后台、应用即将终止等通知的自动处理
- **Swift 6 并发安全**：所有公共类型满足 `Sendable` 约束，并在源码中明确标注 `@unchecked Sendable` 的安全不变量与演进方案
- **自动修剪**：内置后台定时器周期性检查并淘汰超限数据
- **扩展元数据**：支持为每个缓存对象关联附加的 `extendedData`（比如图片解码信息）

---

## 📦 安装

### Swift Package Manager

在 `Package.swift` 中添加依赖：

```swift
dependencies: [
    .package(url: "https://github.com/reers/RECache.git", from: "0.1.0")
]
```

然后将 `RECache` 加入你的 target 的 `dependencies` 列表中。

或者在 Xcode 里：`File > Add Package Dependencies...` 输入 `https://github.com/reers/RECache.git` 即可。

---

## 🚀 快速开始

### 顶层 `Cache`（内存 + 磁盘）

最常用的入口，内部自动协调 `MemoryCache` 与 `DiskCache`：

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

### 仅用 `MemoryCache`

泛型版本，`Key: Hashable & Sendable`，`Value: Sendable`：

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

### 仅用 `DiskCache`

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

### 自定义归档 / 文件名

对于不符合 `NSCoding` 的类型，可以用自定义的归档闭包：

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

## 🏗️ 架构

```
┌──────────────────────────────────────┐
│              Cache                   │   顶层门面：内存 + 磁盘协同
├────────────────┬─────────────────────┤
│  MemoryCache   │     DiskCache       │
│  （LRU 链表）  │  （归档 / LRU 淘汰）│
│                ├─────────────────────┤
│                │      KVStorage      │   SQLite + 文件系统的底层存储
└────────────────┴─────────────────────┘
```

| 类型 | 职责 |
| --- | --- |
| `Cache` | 顶层 API，读写时优先查内存、未命中则回退磁盘并回填内存 |
| `MemoryCache<Key, Value>` | 基于双向链表 + 哈希表实现的线程安全 LRU 内存缓存，支持 count / cost / age 三种淘汰策略 |
| `DiskCache` | 基于 `KVStorage` 的磁盘缓存，提供归档、LRU 淘汰、空闲空间控制 |
| `KVStorage` | 底层键值存储，根据 `KVStorageType`（`.sqlite` / `.file` / `.mixed`）决定 value 的存放位置 |
| `NSCodingBox` | `any NSCoding` 的 `Sendable` 包装盒，用于在 Swift 6 并发模型中安全传递 |

`KVStorage` 生成的磁盘目录结构：

```
/path/
  ├── manifest.sqlite          # 元信息 & 小数据
  ├── manifest.sqlite-shm
  ├── manifest.sqlite-wal
  ├── data/                    # 大数据独立文件
  │   └── e10adc3949ba59abbe56e057f20f883e
  └── trash/                   # 清理操作的回收站（后台异步清空）
```

---

## ⚙️ 常用配置

### MemoryCache

| 属性 | 说明 | 默认值 |
| --- | --- | --- |
| `countLimit` | 最大对象数量 | `Int.max` |
| `costLimit` | 最大总 cost（字节） | `Int.max` |
| `ageLimit` | 对象最长存活时间（秒） | `.greatestFiniteMagnitude` |
| `autoTrimInterval` | 自动修剪间隔 | `5.0` 秒 |
| `shouldRemoveAllObjectsOnMemoryWarning` | 收到内存警告时清空 | `true` |
| `shouldRemoveAllObjectsWhenEnteringBackground` | 进入后台时清空 | `true` |

### DiskCache

| 属性 | 说明 | 默认值 |
| --- | --- | --- |
| `inlineThreshold` | 大于此字节数的 value 存成独立文件，否则存入 SQLite | `20480`（20KB） |
| `countLimit` | 最大对象数量 | `UInt.max` |
| `costLimit` | 最大总字节数 | `UInt.max` |
| `ageLimit` | 对象最长存活时间（秒） | `.greatestFiniteMagnitude` |
| `freeDiskSpaceLimit` | 磁盘最低保留空闲字节数，低于此值时会触发淘汰 | `0` |
| `autoTrimInterval` | 自动修剪间隔 | `60` 秒 |

---

## 🧵 并发模型

- `MemoryCache` 使用 `os_unfair_lock` 保护内部链表
- `DiskCache` 使用 `DispatchSemaphore` 串行化 `KVStorage` 访问
- `KVStorage` 本身**非**线程安全，所有访问都必须在 `DiskCache` 的锁内完成
- 为兼容 `YYCache` 的同步 API 签名，`Cache` / `DiskCache` 采用 `@unchecked Sendable`；源码注释中标注了安全不变量与未来迁移到 `actor` 的演进计划

---

## 🧪 测试

项目使用 [Swift Testing](https://developer.apple.com/documentation/testing) 编写单元测试，覆盖 `MemoryCache`、`DiskCache`、`KVStorage`、`Cache` 四个组件：

```bash
swift test
```

---

## 📋 系统要求

- Swift 6.0+
- iOS 13.0+ / tvOS 13.0+
- Xcode 16.0+

---

## 📝 致谢

本项目是 [ibireme/YYCache](https://github.com/ibireme/YYCache) 的 Swift 移植，感谢原作者 **ibireme** 的卓越工作。

---

## 📄 License

RECache 基于 MIT 协议开源，详见 [LICENSE](LICENSE)。

底层算法、文件结构及 API 设计源自 YYCache（MIT License, © 2015 ibireme）。
