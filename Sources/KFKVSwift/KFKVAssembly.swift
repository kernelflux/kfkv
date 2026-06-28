import KFService
import KFKVAPI

public struct KFKVAssembly: ServiceAssembly {
    public init() {}
    public func assemble(container: ServiceContainer) {
        container.register(KVStore.self) { KFKVDefault() }
    }
}
