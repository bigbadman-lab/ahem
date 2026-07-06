import Combine
import Foundation

final class UserPreferencesStore: ObservableObject {
    private let defaults: UserDefaults
    private let playConfirmationSoundKey = "com.getahem.playConfirmationSoundAfterTraining"

    @Published var playConfirmationSoundAfterTraining: Bool {
        didSet {
            defaults.set(playConfirmationSoundAfterTraining, forKey: playConfirmationSoundKey)
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if defaults.object(forKey: playConfirmationSoundKey) == nil {
            playConfirmationSoundAfterTraining = true
        } else {
            playConfirmationSoundAfterTraining = defaults.bool(forKey: playConfirmationSoundKey)
        }
    }
}
