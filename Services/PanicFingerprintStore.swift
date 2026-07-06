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
        guard let fingerprint = try? JSONDecoder().decode(PanicFingerprint.self, from: data) else {
            #if DEBUG
            print("[Training] Stored fingerprint could not be decoded — retraining required")
            #endif
            return nil
        }

        guard fingerprint.isDetectionCompatible else {
            #if DEBUG
            print(
                "[Training] Legacy fingerprint v\(fingerprint.version) is incompatible — retraining required"
            )
            #endif
            return nil
        }

        #if DEBUG
        print(
            "[Detection] Loaded fingerprint v\(fingerprint.version) "
                + "(consistency: \(String(format: "%.2f", fingerprint.trainingConsistency)))"
        )
        #endif

        return fingerprint
    }

    func delete() {
        defaults.removeObject(forKey: storageKey)
    }
}
