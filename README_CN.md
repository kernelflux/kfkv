# KFKV

高性能 iOS 键值存储组件 —— mmap 持久化、protobuf 编码、AES 加密。

Fork 自 [Tencent/MMKV](https://github.com/Tencent/MMKV) v2.4.0，剥离 Android/WatchOS/Extension 目标，适配 KernelFlux 组件库。

[English](README.md)

## 特性

- **mmap 底层** — 直接内存映射文件 I/O，无序列化开销
- **Protobuf 编码** — 紧凑二进制格式，向后兼容的 schema 演化
- **AES 加密** — 基于 OpenSSL 的单实例静态加密
- **CRC 完整性校验** — zlib CRC-32 校验和，检测数据损坏
- **Swift 下标语法** — `kv["key"] = "value"`，支持可选默认值
- **内存告警韧性** — mmap 页可被 OS 回收而不丢失数据

## 安装

**Swift Package Manager**

```
https://github.com/kernelflux/kfkv.git
```

或在 `Package.swift` 中：

```swift
.package(url: "https://github.com/kernelflux/kfkv.git", from: "1.0.0")
```

按需添加 target：

| Product | 说明 | 依赖 |
|---------|------|------|
| `KFKV` | ObjC 封装 | `KFKVCore` |
| `KFKVAPI` | Swift 纯协议（零依赖） | 无 |
| `KFKVSwift` | Swift 扩展 + KFService 集成 | `KFKV`、`KFKVAPI`、`KFService` |

## 架构

```
KFKV
├── KFKVCore/            ← C++ 核心（mmap、protobuf、AES/OpenSSL、CRC/zlib）
├── KFKV/                ← ObjC 封装（KFKV.h, KFKV.mm）
├── KFKVAPI/             ← Swift 协议（KVStore）
└── KFKVSwift/           ← KFKVDefault、KFKVHandlerBridge、KFKVModule
```

## 快速开始

### 配合 KFService 使用（推荐）

```swift
import KFService
import KFKVSwift

// App 启动时注册模块
KFServiceManager.register(module: KFKVModule(
    rootDir: documentsPath,
    logLevel: .info
))

// 获取实例并使用
let kv = KFServiceManager.resolve(KVStore.self)
kv["theme"] = "dark"
print(kv["theme"] ?? "light")
```

### 独立使用（无需 KFService）

```swift
import KFKVSwift

// 初始化
let rootDir = KFKV.initialize(rootDir: nil)
guard let kv = KFKV.default() else { return }

// 基本操作
kv["greeting"] = "hello"
print(kv["greeting"] ?? "nil")

// 独立实例，独立文件
guard let userKV = KFKV(mmapID: "user_settings") else { return }
userKV["theme"] = "dark"
```

## API 参考

### KVStore 协议

```swift
@objc public protocol KVStore: AnyObject {
    func set(_ value: String, forKey key: String) -> Bool
    func string(forKey key: String) -> String?
    func removeValue(forKey key: String)
    func clearAll()
    func allKeys() -> [String]
    func contains(key: String) -> Bool
    var count: Int { get }
    func close()
}
```

### Swift 便捷方法（协议扩展）

```swift
// 下标 —— 读、写、删除
kv["key"] = "value"
let value = kv["key"]
kv["key"] = nil          // 删除 key

// 带默认值的下标
let theme = kv["theme", default: "light"]

// 查询
kv.isEmpty               // count == 0
kv.allStringKeys         // allKeys() 别名
```

### 自定义日志处理器

```swift
let handler = KFKVHandlerBridge(
    onLog: { level, file, line, function, message in
        print("[KFKV \(level)] \(message)")
    }
)
KFKV.initialize(rootDir: nil, logLevel: .info, handler: handler)
```

## KFKVModule

注册到 KFService，处理生命周期：

```swift
KFKVModule(
    rootDir: documentsPath,
    logLevel: .info,
    priority: 100   // 默认优先级 —— 较早启动
)
```

## 源文件结构

```
Sources/
├── Core/                 ← C++ 核心（fork 自 Tencent/MMKV）
│   ├── aes/              ← OpenSSL AES 加密
│   ├── crc32/            ← zlib CRC-32 校验
│   └── ...               ← mmap、protobuf、CodedOutputData 等
├── KFKV/                 ← ObjC 封装（KFKV.h, KFKV.mm）
├── KFKVAPI/              ← KVStore 协议
└── KFKVSwift/            ← KFKVDefault、KFKVHandlerBridge、KFKVModule
```

## 许可证

[BSD 3-Clause](LICENSE) — Copyright (c) 2018 THL A29 Limited (Tencent)，Copyright (c) 2026 KernelFlux

本项目 fork 自 [Tencent/MMKV](https://github.com/Tencent/MMKV)，继承其 BSD 3-Clause 许可证。
