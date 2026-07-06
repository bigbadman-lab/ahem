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
        do {
            let data = try JSONEncoder().encode(fingerprint)
            defaults.set(data, forKey: storageKey)
        } catch {
            #if DEBUG
            print("[Training] Failed to save fingerprint: \(error.localizedDescription)")
            #endif
            throw error
        }
    }

    func load() -> PanicFingerprint? {
        guard let data = defaults.data(forKey: storageKey), !data.isEmpty else {
            return nil
        }

        let fingerprint: PanicFingerprint
        do {
            fingerprint = try JSONDecoder().decode(PanicFingerprint.self, from: data)
        } catch {
            #if DEBUG
            print("[Detection] Stored fingerprint could not be decoded — retraining required")
            #endif
            return nil
        }

        guard fingerprint.version >= PanicFingerprint.currentVersion else {
            #if DEBUG
            print(
                "[Detection] Legacy fingerprint v\(fingerprint.version) is incompatible — retraining required"
            )
            #endif
            return nil
        }

        guard fingerprint.isDetectionCompatible else {
            #if DEBUG
            print("[Detection] Stored fingerprint is incomplete — retraining required")
            #endif
            return nil
        }

        guard fingerprint.hasCompleteSpectralProfile else {
            #if DEBUG
            print("[Detection] Stored fingerprint is incomplete — retraining required")
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
