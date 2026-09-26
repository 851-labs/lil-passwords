import Foundation
import LilPasswordsKit

/// Where `lilpass` connects to find `LilPasswordsAgent`.
///
/// Production always talks to the real, launchd-activated Mach service at
/// `AgentXPC.machServiceName` — every command should go through ``makeClient()`` rather than
/// constructing `AgentClient()` directly, so there's exactly one place this decision is made.
///
/// The only exception is a DEBUG-only override for 851-2434's end-to-end test suite: it builds the
/// real `lilpass` binary and runs it as a subprocess against a disposable, in-memory-vault test
/// helper registered under a unique, per-test Mach service name (never the production
/// `~/Library/Application Support/lil passwords` vault or the real Keychain item — see
/// `Packages/LilpassE2E`). `#if DEBUG` guarantees this override has no existence at all in a Release
/// build, mirroring the pattern `Agent/Sources/main.swift` already uses for
/// `LILPASS_TOPHAT_ALLOW_AGENT_ACCESS` (see docs/tophat.md): the `LILPASS_E2E_MACH_SERVICE_NAME`
/// check isn't merely unreachable in Release, its code isn't compiled in at all.
enum AgentEndpoint {
  #if DEBUG
    /// Set by `LilpassE2ETests` to point this process at a disposable per-test helper instead of the
    /// real helper. Never read outside a DEBUG build.
    static let e2eMachServiceNameOverrideKey = "LILPASS_E2E_MACH_SERVICE_NAME"
  #endif

  static func makeClient() -> AgentClient {
    #if DEBUG
      if let override = ProcessInfo.processInfo.environment[e2eMachServiceNameOverrideKey],
        !override.isEmpty
      {
        return AgentClient(machServiceName: override)
      }
    #endif
    return AgentClient()
  }
}
