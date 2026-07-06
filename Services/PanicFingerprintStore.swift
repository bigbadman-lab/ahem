import Foundation

final class PanicFingerprintStore {
    private let defaults: UserDefaults
    private let storageKey = "com.getahem.panicFingerprint"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasFingerprint: Bool {
        load() != nil
    }

    func save(_ fingerprint: PanicFingerprint) throws {
        let data = try JSONEncoder().encode(fingerprint)
        defaults.set(data, forKey: storageKey)
    }

    func load() -> PanicFingerprint? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(PanicFingerprint.self, from: data)
    }

    func delete() {
        defaults.removeObject(forKey: storageKey)
    }
}
