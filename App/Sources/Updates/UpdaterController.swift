import AppKit
import Sparkle

/// Sparkle 2, feed + DMG hosted on GitHub Releases (851-2437). See
/// docs/releasing.md for the release pipeline that signs and publishes the
/// appcast, and `generate_keys` for the EdDSA keypair.
///
/// This is a standalone singleton, not something `AppDelegate` owns, so that
/// `MainMenu` can wire "Check for Updates…" straight to
/// `UpdaterController.shared` with a one-line, rebase-friendly addition
/// instead of threading a dependency through the menu-construction code
/// (851-2424 is actively rewriting `MainMenu` in parallel).
@MainActor
final class UpdaterController: NSObject {
  static let shared = UpdaterController()

  /// `nil` when no real Sparkle key has been baked into Info.plist yet
  /// (`SPARKLE_PUBLIC_ED_KEY` in Config/Base.xcconfig is still the empty
  /// placeholder). Sparkle tolerates `SUPublicEDKey` being absent entirely,
  /// but not being present-and-malformed — and an empty string decodes as
  /// the latter, which pops an "update checker failed to start" alert on
  /// every launch. So we simply don't start the updater until a real key
  /// exists; "Check for Updates…" just no-ops until then.
  private let updaterController: SPUStandardUpdaterController?

  /// `automaticallyChecksForUpdates` on the underlying `SPUUpdater`, exposed
  /// for a future Settings opt-out (project description, "an opt-out in
  /// Settings"). `nil` while there's no updater configured. 851-2424 owns the
  /// Settings window; bind a checkbox to this once it exists.
  var automaticallyChecksForUpdates: Bool {
    get { updaterController?.updater.automaticallyChecksForUpdates ?? false }
    set { updaterController?.updater.automaticallyChecksForUpdates = newValue }
  }

  private override init() {
    if let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !publicKey.isEmpty {
      updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
      )
    } else {
      updaterController = nil
    }
    super.init()
  }

  /// Target for the "Check for Updates…" menu item. Matches Sparkle's usual
  /// `SPUStandardUpdaterController.checkForUpdates(_:)` IBAction signature.
  @objc func checkForUpdates(_ sender: Any?) {
    updaterController?.checkForUpdates(sender)
  }
}
