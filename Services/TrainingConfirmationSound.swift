import AppKit

enum TrainingConfirmationSound {
    static func play() {
        guard let sound = NSSound(named: NSSound.Name("Tink")) else { return }
        sound.play()
    }
}
