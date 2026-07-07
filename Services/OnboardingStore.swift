import Foundation

final class OnboardingStore {
    static let completionKey = "ahem.hasCompletedOnboarding"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var hasCompletedOnboarding: Bool {
        defaults.bool(forKey: Self.completionKey)
    }

    func markCompleted() {
        defaults.set(true, forKey: Self.completionKey)
    }
}
