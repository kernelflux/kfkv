# KFKV

High-performance key-value storage for iOS — mmap-backed persistence, protobuf encoding, AES encryption.

Forked from [Tencent/MMKV](https://github.com/Tencent/MMKV) v2.4.0, stripped of Android/WatchOS/Extension targets, adapted for the KernelFlux component library.

[中文文档](README_CN.md)

## Features

- **mmap-backed** — direct memory-mapped file I/O, no serialization overhead
- **Protobuf encoding** — compact binary format, backward-compatible schema evolution
- **AES encryption** — OpenSSL-based at-rest encryption per instance
- **CRC integrity** — zlib CRC-32 checksum for data corruption detection
- **Swift subscript API** — `kv["key"] = "value"` with optional default fallback
- **Memory warning resilience** — mmap pages can be reclaimed by the OS without data loss

## Installation

**Swift Package Manager**

```
https://github.com/kernelflux/kfkv.git
```

Or in `Package.swift`:

```swift
.package(url: "https://github.com/kernelflux/kfkv.git", from: "1.0.0")
```

Then add the target you need:

| Product | Description | Depends on |
|---------|-------------|------------|
| `KFKV` | ObjC wrapper | `KFKVCore` |
| `KFKVAPI` | Swift protocol-only (zero deps) | nothing |
| `KFKVSwift` | Swift extensions + KFService integration | `KFKV`, `KFKVAPI`, `KFService` |

## Architecture

```
KFKV
├── KFKVCore/            ← C++ core (mmap, protobuf, AES/OpenSSL, CRC/zlib)
├── KFKV/                ← ObjC wrapper (KFKV.h, KFKV.mm)
├── KFKVAPI/             ← Swift protocol (KVStore)
└── KFKVSwift/           ← KFKVDefault, KFKVHandlerBridge, KFKVModule
```

## Quick Start

### Using KFService (recommended)

```swift
import KFService
import KFKVSwift

// Register module at app launch
KFServiceManager.register(module: KFKVModule(
    rootDir: documentsPath,
    logLevel: .info
))

// Resolve and use
let kv = KFServiceManager.resolve(KVStore.self)
kv["theme"] = "dark"
print(kv["theme"] ?? "light")
```

### Standalone (no KFService)

```swift
import KFKVSwift

// Initialize
let rootDir = KFKV.initialize(rootDir: nil)
guard let kv = KFKV.default() else { return }

// Basic operations
kv["greeting"] = "hello"
print(kv["greeting"] ?? "nil")

// Custom instance with separate file
guard let userKV = KFKV(mmapID: "user_settings") else { return }
userKV["theme"] = "dark"
```

## API Reference

### KVStore Protocol

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

### Swift Convenience (protocol extension)

```swift
// Subscript — read, write, delete
kv["key"] = "value"
let value = kv["key"]
kv["key"] = nil          // removes the key

// Subscript with default
let theme = kv["theme", default: "light"]

// Query
kv.isEmpty               // count == 0
kv.allStringKeys         // allKeys() alias
```

### Custom Log Handler

```swift
let handler = KFKVHandlerBridge(
    onLog: { level, file, line, function, message in
        print("[KFKV \(level)] \(message)")
    }
)
KFKV.initialize(rootDir: nil, logLevel: .info, handler: handler)
```

## KFKVModule

Registers with KFService, handles lifecycle:

```swift
KFKVModule(
    rootDir: documentsPath,
    logLevel: .info,
    priority: 100   // default priority — start early
)
```

## Source Layout

```
Sources/
├── Core/                 ← C++ core (forked from Tencent/MMKV)
│   ├── aes/              ← OpenSSL AES encryption
│   ├── crc32/            ← zlib CRC-32 checksum
│   └── ...               ← mmap, protobuf, CodedOutputData, etc.
├── KFKV/                 ← ObjC wrapper (KFKV.h, KFKV.mm)
├── KFKVAPI/              ← KVStore protocol
└── KFKVSwift/            ← KFKVDefault, KFKVHandlerBridge, KFKVModule
```

## License

[BSD 3-Clause](LICENSE) — Copyright (c) 2018 THL A29 Limited (Tencent), Copyright (c) 2026 KernelFlux

This project is forked from [Tencent/MMKV](https://github.com/Tencent/MMKV) and inherits its BSD 3-Clause license.
