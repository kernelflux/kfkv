import KFKVAPI
import KFKV
import KFService
@_exported import KFKVAPI

/// KFKV service module — registers the default mmap-backed KVStore with ServiceFactory.
///
///     ServiceFactory.register(KVStore.self) { KFKVDefault(engine: ...) }
public enum KFKVModule {
    /// Initialize KFKV engine and register KVStore service.
    public static func start(
        rootDir: String? = nil,
        logLevel: KFKVLogLevel = .info,
        handler: KFKVHandlerBridge? = nil
    ) {
        let bridge = handler ?? KFKVHandlerBridge.defaultBridge
        ServiceFactory.register(KVStore.self) {
            _ = KFKVEngine.initialize(rootDir: rootDir, logLevel: logLevel, handler: bridge)
            let engine = KFKVEngine.default()
            return KFKVDefault(engine: engine!)
        }
    }
}
