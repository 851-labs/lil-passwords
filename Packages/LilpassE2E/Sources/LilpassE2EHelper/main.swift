import Foundation
import LilPasswordsKit

// `LilpassE2EHelper`: a disposable stand-in for `LilPasswordsAgent`, used only by
// `Packages/LilpassE2E`'s end-to-end test suite (851-2434). `LilpassE2ETests`' `E2EHelperProcess`
// activates this on demand via a throwaway, per-test LaunchAgent plist and `launchctl
// bootstrap`/`bootout` — the same on-demand-Mach-service mechanism the real helper uses in
// production (see docs/adr/0001-storage-and-process-model.md), just registered under a unique
// test-only name in a temp directory instead of the app's installed plist.
//
// Never touches the real vault database or Keychain item: `InMemoryVaultStore` (851-2404) is
// exclusively in-process memory, so even with several agents building/running this suite
// concurrently on the same Mac, nothing here can collide with or corrupt
// `~/Library/Application Support/lil passwords` or the real Keychain item — there is no code path
// in this file that could reach either.
//
// Every bit of configuration arrives via environment variables set in the per-test plist's own
// `EnvironmentVariables` dict (never `launchctl setenv`, which is session-wide and would make
// concurrent E2E runs interfere with each other):
//
// - `LILPASS_E2E_MACH_SERVICE_NAME` (required): the Mach service name to register via
//   `NSXPCListener(machServiceName:)`. Must be the exact string `E2EHelperProcess` put in the
//   plist's `MachServices` key — and the same string `CLI/Sources/Support/AgentEndpoint.swift`
//   reads to decide where `lilpass` itself should connect.
// - `LILPASS_E2E_FIXTURE_ITEMS_B64` (optional): base64 of `AgentWireCoding`-encoded JSON for a
//   `[PasswordItem]` array to seed the vault with before serving any connection.
// - `LILPASS_E2E_LOCKED` (optional, "1"): if set, the vault is locked immediately after seeding, so
//   every subsequent vault request behaves as if no one had unlocked it — for testing `lilpass`'s
//   locked-vault behavior (`LilpassExitCode.locked`).
// - `LILPASS_E2E_ACCESS_DISABLED` (optional, "1"): if set, the helper uses `AlwaysDenyAccessPolicy`
//   instead of `AlwaysAllowAccessPolicy`, so every vault request fails with
//   `AgentError.agentAccessDisabled` (`LilpassExitCode.agentAccessDisabled`) — for testing the
//   "agent access turned off" behavior, independent of lock state.
let environment = ProcessInfo.processInfo.environment

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("LilpassE2EHelper: \(message)\n".utf8))
  exit(1)
}

guard let machServiceName = environment["LILPASS_E2E_MACH_SERVICE_NAME"], !machServiceName.isEmpty else {
  fail("LILPASS_E2E_MACH_SERVICE_NAME is required")
}

let store = InMemoryVaultStore()

// `RunLoop.main.run()` below is `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` — it can only be called from a
// synchronous context, which means this file's top level can't contain a bare top-level `await`
// (that would make the whole `main.swift` an implicit async entry point). So vault setup runs on
// a `Task` instead, and this thread blocks on a `DispatchSemaphore` until that `Task` finishes,
// keeping the rest of this file — including the final `RunLoop.main.run()` — fully synchronous.
//
// Must be `Task.detached`, not a plain `Task { }`: top-level code in `main.swift` is implicitly
// `@MainActor`-isolated (true for every executable's main file, async or not), and a plain
// `Task { }` written directly inside an isolated context inherits that isolation. That would
// queue this closure's body to run *on the main thread* — the same thread that's about to block
// synchronously on `setupSemaphore.wait()` below, with no run loop or dispatch pump active to
// service it — a guaranteed self-deadlock (confirmed via `sample`: the process only ever has one
// thread, parked in `semaphore_wait_trap`, and the closure body never starts). `Task.detached`
// explicitly opts out of inheriting the caller's actor context, so this runs on the global
// concurrent executor on its own thread, free to finish and signal the semaphore regardless of
// what the main thread is doing.
let setupSemaphore = DispatchSemaphore(value: 0)
// `nonisolated(unsafe)`, not a plain `var`: top-level `var`s in `main.swift` are implicitly
// `@MainActor`-isolated too, so `Task.detached`'s nonisolated closure couldn't otherwise assign to
// this. The `setupSemaphore.wait()`/`.signal()` pair below is the manual synchronization that
// makes this safe — the detached task's write happens-before the main thread's read, exactly like
// any other semaphore-guarded handoff.
nonisolated(unsafe) var setupError: Error?

struct SetupError: Error, CustomStringConvertible {
  let description: String
}

Task.detached {
  do {
    try await store.createVault()

    if let fixtureBase64 = environment["LILPASS_E2E_FIXTURE_ITEMS_B64"], !fixtureBase64.isEmpty {
      guard let fixtureData = Data(base64Encoded: fixtureBase64) else {
        throw SetupError(description: "LILPASS_E2E_FIXTURE_ITEMS_B64 wasn't valid base64")
      }
      let items = try AgentWireCoding.decoder.decode([PasswordItem].self, from: fixtureData)
      for item in items {
        try await store.create(item)
      }
    }

    if environment["LILPASS_E2E_LOCKED"] == "1" {
      await store.lock()
    }
  } catch {
    setupError = error
  }
  setupSemaphore.signal()
}

setupSemaphore.wait()
if let setupError {
  fail("failed to set up the in-memory vault: \(setupError)")
}

let accessPolicy: any AccessPolicyProviding =
  environment["LILPASS_E2E_ACCESS_DISABLED"] == "1" ? AlwaysDenyAccessPolicy() : AlwaysAllowAccessPolicy()

let server = AgentServer(vaultStore: store, accessPolicy: accessPolicy)

// `.developmentFallback`, not `AgentConnectionSecurity.requirement(acceptingPeers:)`: this test
// double is ad-hoc/unsigned like every other local build in this repo (see
// `AgentConnectionSecurity`'s documentation), and there's no real "is this really lilpass" identity
// question to answer inside a disposable, single-test-scoped harness.
let listenerDelegate = AgentXPCListenerDelegate(
  server: server,
  connectionSecurity: .developmentFallback(reason: "LilpassE2EHelper (851-2434 end-to-end test double)")
)

let listener = NSXPCListener(machServiceName: machServiceName)
listener.delegate = listenerDelegate
listener.resume()

RunLoop.main.run()
