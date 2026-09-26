import LilPasswordsKit
import SwiftUI

/// Settings → Security: auto-lock timing and clipboard-clearing timing.
///
/// This tab only edits the stored preference; the actual lock timer (851-2411) and clipboard
/// clearing (851-2423) read `AppSettings` themselves and aren't implemented yet.
struct SecuritySettingsView: View {
  @ObservedObject var settings: ObservableAppSettings

  var body: some View {
    Form {
      Section {
        Picker("Auto-Lock", selection: $settings.autoLockInterval) {
          ForEach(AppSettings.AutoLockInterval.allCases) { interval in
            Text(interval.displayName).tag(interval)
          }
        }
      } footer: {
        Text(
          "\(LilPasswordsKit.productName) locks and requires Touch ID or your password again after this much inactivity."
        )
      }

      Section {
        Picker("Clear Clipboard", selection: $settings.clipboardClearInterval) {
          ForEach(AppSettings.ClipboardClearInterval.allCases) { interval in
            Text(interval.displayName).tag(interval)
          }
        }
      } footer: {
        Text("Copied passwords and verification codes are removed from the clipboard automatically.")
      }
    }
    .formStyle(.grouped)
    .frame(width: SettingsLayout.contentWidth)
    .fixedSize(horizontal: false, vertical: true)
  }
}
