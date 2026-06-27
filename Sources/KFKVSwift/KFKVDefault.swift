// Copyright (c) 2026 KernelFlux. All rights reserved.

import Foundation
import KFKVAPI
import KFKV

/// Default KVStore implementation backed by the KFKV mmap engine.
/// Wraps the internal KFKVEngine ObjC class.
public final class KFKVDefault: KVStore {
    private let engine: KFKVEngine

    public var count: Int { Int(engine.count()) }
    public var mmapID: String { engine.mmapID() }

    public init(mmapID: String, cryptKey: Data? = nil) {
        self.engine = KFKVEngine(mmapID: mmapID, cryptKey: cryptKey)!
    }

    public init(engine: KFKVEngine) {
        self.engine = engine
    }

    public func set(_ value: String, forKey key: String) -> Bool {
        engine.set(value, forKey: key)
    }

    public func string(forKey key: String) -> String? {
        engine.string(forKey: key)
    }

    public func removeValue(forKey key: String) {
        engine.removeValue(forKey: key)
    }

    public func clearAll() {
        engine.clearAll()
    }

    public func allKeys() -> [String] {
        (engine.allKeys() as? [String]) ?? []
    }

    public func contains(key: String) -> Bool {
        engine.contains(key: key)
    }

    public func close() {
        engine.close()
    }
}
