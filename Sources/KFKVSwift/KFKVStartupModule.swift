import KFService
import KFKVAPI

final class KFKVStartupTask: BaseStartupTask {
    override var identifier: String { "com.kernelflux.kv" }
    override var actorRequirement: ActorRequirement { .mainActor }

    private let config: KFKVConfig

    init(config: KFKVConfig) { self.config = config }

    override func run() async throws {
        let store = try ServiceContainer.shared.resolve(KVStore.self)
        store.initialize(config: config)
    }
}

public struct KFKVStartupModule: StartupModule {
    private let config: KFKVConfig
    public var tasks: [any StartupTask] { [KFKVStartupTask(config: config)] }
    public init(config: KFKVConfig) { self.config = config }
}
