#if DEBUG
  import AppKit
  import LilPasswordsKit
  import LilpassCore

  /// Headless tophat capture for 851-2445 (Settings → Agents' three access modes, the Touch ID
  /// approval dialog, the per-item allowlist toggle, and a `lilpass` transcript demonstrating a
  /// denied/timed-out request and allowlist filtering), driven by `LIL_PASSWORDS_TOPHAT_DIR` the
  /// same way every other feature's `*DebugMenu.runTophatCapture` is (see `AppDelegate`).
  ///
  /// Everything here runs against a throwaway, **in-memory** `InMemoryVaultStore` +
  /// `InMemoryAgentSettingsStore`, reached over two real (if in-process) XPC connections — never
  /// the real, on-disk, launchd-activated `LilPasswordsAgent` every concurrently-running worktree on
  /// this machine otherwise shares. See docs/tophat.md's "shared machine hazard" section for why
  /// that matters, and `OfflineDemoAgent` for the app's own precedent of solving the same problem
  /// for its lock/unlock screenshots.
  ///
  /// **Why in-process rather than a genuinely separate `lilpass` process, despite the original brief
  /// asking for "via lilpass":** a named Mach service can't be self-hosted by an ordinary process
  /// without a launchd plist reserving that name first — confirmed empirically while designing this
  /// capture (`bootstrap_check_in` for an unreserved name fails with "No such process" even from an
  /// unsandboxed process). The real name (`AgentXPC.machServiceName`) is already claimed by the real,
  /// running helper, and installing a real (if temporary) LaunchAgent on this shared dev machine just
  /// to reserve a throwaway name would reintroduce the exact shared-machine hazard this capture
  /// exists to avoid. Calling `LilpassCommands` directly — the same argument-parser-free logic
  /// `GetCommand.run()` itself calls, including the real `LilpassError.from(_:)` exit-code mapping —
  /// against an in-process `AgentClient` is the closest achievable substitute: real production logic,
  /// just not a forked OS process. See this file's `README.md` companion, written alongside the other
  /// artifacts, for the same explanation in the tophat output itself.
  @MainActor
  enum AgentTophatDebugMenu {
    static func runTophatCapture(outputDirectory: URL) {
      try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

      // `applicationDidFinishLaunching`'s tophat block (see `AppDelegate`) is synchronous, and
      // `RecoveryKitDebugMenu.runTophatCapture` — which must run *after* this one — calls `exit(0)`
      // at its end, so this function can't return until every capture below has actually finished.
      // Bridged the same way `AppDelegate.applicationWillTerminate` bridges a synchronous callback
      // to async work, except with `RunLoop.current.run(until:)` instead of a `DispatchSemaphore`:
      // a semaphore would block the main thread outright, starving the `@MainActor` task below of
      // the very thread its executor needs to make progress. Repeatedly running the run loop for
      // short intervals keeps pumping the main dispatch queue (and therefore the `@MainActor` task)
      // while still blocking this function's caller until `finished` flips — the same technique the
      // capture helpers below already use to let a freshly-presented sheet actually render before
      // `screencapture` runs.
      var finished = false
      Task { @MainActor in
        await performCapture(outputDirectory: outputDirectory)
        finished = true
      }
      while !finished {
        RunLoop.current.run(until: Date().addingTimeInterval(0.02))
      }
    }

    private static func performCapture(outputDirectory: URL) async {
      let harness: TophatAgentHarness
      do {
        harness = try await TophatAgentHarness()
      } catch {
        NSLog("[AgentTophatDebugMenu] failed to set up in-memory harness, skipping capture: \(error)")
        return
      }
      defer { harness.invalidate() }

      await captureSettingsScreenshots(harness: harness, outputDirectory: outputDirectory)
      captureApprovalDialogScreenshot(outputDirectory: outputDirectory)
      await captureAllowlistToggleTranscript(harness: harness, outputDirectory: outputDirectory)
      await captureCLITranscript(harness: harness, outputDirectory: outputDirectory)
      writeReadme(to: outputDirectory)
    }

    // MARK: - Settings → Agents (three access modes)

    private static func captureSettingsScreenshots(harness: TophatAgentHarness, outputDirectory: URL) async {
      let scenarios: [(AgentSettings, String)] = [
        (
          AgentSettings(
            agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: true, accessScope: .allPasswords
          ),
          "agent-settings-all-passwords.png"
        ),
        (
          AgentSettings(
            agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: true, accessScope: .selected,
            allowedItemIDs: [harness.githubItemID]
          ),
          "agent-settings-only-selected.png"
        ),
        (
          AgentSettings(
            agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: true, accessScope: .askEveryTime
          ),
          "agent-settings-ask-every-time.png"
        ),
      ]

      for (settings, filename) in scenarios {
        do {
          _ = try await harness.appClient.setAgentSettings(settings)
        } catch {
          NSLog("[AgentTophatDebugMenu] failed to push settings for \(filename): \(error)")
          continue
        }
        // `initialSettings: settings` bakes this scenario into the very first SwiftUI render —
        // see `AgentSettingsViewModel.init(client:initialSettings:)` — rather than relying on
        // `.task { await agentSettings.refresh() }` to complete before `captureWindow` runs. That
        // async refresh is real and does eventually apply the same settings, but empirically takes
        // several seconds to resume inside this capture flow's deeply-nested manual `RunLoop`
        // pumping, and no fixed wait tried (0.4s, 1.5s, 5s) reliably outlasted it — every capture
        // came back showing the view's untouched `false`/`.allPasswords` defaults regardless, since
        // that first frame renders before the refresh (whenever it lands) ever changes anything.
        let controller = AgentsSettingsViewController(client: harness.appClient, initialSettings: settings)
        captureAsStandaloneWindow(controller, filename: filename, in: outputDirectory)
      }
    }

    /// Presents `contentViewController` as its own top-level window — not a sheet — matching how
    /// `SettingsWindowController` actually shows `AgentsSettingsViewController` in the real app
    /// (Settings is never presented as a sheet over another window).
    ///
    /// This distinction isn't cosmetic: `AgentsSettingsViewController` is an `NSHostingController`
    /// with `sizingOptions = [.intrinsicContentSize]`, which (per `SettingsTabViewController
    /// .resizeToFitContent(of:)`'s own doc comment) only actually tracks its SwiftUI content's real
    /// size when the hosting controller is set *directly* as a window's `contentViewController` —
    /// which this does, matching that precedent — and even then only after a forced layout pass
    /// (`layoutSubtreeIfNeeded()`), which `ImportExportDebugMenu`'s `captureAsSheet` convention never
    /// needs to perform, since its plain `NSViewController`s already have an Auto-Layout-computed
    /// size before any display pass. Skipping that step here first produced a zero-sized sheet window
    /// that `beginSheet` silently attached nothing for, capturing the parent's own blank backdrop
    /// instead.
    private static func captureAsStandaloneWindow(
      _ contentViewController: NSViewController, filename: String, in directory: URL
    ) {
      let window = NSWindow(contentViewController: contentViewController)
      window.title = LilPasswordsKit.productName
      window.styleMask = [.titled, .closable, .miniaturizable]

      contentViewController.view.layoutSubtreeIfNeeded()
      let fittingSize = contentViewController.view.fittingSize
      if fittingSize != .zero {
        window.setContentSize(fittingSize)
      }
      window.center()

      window.makeKeyAndOrderFront(nil)
      // Same 0.4s the other captures use — just enough for the initial layout/paint pass. Unlike an
      // earlier version of this function, nothing here is waiting on `AgentsSettingsView`'s `.task {
      // await agentSettings.refresh() }` to resolve; see the `initialSettings:` argument this
      // function's caller now passes to `AgentsSettingsViewController`.
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))

      captureWindow(window, filename: filename, in: directory)
      window.orderOut(nil)
    }

    // MARK: - Touch ID approval dialog

    /// Renders `AgentApprovalController.makeAlert(for:)` against a synthetic
    /// `PendingApprovalSummary` — no live `ApprovalCenter`/XPC round trip needed behind it, since
    /// the dialog's contents come entirely from the summary handed to it.
    private static func captureApprovalDialogScreenshot(outputDirectory: URL) {
      let summary = PendingApprovalSummary(
        agentDescription: "claude",
        itemTitle: "GitHub",
        operationDescription: String(localized: "wants to read the password for")
      )
      let alert = AgentApprovalController.makeAlert(for: summary)
      let parent = makeParentWindow()
      parent.orderFrontRegardless()
      // `NSAlert.beginSheetModal(for:)` — not manually attaching `alert.window` as a sheet — is
      // what actually sizes/lays out the alert panel for its text (see `RegenerateRecoveryKeyDebugMenu`'s
      // identical note), and matches how `AgentApprovalController` itself presents this dialog.
      alert.beginSheetModal(for: parent) { _ in }
      RunLoop.current.run(until: Date().addingTimeInterval(0.4))
      captureWindow(alert.window, filename: "agent-approval-dialog.png", in: outputDirectory)
      parent.endSheet(alert.window)
      parent.orderOut(nil)
    }

    // MARK: - Per-item context-menu toggle (text-based; see README)

    /// `ItemListViewController`'s `toggleAgentAccessMenuAction` (851-2445) pops a live `NSMenu` —
    /// `NSMenu.popUp` is fully blocking with no completion-handler equivalent, unlike
    /// `NSAlert.beginSheetModal`, and there's no existing precedent anywhere in this codebase for
    /// capturing a live popped menu. Rather than risk a fragile `Timer`-based interruption of
    /// `NSMenu`'s tracking loop, this demonstrates the same read-modify-write the real menu action
    /// performs — toggling `AgentSettings.allowedItemIDs` for one item — as a captioned before/after
    /// text transcript instead. See README.md for the explicit scope note.
    private static func captureAllowlistToggleTranscript(harness: TophatAgentHarness, outputDirectory: URL) async {
      var lines: [String] = []
      lines.append("Per-item context-menu toggle (Settings → Agents → \"Only Selected Passwords\")")
      lines.append(String(repeating: "=", count: 70))
      lines.append("")
      lines.append(
        "Demonstrates the same read-modify-write ItemListViewController's context-menu \"Allow Agent "
          + "Access\" toggle performs, against the item list's item ID directly (a live popped NSMenu "
          + "isn't screenshotted here — see README.md)."
      )
      lines.append("")

      do {
        _ = try await harness.appClient.setAgentSettings(
          AgentSettings(
            agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: true, accessScope: .selected
          )
        )
        let before = try await harness.appClient.agentSettings()
        lines.append("Before toggling \"GitHub\":")
        lines.append("  allowedItemIDs = \(before.allowedItemIDs)")
        lines.append("")

        var updated = before
        updated.allowedItemIDs.insert(harness.githubItemID)
        _ = try await harness.appClient.setAgentSettings(updated)
        let afterAllow = try await harness.appClient.agentSettings()
        lines.append("After toggling \"GitHub\" on from its context menu:")
        lines.append(
          "  allowedItemIDs = \(afterAllow.allowedItemIDs)  (contains GitHub's item id: \(harness.githubItemID))"
        )
        lines.append("")

        var reverted = afterAllow
        reverted.allowedItemIDs.remove(harness.githubItemID)
        _ = try await harness.appClient.setAgentSettings(reverted)
        let afterRemove = try await harness.appClient.agentSettings()
        lines.append("After toggling \"GitHub\" off again:")
        lines.append("  allowedItemIDs = \(afterRemove.allowedItemIDs)")
      } catch {
        lines.append("FAILED: \(error)")
      }

      write(lines.joined(separator: "\n") + "\n", to: outputDirectory.appendingPathComponent("agent-item-toggle.txt"))
    }

    // MARK: - CLI transcript (denied/timed-out request, allowlist filtering)

    private static func captureCLITranscript(harness: TophatAgentHarness, outputDirectory: URL) async {
      var lines: [String] = []
      lines.append("lilpass transcript — 851-2445 scoped agent access")
      lines.append(String(repeating: "=", count: 70))
      lines.append("")
      lines.append(
        "Captured by calling LilpassCommands (CLI/Sources/Commands/GetCommand.swift's own logic) "
          + "in-process against a throwaway in-memory AgentServer standing in for `claude` — see "
          + "README.md for why this isn't a literal separate `lilpass` process."
      )
      lines.append("")

      // Scenario 1: `.selected` scope, only "GitHub" allowed — allowlist filtering, no existence
      // leak (a non-allowed-but-real item fails exactly like a nonexistent one: exit code 5).
      do {
        _ = try await harness.appClient.setAgentSettings(
          AgentSettings(
            agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: true, accessScope: .selected,
            allowedItemIDs: [harness.githubItemID]
          )
        )
      } catch {
        lines.append("FAILED to configure \"Only Selected Passwords\" scope: \(error)")
      }

      lines.append("$ lilpass get GitHub")
      await appendTranscript(for: "GitHub", client: harness.agentClient, to: &lines)
      lines.append("")

      lines.append("$ lilpass get \"AWS Root\"   # exists, but not allowlisted — must look not-found")
      await appendTranscript(for: "AWS Root", client: harness.agentClient, to: &lines)
      lines.append("")

      lines.append("$ lilpass get \"Does Not Exist\"   # genuinely nonexistent, for comparison")
      await appendTranscript(for: "Does Not Exist", client: harness.agentClient, to: &lines)
      lines.append("")

      // Scenario 2: `.askEveryTime` scope, nobody ever answers the approval prompt — denied/timed
      // out after `TophatAgentHarness`'s short 2s `approvalTimeout` (60s in production).
      do {
        _ = try await harness.appClient.setAgentSettings(
          AgentSettings(
            agentAccessEnabled: true, keepAgentAccessAvailableWhileMacUnlocked: true, accessScope: .askEveryTime
          )
        )
      } catch {
        lines.append("FAILED to configure \"Ask Every Time\" scope: \(error)")
      }

      lines.append("$ lilpass get GitHub   # \"Ask Every Time\" is on; nobody answers the Touch ID prompt")
      await appendTranscript(for: "GitHub", client: harness.agentClient, to: &lines)

      write(lines.joined(separator: "\n") + "\n", to: outputDirectory.appendingPathComponent("lilpass-transcript.txt"))
    }

    private static func appendTranscript(for identifier: String, client: AgentClient, to lines: inout [String]) async {
      do {
        let detail = try await LilpassCommands.getDetail(client: client, identifier: identifier)
        lines.append("title: \(detail.title)")
        if let username = detail.usernames.first { lines.append("username: \(username)") }
        lines.append("password: \(detail.password)")
        lines.append("exit code: \(LilpassExitCode.ok.rawValue)")
      } catch {
        let lilpassError = LilpassError.from(error)
        lines.append("error: \(lilpassError.message)")
        lines.append("exit code: \(lilpassError.exitCode.rawValue)")
      }
    }

    // MARK: - README

    private static func writeReadme(to outputDirectory: URL) {
      let readme = """
        851-2445 — Scoped agent access + Touch ID approvals: tophat capture
        ====================================================================

        - agent-settings-all-passwords.png / agent-settings-only-selected.png /
          agent-settings-ask-every-time.png — Settings → Agents' three 851-2445 access modes.
        - agent-approval-dialog.png — the Touch ID-gated Allow / Allow for 15 Minutes / Deny dialog
          (AgentApprovalController.makeAlert(for:)), rendered from a synthetic pending-approval
          summary — no live approval round trip behind it.
        - agent-item-toggle.txt — the per-item context-menu "Allow Agent Access" toggle's
          before/after AgentSettings.allowedItemIDs state. Not a screenshot: NSMenu.popUp is fully
          blocking with no completion-handler equivalent (unlike NSAlert.beginSheetModal), and there's
          no existing precedent in this codebase for capturing a live popped menu — capturing the
          exact same read-modify-write as text was judged the better trade than a fragile
          Timer-based interruption of NSMenu's tracking loop.
        - lilpass-transcript.txt — a "denied/timed-out" (.askEveryTime, exit code 9) and an
          allowlist-filtering (.selected, exit code 5, indistinguishable from a genuinely nonexistent
          item) demonstration.

          This is captured by calling LilpassCommands (the same argument-parser-free logic
          CLI/Sources/Commands/GetCommand.swift itself calls, including the real
          LilpassError.from(_:) exit-code mapping) in-process, rather than forking a literal separate
          `lilpass` process. macOS requires a launchd plist to reserve a *named* Mach service before
          any process can host one reachable by another, cold process — confirmed empirically while
          designing this capture (bootstrap_check_in for an unreserved name fails with "No such
          process" even from an ordinary, unsandboxed process). The real name
          (AgentXPC.machServiceName) is already claimed by the real, running helper, and installing a
          real (if temporary) LaunchAgent on this shared dev machine just to reserve a throwaway name
          would reintroduce the exact "shared machine hazard" (docs/tophat.md) this whole capture
          exists to avoid. Calling LilpassCommands directly is the closest achievable substitute: real
          production logic, just not a forked OS process.

        Everything above runs against a throwaway, in-memory InMemoryVaultStore +
        InMemoryAgentSettingsStore (see AgentTophatDebugMenu.swift), reached over two in-process
        (anonymous NSXPCListener) connections — one treated as "the app" (Settings reads/writes), one
        treated as an ordinary external agent (scope/approval enforcement) — never the real, on-disk,
        launchd-activated LilPasswordsAgent every concurrently-running worktree on this machine
        otherwise shares.
        """
      write(readme, to: outputDirectory.appendingPathComponent("README.md"))
    }

    private static func write(_ string: String, to url: URL) {
      do {
        try string.write(to: url, atomically: true, encoding: .utf8)
      } catch {
        NSLog("[AgentTophatDebugMenu] failed to write \(url.lastPathComponent): \(error)")
      }
    }

    // MARK: - Capture mechanics (mirrors RecoveryKitDebugMenu's own tophat helpers)

    private static func makeParentWindow() -> NSWindow {
      let parent = NSWindow(
        contentRect: NSRect(x: 80, y: 80, width: 900, height: 700),
        styleMask: [.titled],
        backing: .buffered,
        defer: false
      )
      parent.title = LilPasswordsKit.productName
      return parent
    }

    private static func captureWindow(_ window: NSWindow, filename: String, in directory: URL) {
      window.orderFrontRegardless()
      RunLoop.current.run(until: Date().addingTimeInterval(0.3))

      let outputURL = directory.appendingPathComponent(filename)
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
      process.arguments = ["-x", "-o", "-l\(window.windowNumber)", outputURL.path]
      try? process.run()
      process.waitUntilExit()

      window.orderOut(nil)
    }
  }

  /// Two in-process, anonymous-`NSXPCListener`-backed `AgentClient`s sharing one
  /// `InMemoryVaultStore`/`InMemoryAgentSettingsStore`, seeded with two demo items — everything
  /// `AgentTophatDebugMenu` needs, none of it touching the real vault or the real helper.
  ///
  /// Two clients, not one, because `AgentServer` restricts `agentSettings()`/`setAgentSettings()`
  /// to whichever caller its own `appCallerBundleIdentifier` names as "the app" — and this capture
  /// needs both roles at once: `appClient` to configure scenarios via Settings, `agentClient` to
  /// exercise them exactly as a real external agent would (scope enforcement, approval prompts,
  /// `AgentError.callerNotAuthorized` for the app-only calls). A single in-process caller can't be
  /// both, so each client is backed by its own `AgentServer`/listener, both pointed at the same
  /// shared vault/settings state.
  private struct TophatAgentHarness {
    let appClient: AgentClient
    let agentClient: AgentClient
    let githubItemID: UUID
    let awsRootItemID: UUID

    private let appListener: NSXPCListener
    private let agentListener: NSXPCListener

    // `NSXPCListener.delegate` is a *weak* reference (see its header) — unlike `Harness`'s own
    // `delegate` stored property (`LilpassCoreTests/Support/Harness.swift`), a delegate that's only
    // a local variable inside `init` gets deallocated the moment `init` returns, silently dropping
    // the listener back to having no delegate at all and invalidating every connection made against
    // it. Stored here for exactly the same reason `Harness` stores its own.
    private let appDelegate: AgentXPCListenerDelegate
    private let agentDelegate: AgentXPCListenerDelegate

    init() async throws {
      let vaultStore = InMemoryVaultStore()
      let agentSettingsStore = InMemoryAgentSettingsStore()
      let accessPolicy = AgentSettingsAccessPolicy(store: agentSettingsStore)

      try await vaultStore.createVault()
      let githubID = UUID()
      let awsID = UUID()
      try await vaultStore.create(
        PasswordItem(id: githubID, title: "GitHub", usernames: ["octocat"], password: "correct-horse-battery-staple")
      )
      try await vaultStore.create(
        PasswordItem(id: awsID, title: "AWS Root", usernames: ["root"], password: "s3cr3t-root-only-password")
      )
      githubItemID = githubID
      awsRootItemID = awsID

      let selfIdentity = CallerIdentityResolver.resolve(pid: ProcessInfo.processInfo.processIdentifier)
      let appServer = AgentServer(
        vaultStore: vaultStore,
        accessPolicy: accessPolicy,
        appCallerBundleIdentifier: selfIdentity.bundleIdentifier ?? AgentConnectionSecurity.PeerIdentifier.app.rawValue,
        agentSettingsStore: agentSettingsStore
      )
      appListener = NSXPCListener.anonymous()
      appDelegate = AgentXPCListenerDelegate(
        server: appServer, connectionSecurity: .developmentFallback(reason: "851-2445 tophat")
      )
      appListener.delegate = appDelegate
      appListener.resume()
      appClient = AgentClient(
        endpoint: appListener.endpoint, connectionSecurity: .developmentFallback(reason: "851-2445 tophat")
      )

      let agentServer = AgentServer(
        vaultStore: vaultStore,
        accessPolicy: accessPolicy,
        appCallerBundleIdentifier: "com.851labs.lilpasswords.tophat.unmatched-app-identity",
        agentSettingsStore: agentSettingsStore,
        approvalCenter: ApprovalCenter(appLauncher: NoOpApprovalAppLauncher()),
        approvalTimeout: .seconds(2)
      )
      agentListener = NSXPCListener.anonymous()
      agentDelegate = AgentXPCListenerDelegate(
        server: agentServer, connectionSecurity: .developmentFallback(reason: "851-2445 tophat")
      )
      agentListener.delegate = agentDelegate
      agentListener.resume()
      agentClient = AgentClient(
        endpoint: agentListener.endpoint, connectionSecurity: .developmentFallback(reason: "851-2445 tophat")
      )
    }

    func invalidate() {
      appListener.invalidate()
      agentListener.invalidate()
    }
  }
#endif
