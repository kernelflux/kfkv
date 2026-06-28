// Copyright (c) 2026 KernelFlux. All rights reserved.

import Foundation
import KFKVAPI
import KFKV

/// Default KVStore implementation backed by the KFKV mmap engine.
/// Wraps the internal KFKVEngine ObjC class.
public final class KFKVDefault: KVStore {
    private var engine: KFKVEngine?

    public var count: Int { Int(engine?.count() ?? 0) }
    public var mmapID: String { engine?.mmapID() ?? "" }

    public init() {}

    public func initialize(config: KFKVConfig) {
        unInit()
        // Global ObjC class-level init — must be called once on main thread before creating instances.
        _ = KFKVEngine.initialize(rootDir: nil)
        engine = KFKVEngine(mmapID: config.mmapID, cryptKey: config.cryptKey)!
    }

    public func set(_ value: String, forKey key: String) -> Bool {
        engine?.set(value, forKey: key) ?? false
    }

    public func string(forKey key: String) -> String? {
        engine?.string(forKey: key)
    }

    public func removeValue(forKey key: String) {
        engine?.removeValue(forKey: key)
    }

    public func clearAll() {
        engine?.clearAll()
    }

    public func allKeys() -> [String] {
        (engine?.allKeys() as? [String]) ?? []
    }

    public func contains(key: String) -> Bool {
        engine?.contains(key: key) ?? false
    }

    public func unInit() {
        engine?.close()
        engine = nil
    }
}
