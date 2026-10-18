import Foundation
import Observation

@MainActor
@Observable
final class ProviderStore {
    private(set) var providers: [APIProvider] = []
    @ObservationIgnored private var keyCache: [UUID: String] = [:]
    /// 用于在界面上刷新 Key 的显示
    private(set) var keyVersion = 0

    private let file = "providers.json"

    init() {
        providers = FileStore.load([APIProvider].self, from: file) ?? []
    }

    func provider(_ id: UUID?) -> APIProvider? {
        guard let id else { return nil }
        return providers.first(where: { $0.id == id })
    }

    var enabled: [APIProvider] { providers.filter { $0.isEnabled } }

    func apiKey(for provider: APIProvider) -> String {
        if let k = keyCache[provider.id] { return k }
        let k = Keychain.get(provider.keychainKey) ?? ""
        keyCache[provider.id] = k
        return k
    }

    func setAPIKey(_ key: String, for provider: APIProvider) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set(trimmed, for: provider.keychainKey)
        keyCache[provider.id] = trimmed
        keyVersion += 1
    }

    func maskedKey(for provider: APIProvider) -> String {
        _ = keyVersion
        let k = apiKey(for: provider)
        guard !k.isEmpty else { return "未设置" }
        guard k.count > 10 else { return String(repeating: "•", count: k.count) }
        return String(k.prefix(4)) + "••••" + String(k.suffix(4))
    }

    func add(_ provider: APIProvider) {
        providers.append(provider)
        save()
    }

    func update(_ provider: APIProvider) {
        guard let i = providers.firstIndex(where: { $0.id == provider.id }) else {
            add(provider)
            return
        }
        providers[i] = provider
        save()
    }

    func update(_ id: UUID, _ mutate: (inout APIProvider) -> Void) {
        guard let i = providers.firstIndex(where: { $0.id == id }) else { return }
        mutate(&providers[i])
        save()
    }

    func delete(_ id: UUID) {
        if let p = provider(id) { Keychain.delete(p.keychainKey) }
        providers.removeAll { $0.id == id }
        keyCache[id] = nil
        save()
    }

    func move(from: IndexSet, to: Int) {
        providers.move(fromOffsets: from, toOffset: to)
        save()
    }

    private func save() {
        FileStore.save(providers, to: file)
    }

    /// 解析实际使用的服务商与模型
    func resolve(providerID: UUID?, modelName: String?, settings: AppSettings) -> (APIProvider, ModelConfig)? {
        if let p = provider(providerID), p.isEnabled, let m = p.model(named: modelName) {
            return (p, m)
        }
        if let p = provider(settings.defaultProviderID), p.isEnabled, let m = p.model(named: settings.defaultModelName) {
            return (p, m)
        }
        for p in enabled {
            if let m = p.defaultModel { return (p, m) }
        }
        return nil
    }

    func resolveAux(settings: AppSettings, fallbackProviderID: UUID?, fallbackModel: String?) -> (APIProvider, ModelConfig)? {
        if let p = provider(settings.auxProviderID), p.isEnabled, let m = p.model(named: settings.auxModelName) {
            return (p, m)
        }
        return resolve(providerID: fallbackProviderID, modelName: fallbackModel, settings: settings)
    }
}
