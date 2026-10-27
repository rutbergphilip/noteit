import Foundation

/// The caption under every passphrase field (web-app spec §7): keys come from the passphrase's raw UTF-8 bytes,
/// so a letter with an accent typed differently on another keyboard gives a different key.
enum PassphraseHint {
    static let text = "Type it exactly as on your other devices. Letters with accents can differ between keyboards."
}
