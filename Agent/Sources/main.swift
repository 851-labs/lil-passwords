import Foundation
import LilPasswordsKit

// `LilPasswordsAgent` is a Mach service: launchd starts this process on demand when a client (the
// app or `lilpw`) first connects to `AgentXPC.machServiceName`, and stops it again once every
// connection using the service has gone away — see `Agent/Support/com.851labs.lilpasswords.agent.plist`
// and docs/adr/0001-storage-and-process-model.md.

// `VaultStore` (851-2404) is the real, SQLite-backed `VaultStoring` conformer: one instance,
// constructed once for this process's lifetime, persisted at the default on-disk location (see
// `VaultStore.defaultDatabaseURL()`). `AgentServer` never constructs a store itself — it just
// calls `open(with:)`/`lock()` on whatever it's handed — so swapping this line is the only thing
// a future change to where/how the vault lives should ever require here.
let sharedVaultStore = try VaultStore()

// Agent access starts disabled and stays that way until a user explicitly turns it on (during
// onboarding or in Settings) — never hardcode `true` here. `AlwaysDenyAccessPolicy` is wired in
// explicitly rather than leaning on `AgentServer`'s own `AlwaysAllowAccessPolicy()` parameter
// default, which exists only for tests that don't care about the toggle.
// TODO(851-2428): replace this with the real, AppSettings-backed `AccessPolicyProviding` (the
// Settings → Agents toggle) once it exists.
//
// Until then, a DEBUG-only local override lets 851-2430/851-2431 tophat `lilpw`/`lilpw mcp`
// against a real, launchd-managed helper without hand-building Settings UI first. See
// docs/tophat.md for how to enable it. `#if DEBUG` guarantees this can never reach a Release
// build: the override check (env var, launch argument) isn't merely unreachable at runtime in
// Release, its code doesn't exist in the compiled binary at all, and the `#else` branch is a bare,
// unconditional `AlwaysDenyAccessPolicy()` with no override path of any kind.
#if DEBUG
  /// - Returns: `true` if a developer has explicitly opted this helper process into agent access
  ///   for local tophat testing, via either:
  ///   - `launchctl setenv LILPW_TOPHAT_ALLOW_AGENT_ACCESS 1` (launchd reads its own managed
  ///     environment when it activates the on-demand Mach service, so this must be set — and the
  ///     helper stopped/relaunched if it was already running — before the next connection attempt
  ///     triggers activation), or
  ///   - passing `--allow-agent-access-debug` when launching this binary directly (e.g. running it
  ///     from Xcode or a terminal rather than through launchd).
  func debugAgentAccessOverrideEnabled() -> Bool {
    if ProcessInfo.processInfo.environment["LILPW_TOPHAT_ALLOW_AGENT_ACCESS"] == "1" { return true }
    if CommandLine.arguments.contains("--allow-agent-access-debug") { return true }
    return false
  }

  let accessPolicy: any AccessPolicyProviding =
    debugAgentAccessOverrideEnabled() ? AlwaysAllowAccessPolicy() : AlwaysDenyAccessPolicy()
#else
  let accessPolicy: any AccessPolicyProviding = AlwaysDenyAccessPolicy()
#endif

let server = AgentServer(vaultStore: sharedVaultStore, accessPolicy: accessPolicy)

// TODO(851-2429): supply the real `AccessLogging` conformer once it exists; `AgentServer`'s default
// (`NoOpAccessLog`) is used above until then.

// Accept only connections from the app or `lilpw`, validated against our own running process's
// code-signing team identifier — see `AgentConnectionSecurity`'s documentation for why this reads
// the team id from `self` rather than a hardcoded constant, and for the ad-hoc/unsigned-build
// fallback (the default for local dev builds and CI; see `Config/Base.xcconfig`).
let connectionSecurity = AgentConnectionSecurity.requirement(acceptingPeers: [.app, .cli])
let listenerDelegate = AgentXPCListenerDelegate(server: server, connectionSecurity: connectionSecurity)

let listener = NSXPCListener(machServiceName: AgentXPC.machServiceName)
listener.delegate = listenerDelegate
listener.resume()

RunLoop.main.run()
