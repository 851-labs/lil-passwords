import AppKit
import CoreGraphics
import Foundation
import LilPasswordsKit

// `LilPasswordsAgent` is a Mach service: launchd starts this process on demand when a client (the
// app or `lilpass`) first connects to `AgentXPC.machServiceName`, and stops it again once every
// connection using the service has gone away — see `Agent/Support/com.851labs.lilpasswords.agent.plist`
// and docs/adr/0001-storage-and-process-model.md.

// `VaultStore` (851-2404) is the real, SQLite-backed `VaultStoring` conformer: one instance,
// constructed once for this process's lifetime, persisted at the default on-disk location (see
// `VaultStore.defaultDatabaseURL()`). `AgentServer` never constructs a store itself — it just
// calls `open(with:)`/`lock()` on whatever it's handed — so swapping this line is the only thing
// a future change to where/how the vault lives should ever require here.
let sharedVaultStore = try VaultStore()

// The real, Keychain-backed `VaultKeyStoring` (851-2411): the vault key this process reads back
// on `.unlock` and persists on `.createVault`. See that protocol's documentation for why this is
// the legacy, file-based Keychain rather than the Data Protection Keychain.
let vaultKeyStore = KeychainVaultKeyStore()

// The real, Keychain-backed `AgentSettingsStoring` (851-2428 security review): the agent-access
// settings — "Allow agents to access passwords" and "keep agent access available while the Mac is
// unlocked" — are owned by this helper alone, in an explicitly ACL'd Keychain item, rather than
// the shared, any-process-writable `AppSettings` UserDefaults suite. See that protocol's
// documentation and docs/adr/0001-storage-and-process-model.md (e). One instance, shared between
// the access policy below (reads only) and `AgentServer` (reads and writes, via the
// `.getAgentSettings`/`.setAgentSettings` ops the Settings UI calls through `AgentClient`).
let agentSettingsStore = KeychainAgentSettingsStore()

// Agent access starts disabled and stays that way until a user explicitly turns it on in
// Settings → Agents — never hardcode `true` here. `AgentSettingsAccessPolicy` reads that toggle
// (and the app's own-connection exemption) live out of `agentSettingsStore`; see its documentation
// for why re-reading per request is sufficient without separate KVO/notification plumbing.
let accessPolicy: any AccessPolicyProviding = AgentSettingsAccessPolicy(store: agentSettingsStore)

// The real, 851-2429 access log: an append-only, permission-restricted JSONL file in Application
// Support, pruned to 30 days. Falls back to `NoOpAccessLog` only if the file/directory can't be
// set up at all (e.g. an unwritable home directory) — better to keep serving vault operations
// without a log than to make a broken access log take the whole helper down.
let accessLog: any AccessLogging
do {
  accessLog = try AccessLogStore()
} catch {
  FileHandle.standardError.write(Data("LilPasswordsAgent: failed to open the access log: \(error)\n".utf8))
  accessLog = NoOpAccessLog()
}

let server = AgentServer(
  vaultStore: sharedVaultStore,
  vaultKeyStore: vaultKeyStore,
  accessPolicy: accessPolicy,
  accessLog: accessLog,
  agentSettingsStore: agentSettingsStore
)

// Accept only connections from the app or `lilpass`, validated against our own running process's
// code-signing team identifier — see `AgentConnectionSecurity`'s documentation for why this reads
// the team id from `self` rather than a hardcoded constant, and for the ad-hoc/unsigned-build
// fallback (the default for local dev builds and CI; see `Config/Base.xcconfig`).
let connectionSecurity = AgentConnectionSecurity.requirement(acceptingPeers: [.app, .cli])
let listenerDelegate = AgentXPCListenerDelegate(server: server, connectionSecurity: connectionSecurity)

let listener = NSXPCListener(machServiceName: AgentXPC.machServiceName)
listener.delegate = listenerDelegate
listener.resume()

// MARK: - Auto-lock (851-2411)
//
// Three of this ticket's four auto-lock triggers live here, in the helper, because they're
// system-wide signals this process can observe for as long as it's alive (which, per the Mach
// service comment above, is for as long as the app holds a connection open) — see
// `AutoLockEngine`'s documentation for why the fourth (quit) instead lives in the app's
// `AppDelegate`: quitting is specifically the *app* quitting, not this helper.

/// Wraps `CGEventSourceSecondsSinceLastEventType`, using the `~0` ("any input event type")
/// sentinel documented in `CGEventSource.h` (not exposed as a named Swift constant) so idle time
/// reflects keyboard, mouse, and every other HID input, not just one event type.
struct SystemIdleTimeProvider: IdleTimeProviding {
  func idleInterval() -> TimeInterval {
    // `CGEventType(rawValue:)` is failable in its Swift import, but `~0` is the documented
    // "any event type" sentinel and is always a valid raw value — force-unwrapping is safe here.
    // The free-function form (`CGEventSourceSecondsSinceLastEventType`) is obsoleted in Swift;
    // this is its replacement per the SDK's availability diagnostic.
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
  }
}

// `AppSettingsAutoLockPolicy` reads Settings → Security → "Lock after" (851-2424) live, off the
// same shared `UserDefaults` suite the app's Settings window writes to; its own default (5
// minutes) matches this ticket's original hardcoded one.
let autoLockEngine = AutoLockEngine(policy: AppSettingsAutoLockPolicy(), idleProvider: SystemIdleTimeProvider())

/// Locks the vault (if it isn't already) and tells every observer (the app's 851-2422 lock
/// screen) that lock state changed. Idempotent: `VaultStoring.lock()` on an already-locked store
/// is a no-op, so every trigger below can call this unconditionally without first checking
/// `isUnlocked`.
func lockVaultNow() async {
  await sharedVaultStore.lock()
  LockStateNotifications.post()
}

// Idle timeout: polled rather than scheduled for the exact remaining interval, since the idle
// clock resets on every input and there's no notification for "input happened" to reschedule
// against — a short poll interval approximates a live timer closely enough that a user can't
// perceive the difference, at negligible cost for a timer this infrequent.
let idleCheckInterval: TimeInterval = 5
let idleTimer = Timer(timeInterval: idleCheckInterval, repeats: true) { _ in
  Task {
    if await autoLockEngine.shouldLockForIdleTimeout() {
      await lockVaultNow()
    }
  }
}
RunLoop.main.add(idleTimer, forMode: .common)

// Sleep: lock unconditionally the moment the system starts sleeping, regardless of the idle
// timeout policy. `NSWorkspace`'s notification center works from any process with a running
// `CFRunLoop` (this one, via `RunLoop.main.run()` below) — it doesn't require `NSApplication`.
NSWorkspace.shared.notificationCenter.addObserver(
  forName: NSWorkspace.willSleepNotification,
  object: nil,
  queue: nil
) { _ in
  Task { await lockVaultNow() }
}

// Screen lock: also unconditional, and distinct from sleep (fast user switching or a manual
// "Lock Screen" both post this without the system actually sleeping).
DistributedNotificationCenter.default().addObserver(
  forName: Notification.Name("com.apple.screenIsLocked"),
  object: nil,
  queue: nil
) { _ in
  Task { await lockVaultNow() }
}

RunLoop.main.run()
