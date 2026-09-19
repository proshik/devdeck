import Foundation

struct EngineChoice {
    let engine: any ContainerEngine
    let running: Bool
}

/// Which engine DevDeck watches. `candidates` come in priority order — colima first: on the
/// developer's machine it is the main one, and a tie is settled by the setting, not by guessing.
enum EngineSelector {
    static func select(_ preference: EnginePreference, from candidates: [any ContainerEngine]) -> EngineChoice? {
        if let wanted = preference.kind {
            // An explicit choice is final, installed or not — then it simply isn't running.
            guard let engine = candidates.first(where: { $0.kind == wanted }) else { return nil }
            return EngineChoice(engine: engine, running: engine.isRunning())
        }
        if let engine = candidates.first(where: { $0.isRunning() }) {
            return EngineChoice(engine: engine, running: true)
        }
        if let engine = candidates.first(where: { $0.isInstalled() }) {
            return EngineChoice(engine: engine, running: false)
        }
        return nil
    }
}