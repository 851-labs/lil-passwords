import LilPasswordsKit
import SwiftUI

/// Settings → Security: auto-lock timing, clipboard-clearing timing, and recovery-key rotation.
///
/// The auto-lock/clipboard sections only edit the stored preference; the actual lock timer
/// (851-2411) and clipboard clearing (851-2423) read `AppSettings` themselves and aren't
/// implemented yet.
struct SecuritySettingsView: View {
  @ObservedObject var settings: ObservableAppSettings

  /// 851-2462: generating a new recovery key needs an `LAContext` authentication prompt and a
  /// couple of AppKit sheets (`RegenerateRecoveryKeyFlow.present(agentClient:over:)`) — neither of
  /// which this SwiftUI view has any business owning itself. `SecuritySettingsViewController`
  /// supplies this closure and drives the actual flow, the same way it owns the `AgentClient`/
  /// `NSWindow` that flow needs.
  var onGenerateNewRecoveryKey: () -> Void

  var body: some View {
    Form {
      Section {
        Picker("Auto-Lock", selection: $settings.autoLockInterval) {
          ForEach(AppSettings.AutoLockInterval.allCases) { interval in
            Text(interval.displayName).tag(interval)
          }
        }
        .pickerStyle(.menu)
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
        .pickerStyle(.menu)
      } footer: {
        Text("Copied passwords and verification codes are removed from the clipboard automatically.")
      }

      Section {
        Button("Generate New Recovery Key…", action: onGenerateNewRecoveryKey)
      } footer: {
        Text(
          "Your current recovery key will stop working immediately, and you'll be shown a new one to save. "
            + "Do this if you ever suspect someone else has seen your existing key."
        )
      }
    }
    .formStyle(.grouped)
    .controlSize(.small)
    .frame(width: SettingsLayout.contentWidth)
    .fixedSize(horizontal: false, vertical: true)
  }
}
