import Foundation

/// Configuration for the KVStore service.
public struct KFKVConfig: Sendable {
    /// Unique mmap file identifier. Default "KFKit".
    public var mmapID: String

    /// Optional AES encryption key. nil means no encryption.
    public var cryptKey: Data?

    public init(mmapID: String = "KFKit", cryptKey: Data? = nil) {
        self.mmapID = mmapID
        self.cryptKey = cryptKey
    }
}
