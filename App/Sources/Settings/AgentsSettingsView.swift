import LilPasswordsKit
import SwiftUI

/// Settings → Agents: the access toggle and its policy nuance (851-2428), and the access log
/// (851-2429).
///
/// The two toggles bind to `AgentSettingsViewModel`, not `ObservableAppSettings` — see that view
/// model's documentation for why the 851-2428 settings are read and written through `AgentClient`
/// rather than `AppSettings`/`UserDefaults`.
struct AgentsSettingsView: View {
  @StateObject private var agentSettings: AgentSettingsViewModel
  @StateObject private var logModel = AccessLogViewModel()
  @StateObject private var cliInstall = CLIInstallViewModel()
  @StateObject private var connections = AgentConnectionsViewModel()

  init(client: AgentClient) {
    _agentSettings = StateObject(wrappedValue: AgentSettingsViewModel(client: client))
  }

  var body: some View {
    Form {
      Section {
        Toggle("Allow agents to access passwords", isOn: $agentSettings.agentAccessEnabled)
          .toggleStyle(.switch)
        Toggle(
          "Keep agent access available while the Mac is unlocked",
          isOn: $agentSettings.keepAgentAccessAvailableWhileMacUnlocked
        )
        .toggleStyle(.switch)
        .disabled(!agentSettings.agentAccessEnabled)
        Toggle(
          "Allow agents to create, edit, and delete passwords",
          isOn: $agentSettings.agentWriteAccessEnabled
        )
        .toggleStyle(.switch)
        .disabled(!agentSettings.agentAccessEnabled)
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          // Plain `"a" + "b"` type-infers to a `String`, not `LocalizedStringKey` — `Text(_:)` only
          // auto-localizes via the String Catalog when it receives one literal. Each half is
          // wrapped in `String(localized:)` individually so the whole sentence still gets
          // extracted (851-2466).
          Text(
            String(
              localized:
                "The \(LilPasswordsKit.cliName) CLI and MCP server can read every password with no prompts while "
            )
              + String(
                localized:
                  "\(LilPasswordsKit.productName) is unlocked. Turning this off, or locking the vault, blocks access."
              )
          )
          Text("Otherwise, agent access follows \(LilPasswordsKit.productName)' own auto-lock.")
          Text(
            String(
              localized:
                "Write access is separate from read access and off by default — turn it on only if you want agents "
            )
              + String(localized: "to be able to add, change, or delete passwords, not just read them.")
          )
        }
      }

      Section {
        CLIInstallSectionBody(viewModel: cliInstall)
      } header: {
        Text("Command Line Tool")
      } footer: {
        Text(cliInstallFooterText)
      }

      Section {
        ForEach(AgentConnectionsViewModel.Agent.allCases) { agent in
          AgentConnectionRow(agent: agent, viewModel: connections)
        }
      } header: {
        Text("Connect Agents")
      } footer: {
        Text(
          String(
            localized:
              "Sets up \(LilPasswordsKit.cliName)'s MCP server so the agent can use \(LilPasswordsKit.productName) "
          )
            + String(localized: "directly, subject to the access setting above.")
        )
      }

      Section {
        AccessLogTable(entries: logModel.entries)
        TextField("Filter", text: $logModel.filterText)
        HStack {
          Spacer()
          Button("Clear Log") {
            Task { await logModel.clear() }
          }
          .disabled(logModel.entries.isEmpty)
        }
      } header: {
        Text("Access Log")
      } footer: {
        Text(
          String(
            localized:
              "Every agent request is recorded here — time, agent, item, and fields accessed, never secret values. "
          )
            + String(localized: "Entries older than 30 days are removed automatically.")
        )
      }
    }
    .formStyle(.grouped)
    .controlSize(.small)
    .frame(width: SettingsLayout.contentWidth)
    .fixedSize(horizontal: false, vertical: true)
    .task { await logModel.refresh() }
    .task { await agentSettings.refresh() }
    .task { cliInstall.refresh() }
    .task { connections.refresh() }
  }

  /// `~/.local/bin` (the fallback location — see `CLIInstaller`'s documentation) isn't guaranteed
  /// to be on every shell's `PATH` out of the box, unlike `/usr/local/bin`, so the footer calls that
  /// out only when it's actually relevant.
  ///
  /// Returned as `String`, not `LocalizedStringKey` — this feeds `Text(_:)` below via the verbatim
  /// `Text(String)` initializer, which does *not* auto-localize, unlike `Text("literal")`'s
  /// `LocalizedStringKey` initializer. Each branch is wrapped in `String(localized:)` individually
  /// so it still gets extracted into the catalog.
  private var cliInstallFooterText: String {
    switch cliInstall.status {
    case .notInstalled:
      return String(
        localized: "Installs a \"\(LilPasswordsKit.cliName)\" command so agents (and you) can use it from a terminal."
      )
    case .installed(let path) where path.hasPrefix(NSHomeDirectory() + "/.local/bin"):
      return String(
        localized: "Installed to \(path). If your terminal can't find it, add ~/.local/bin to your shell's PATH."
      )
    case .installed(let path):
      return String(localized: "Installed to \(path).")
    case .pointsElsewhere(let path, let target):
      return String(
        localized: "Something else is already at \(path) (pointing to \(target)). Installing will replace it.")
    }
  }
}

