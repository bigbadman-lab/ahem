import Foundation

final class PanicFingerprintStore {
    private let defaults: UserDefaults
    private let storageKey = "com.getahem.panicFingerprint"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasStoredData: Bool {
        guard let data = defaults.data(forKey: storageKey), !data.isEmpty else {
            return false
        }
        return true
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
            print("[FingerprintStore] Fingerprint save failure: \(error.localizedDescription)")
            #endif
            throw error
        }
    }

    func load() -> PanicFingerprint? {
        guard let data = defaults.data(forKey: storageKey), !data.isEmpty else {
            #if DEBUG
            print("[FingerprintStore] Fingerprint load failure — no stored data")
            #endif
            return nil
        }

        let fingerprint: PanicFingerprint
        do {
            fingerprint = try JSONDecoder().decode(PanicFingerprint.self, from: data)
        } catch {
            #if DEBUG
            print("[FingerprintStore] Fingerprint load failure — could not decode stored data")
            #endif
            return nil
        }

        guard fingerprint.version >= PanicFingerprint.currentVersion else {
            #if DEBUG
            print(
                "[FingerprintStore] Fingerprint load failure — legacy v\(fingerprint.version) "
                    + "(need v\(PanicFingerprint.currentVersion))"
            )
            #endif
            return nil
        }

        guard fingerprint.isDetectionCompatible else {
            #if DEBUG
            print(
                "[FingerprintStore] Fingerprint load failure — incompatible processing rate "
                    + "\(String(format: "%.0f", fingerprint.processingSampleRate))"
            )
            #endif
            return nil
        }

        guard fingerprint.hasCompleteSpectralProfile else {
            #if DEBUG
            print("[FingerprintStore] Fingerprint load failure — incomplete spectral profile")
            #endif
            return nil
        }

        #if DEBUG
        print(
            "[FingerprintStore] Fingerprint load success — v\(fingerprint.version) "
                + "@ \(String(format: "%.0f", fingerprint.processingSampleRate))Hz "
                + "(consistency: \(String(format: "%.2f", fingerprint.trainingConsistency)))"
        )
        #endif

        return fingerprint
    }

    func lastTrainedDate() -> Date? {
        guard let date = load()?.createdAt else {
            return nil
        }

        #if DEBUG
        print("[FingerprintStore] Last trained metadata found")
        #endif

        return date
    }

    func delete() {
        defaults.removeObject(forKey: storageKey)
    }
}
