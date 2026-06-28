# KFKV

High-performance key-value storage for iOS — mmap-backed persistence, protobuf encoding, AES encryption.

Forked from [Tencent/MMKV](https://github.com/Tencent/MMKV) v2.4.0, stripped of Android/WatchOS/Extension targets, adapted for the KernelFlux component library.

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
| `KFKVSwift` | Swift impl + KFService integration | `KFKV`, `KFKVAPI`, `KFService` |

## Architecture

```
KFKV
├── KFKVCore/            ← C++ core (mmap, protobuf, AES/OpenSSL, CRC/zlib)
├── KFKV/                ← ObjC wrapper (KFKV.h, KFKV.mm)
├── KFKVAPI/             ← Swift protocol (KVStore) + config (KFKVConfig)
└── KFKVSwift/           ← KFKVDefault, KFKVAssembly, KFKVStartupModule
```

## Quick Start

### Using KFService (recommended)

```swift
import KFService
import KFKVSwift

// In App init — register via assembly
ServiceContainer.shared.install(KFKVAssembly())

// In App.task — run startup
try await Engine.run(modules: [
    KFKVStartupModule(config: KFKVConfig(mmapID: "MyApp")),
])
```

Resolve and use anywhere:

```swift
let kv = try ServiceContainer.shared.resolve(KVStore.self)
kv["theme"] = "dark"
print(kv["theme"] ?? "light")
```

Or via property wrapper:

```swift
@Inject(KVStore.self) private var kv
```

### Standalone (no KFService)

```swift
import KFKVSwift

let kv = KFKVDefault()
kv.initialize(config: KFKVConfig(mmapID: "standalone"))
kv["greeting"] = "hello"
```

## API Reference

### KVStore Protocol

```swift
public protocol KVStore: AnyObject {
    func initialize(config: KFKVConfig)
    func set(_ value: String, forKey key: String) -> Bool
    func string(forKey key: String) -> String?
    func removeValue(forKey key: String)
    func clearAll()
    func allKeys() -> [String]
    func contains(key: String) -> Bool
    var count: Int { get }
    func unInit()
}
```

### Swift Convenience (protocol extension)

```swift
/// Subscript — read, write, delete
kv["key"] = "value"
let value = kv["key"]
kv["key"] = nil          // removes the key

/// Subscript with default
let theme = kv["theme", default: "light"]

/// Query
kv.isEmpty               // count == 0
kv.allStringKeys         // allKeys() alias
```

### KFKVConfig

```swift
public struct KFKVConfig {
    public var mmapID: String
    public init(mmapID: String)
}
```

## KFService Integration

| Type | Role |
|------|------|
| `KFKVAssembly` | Implements `ServiceAssembly` — registers `KVStore` → `KFKVDefault` |
| `KFKVStartupModule` | Implements `StartupModule` — provides `KFKVStartupTask` |

```swift
// Install (sync, in App init)
ServiceContainer.shared.install(KFKVAssembly())

// Override with custom impl — last write wins
ServiceContainer.shared.register(KVStore.self) { MyCustomKV() }

// Run (async, in App.task)
try await Engine.run(modules: [
    KFKVStartupModule(config: KFKVConfig(mmapID: "MyApp")),
])
```

## Source Layout

```
Sources/
├── Core/                 ← C++ core (forked from Tencent/MMKV)
│   ├── aes/              ← OpenSSL AES encryption
│   ├── crc32/            ← zlib CRC-32 checksum
│   └── ...               ← mmap, protobuf, CodedOutputData, etc.
├── KFKV/                 ← ObjC wrapper (KFKV.h, KFKV.mm)
├── KFKVAPI/              ← KVStore protocol + KFKVConfig
└── KFKVSwift/            ← KFKVDefault, KFKVAssembly, KFKVStartupModule
```

## License

[BSD 3-Clause](LICENSE) — Copyright (c) 2018 THL A29 Limited (Tencent), Copyright (c) 2026 KernelFlux

This project is forked from [Tencent/MMKV](https://github.com/Tencent/MMKV) and inherits its BSD 3-Clause license.