/// The "Command Line Tool" section's contents: current status plus an Install or Uninstall button,
/// wired to `CLIInstallViewModel`/`CLIInstaller` (851-2432).
private struct CLIInstallSectionBody: View {
  @ObservedObject var viewModel: CLIInstallViewModel

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(statusText)
        if let lastErrorMessage = viewModel.lastErrorMessage {
          Text(lastErrorMessage)
            .foregroundStyle(.red)
        }
      }
      // 851-2466: combines the status/error lines into a single VoiceOver element (e.g. "Not
      // installed") instead of two separate stops — mirrors the row-description principle in
      // docs/accessibility.md. Doesn't touch the Install/Uninstall button below, which stays its
      // own focusable element.
      .accessibilityElement(children: .combine)
      Spacer()
      switch viewModel.status {
      case .notInstalled:
        Button("Install \"\(LilPasswordsKit.cliName)\" Command") { viewModel.install() }
      case .installed:
        Button("Uninstall") { viewModel.uninstall() }
      case .pointsElsewhere:
        Button("Install \"\(LilPasswordsKit.cliName)\" Command") { viewModel.install() }
      }
    }
  }

  // Returned as `String`, not `LocalizedStringKey` — see `cliInstallFooterText`'s doc comment
  // above for why each branch needs its own `String(localized:)` wrap.
  private var statusText: String {
    switch viewModel.status {
    case .notInstalled:
      return String(localized: "Not installed")
    case .installed(let path):
      return String(localized: "Installed at \(path)")
    case .pointsElsewhere(let path, let target):
      return String(localized: "A different program is at \(path) (\(target))")
    }
  }
}

/// One row in the "Connect Agents" section (851-2432) — a single agent's name, its current MCP
/// connection status, and the "Copy Setup"/"Add Automatically" actions.
private struct AgentConnectionRow: View {
  let agent: AgentConnectionsViewModel.Agent
  @ObservedObject var viewModel: AgentConnectionsViewModel

  var body: some View {
    HStack {
      VStack(alignment: .leading, spacing: 2) {
        Text(agent.displayName)
        Text(statusText)
          .font(.callout)
          .foregroundStyle(.secondary)
      }
      // 851-2466: combines name + connection status into one VoiceOver element (e.g. "Claude
      // Code, Connected") instead of two separate stops — mirrors the row-description principle
      // in docs/accessibility.md. Doesn't touch the buttons below, which stay their own focusable
      // elements.
      .accessibilityElement(children: .combine)
      Spacer()
      Button("Copy Setup") {
        Pasteboard.copyText(viewModel.snippet(for: agent))
      }
      if viewModel.canAddAutomatically(for: agent) {
        Button("Add Automatically") {
          Task { await viewModel.addAutomatically(for: agent) }
        }
        .disabled(viewModel.isAddingAutomatically(agent))
      }
    }
  }

  // Returned as `String`, not `LocalizedStringKey` — see `AgentsSettingsView.cliInstallFooterText`'s
  // doc comment for why each branch needs its own `String(localized:)` wrap.
  private var statusText: String {
    switch viewModel.status(for: agent) {
    case .notConfigured: return String(localized: "Not connected")
    case .configured: return String(localized: "Connected")
    case .configuredDifferently: return String(localized: "Configured differently")
    }
  }
}

/// The access log's table — time, agent (the process chain, e.g. "claude → node → lilpass"), item,
/// and fields accessed. A plain SwiftUI `Table` rather than a bridged `NSTableView`: it's available
/// on this project's macOS 13 deployment target and needs none of `NSTableView`'s
/// delegate/data-source boilerplate the old placeholder implementation had.
private struct AccessLogTable: View {
  let entries: [AccessLogEntry]

  var body: some View {
    if entries.isEmpty {
      Text("No agent activity yet.")
        .font(.callout)
        .foregroundStyle(.tertiary)
        .frame(maxWidth: .infinity, minHeight: 100)
    } else {
      Table(entries) {
        TableColumn("Time") { entry in
          Text(entry.date, style: .time)
        }
        .width(min: 56, ideal: 64)

        TableColumn("Agent") { entry in
          Text(entry.callerDescription)
            .lineLimit(1)
            .truncationMode(.head)
        }
        .width(min: 90, ideal: 130)

        TableColumn("Item") { entry in
          Text(entry.itemDescription)
            .lineLimit(1)
        }
        .width(min: 70, ideal: 110)

        TableColumn("Fields") { entry in
          Text(entry.fields.joined(separator: ", "))
            .lineLimit(1)
            .truncationMode(.tail)
        }
      }
      .frame(minHeight: 160, maxHeight: 220)
    }
  }
}
