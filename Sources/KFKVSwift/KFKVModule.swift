import KFKVAPI
import KFKV
import KFService

/// KFKV module — implements ModuleProtocol for DAG startup.
///
///     try await Engine.run(graph: graph)
///     ServiceFactory.resolve(KVStore.self).string(forKey: "token")
public final class KFKVModule: ModuleProtocol {
    public static var dependencies: [ModuleID] { [] }

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

    public func performInit() async {
        ServiceFactory.register(KVStore.self) {
            _ = KFKVEngine.initialize(rootDir: self.rootDir, logLevel: self.logLevel, handler: self.handler)
            let engine = KFKVEngine.default()
            return KFKVDefault(engine: engine!)
        }
    }
}
