import KFKVAPI
import KFKV
import KFService

/// KFKV module — provides DAG startup hook after registration.
///
/// Host registers KVStore in init():
///     ServiceFactory.register(KVStore.self) { KFKVDefault(engine: KFKVEngine.default()!) }
///
/// Engine calls performInit() for async startup.
public final class KFKVModule: ModuleProtocol {
    public static var dependencies: [ModuleID] { [] }
    public init() {}

    /// Async startup after registration — preload data etc.
    public func performInit() async {
        // No registration needed — KVStore was registered by host.
        // Add any async warmup here.
    }
}
