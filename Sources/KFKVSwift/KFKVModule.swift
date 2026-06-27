import KFKVAPI
import KFKV
import KFService
@_exported import KFKVAPI

/// KFKV service module — registers the default mmap-backed KVStore with ServiceFactory.
///
///     ServiceFactory.register(module: KFKVModule(handler: ...))
///     ServiceFactory.resolve(KVStore.self).string(forKey: "token")
public struct KFKVModule: KFModule {
    private let handler: KFKVHandlerBridge
    private let rootDir: String?
    private let logLevel: KFKVLogLevel

    public init(
        rootDir: String? = nil,
        logLevel: KFKVLogLevel = .info,
        handler: KFKVHandlerBridge? = nil
    ) {
        self.rootDir = rootDir
        self.logLevel = logLevel
        self.handler = handler ?? KFKVHandlerBridge.defaultBridge
    }

    public func register() {
        ServiceFactory.register(KVStore.self) {
            _ = KFKVEngine.initialize(rootDir: rootDir, logLevel: logLevel, handler: handler)
            let engine = KFKVEngine.default()
            return KFKVDefault(engine: engine!)
        }
    }
}
