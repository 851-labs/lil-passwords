import AppKit
import LilPasswordsKit

/// Settings → Security: auto-lock timing and clipboard-clearing timing.
///
/// This tab only edits the stored preference; the actual lock timer (851-2411) and clipboard
/// clearing (851-2423) read `AppSettings` themselves and aren't implemented yet.
@MainActor
final class SecuritySettingsViewController: NSViewController {
  private let settings: AppSettings

  private let autoLockPopUp = NSPopUpButton()
  private let clipboardPopUp = NSPopUpButton()

  init(settings: AppSettings = .shared) {
    self.settings = settings
    super.init(nibName: nil, bundle: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) is not supported")
  }

  override func loadView() {
    autoLockPopUp.addItems(withTitles: AppSettings.AutoLockInterval.allCases.map(\.displayName))
    autoLockPopUp.target = self
    autoLockPopUp.action = #selector(autoLockChanged(_:))

    clipboardPopUp.addItems(withTitles: AppSettings.ClipboardClearInterval.allCases.map(\.displayName))
    clipboardPopUp.target = self
    clipboardPopUp.action = #selector(clipboardChanged(_:))

    let autoLockRow = NSStackView(views: [SettingsLayout.rowLabel("Auto-Lock:"), autoLockPopUp])
    autoLockRow.orientation = .horizontal
    autoLockRow.spacing = 8
    autoLockRow.alignment = .firstBaseline

    let clipboardRow = NSStackView(views: [SettingsLayout.rowLabel("Clear Clipboard:"), clipboardPopUp])
    clipboardRow.orientation = .horizontal
    clipboardRow.spacing = 8
    clipboardRow.alignment = .firstBaseline

    view = SettingsLayout.makeStack([
      SettingsLayout.sectionHeader("Auto-Lock"),
      autoLockRow,
      SettingsLayout.caption(
        "Lil Passwords locks and requires Touch ID or your password again after this much inactivity."),
      SettingsLayout.sectionHeader("Clipboard"),
      clipboardRow,
      SettingsLayout.caption("Copied passwords and verification codes are removed from the clipboard automatically."),
    ])
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    preferredContentSize = SettingsLayout.preferredSize(for: view)
    loadFromSettings()
  }

  private func loadFromSettings() {
    let allAutoLock = AppSettings.AutoLockInterval.allCases
    if let index = allAutoLock.firstIndex(of: settings.autoLockInterval) {
      autoLockPopUp.selectItem(at: index)
    }

    let allClipboard = AppSettings.ClipboardClearInterval.allCases
    if let index = allClipboard.firstIndex(of: settings.clipboardClearInterval) {
      clipboardPopUp.selectItem(at: index)
    }
  }

  @objc private func autoLockChanged(_ sender: NSPopUpButton) {
    let options = AppSettings.AutoLockInterval.allCases
    guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < options.count else { return }
    settings.autoLockInterval = options[sender.indexOfSelectedItem]
  }

  @objc private func clipboardChanged(_ sender: NSPopUpButton) {
    let options = AppSettings.ClipboardClearInterval.allCases
    guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < options.count else { return }
    settings.clipboardClearInterval = options[sender.indexOfSelectedItem]
  }
}
