import ShadCore
import Carbon.HIToolbox

/// The entry target selects this value at link time. The bundle plist is only installer metadata.
package enum Edition {
    case suite([FeatureModule])
    case standalone(FeatureModule)

    package var modules: [FeatureModule] {
        switch self {
        case let .suite(modules): return modules
        case let .standalone(module): return [module]
        }
    }

    var standaloneModule: FeatureModule? {
        if case let .standalone(module) = self { return module }
        return nil
    }
    var isSuite: Bool { standaloneModule == nil }
    var id: String { standaloneModule?.id ?? "suite" }
    var title: String { standaloneModule?.appName ?? "Shad Tools" }
    var symbol: String { standaloneModule?.symbol ?? "square.stack.3d.up.fill" }

    var shortcuts: [String: KeyChord] {
        var bindings: [String: KeyChord] = [:]
        for module in modules {
            for (id, chord) in module.commandShortcuts where id.hasPrefix(module.commandPrefix) {
                bindings[id] = chord
            }
        }
        if isSuite { bindings["app.open"] = KeyChord(49, controlKey | optionKey, "Space") }
        else if let launcher = standaloneModule?.launcher { bindings["app.open"] = launcher }
        return bindings
    }
}
