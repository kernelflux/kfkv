// Copyright (c) 2026 KernelFlux. All rights reserved.

import Foundation

/// Abstract key-value store protocol.
/// Implement this to provide custom storage backends (plist, UserDefaults, in-memory, etc.).
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

// MARK: - Convenience

public extension KVStore {
    var allStringKeys: [String] { allKeys() }
    var isEmpty: Bool { count == 0 }

    subscript(key: String) -> String? {
        get { string(forKey: key) }
        set {
            if let value = newValue {
                _ = set(value, forKey: key)
            } else {
                removeValue(forKey: key)
            }
        }
    }

    subscript(key: String, default default: String) -> String {
        string(forKey: key) ?? `default`
    }
}
