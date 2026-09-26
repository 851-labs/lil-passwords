import LilPasswordsKit
import SwiftUI

/// Settings → Agents: the access toggle and its policy nuance (851-2428), and the access log
/// (851-2429).
struct AgentsSettingsView: View {
  @ObservedObject var settings: ObservableAppSettings
  @StateObject private var logModel = AccessLogViewModel()

  var body: some View {
    Form {
      Section {
        Toggle("Allow agents to access passwords", isOn: $settings.agentAccessEnabled)
          .toggleStyle(.switch)
        Toggle(
          "Keep agent access available while the Mac is unlocked",
          isOn: $settings.keepAgentAccessAvailableWhileMacUnlocked
        )
        .toggleStyle(.switch)
        .disabled(!settings.agentAccessEnabled)
      } footer: {
        VStack(alignment: .leading, spacing: 6) {
          Text(
            "The \(LilPasswordsKit.cliName) CLI and MCP server can read every password with no prompts while "
              + "\(LilPasswordsKit.productName) is unlocked. Turning this off, or locking the vault, blocks access."
          )
          Text("Otherwise, agent access follows \(LilPasswordsKit.productName)'s own auto-lock.")
        }
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
          "Every agent request is recorded here — time, agent, item, and fields accessed, never secret values. "
            + "Entries older than 30 days are removed automatically."
        )
      }
    }
    .formStyle(.grouped)
    .frame(width: SettingsLayout.contentWidth)
    .fixedSize(horizontal: false, vertical: true)
    .task { await logModel.refresh() }
  }
}

/// The access log's table — time, agent (the process chain, e.g. "claude → node → lilpw"), item,
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
