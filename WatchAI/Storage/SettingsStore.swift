import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            FileStore.save(settings, to: file)
        }
    }

    var personas: [Persona] {
        didSet { FileStore.save(personas, to: personasFile) }
    }

    private let file = "settings.json"
    private let personasFile = "personas.json"

    init() {
        settings = FileStore.load(AppSettings.self, from: file) ?? AppSettings()
        personas = FileStore.load([Persona].self, from: personasFile) ?? Persona.defaults
    }

    func persona(_ id: UUID?) -> Persona? {
        guard let id else { return nil }
        return personas.first(where: { $0.id == id })
    }

    func reset() {
        settings = AppSettings()
    }
}
