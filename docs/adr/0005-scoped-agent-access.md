# 0005. Scoped agent access + Touch ID approvals

- Status: Accepted
- Related: [851-2445](https://linear.app/851/issue/851-2445) (this ticket), [851-2428](https://linear.app/851/issue/851-2428) (agent access toggle, `AgentSettings`), [851-2429](https://linear.app/851/issue/851-2429) (access log), [851-2433](https://linear.app/851/issue/851-2433) (write-access toggle), [851-2430](https://linear.app/851/issue/851-2430) (`lilpass` exit codes), `docs/adr/0001-storage-and-process-model.md` (storage/process model, especially section (e) on why `AgentSettings` lives in a helper-owned Keychain item)

## Context

851-2428 shipped one binary toggle: agents (`lilpass`, MCP) either see the whole vault or none of it. 851-2433 added a second, orthogonal toggle for write access. Both are stored in the same helper-owned, ACL'd `AgentSettings` Keychain item (`AgentSettingsStoring`), read and written exclusively through `AgentRequest.getAgentSettings`/`.setAgentSettings`, both restricted to the app's own, code-signing-verified connection (`CallerIdentity.isVerifiedApp(appBundleIdentifier:)`).

That's no longer fine-grained enough. Two things are missing:

1. **Scope.** All-or-nothing access means turning agent access on at all hands over every item — there's no way to say "agents can only see my GitHub and AWS logins" or "ask me every time."
2. **Live approval.** Even with a scope, there's no way to gate a specific request on the person actually being present and consenting in the moment, the way Touch ID gates unlock.

This ADR designs both, entirely within the existing `LilPasswordsKit`/`AgentServer`/XPC architecture: no new IPC mechanism, no new persistence mechanism, no change to `docs/adr/0001-storage-and-process-model.md`'s process model. `AgentServer` remains the only thing that ever touches the vault; the app remains the only thing that ever performs `LAContext` authentication; `AgentSettings` remains the single, fail-closed, helper-owned source of truth.

## Decision

### Three access modes, one `AgentSettings` field

```swift
public enum AgentAccessScope: String, Sendable, Codable, Equatable, CaseIterable {
  case allPasswords
  case selected
  case askEveryTime
}
```

Added to `AgentSettings` as `accessScope: AgentAccessScope`, alongside two new allowlist fields used only by `.selected`:

```swift
public var allowedItemIDs: Set<UUID>
public var allowedGroups: Set<String>
```

- **`.allPasswords`** — today's behavior. The default, and what every pre-851-2445 stored `AgentSettings` item decodes to (see "Backward compatibility" below) — this ticket changes what's possible, not what's already-enabled installs get by surprise.
- **`.selected`** — a caller other than the app only ever sees items whose `id` is in `allowedItemIDs` or whose `group` is in `allowedGroups`. Everything else — list, search, get, TOTP, update, delete — treats a non-allowed item as if it doesn't exist (see "No existence leak" below).
- **`.askEveryTime`** — every vault operation except `.generatePassword` (which never touches the vault) blocks on a live approval before proceeding (see "Approval flow" below).

These three are mutually exclusive, matching a single picker in Settings → Agents, not stackable flags — `.selected` and `.askEveryTime` are two different answers to "what happens when an agent asks for something," not independent toggles.

Same custom-`Decodable`-with-`decodeIfPresent` pattern `agentWriteAccessEnabled` (851-2433) already established, so a Keychain item written before this ticket — no `accessScope`/`allowedItemIDs`/`allowedGroups` keys at all — decodes to `accessScope: .allPasswords, allowedItemIDs: [], allowedGroups: []` instead of throwing `AgentSettingsStoreError.corruptStoredSettings`. `AgentSettings.disabled` (the fail-closed fallback used when the store has nothing, or fails to read at all) also gets `accessScope: .allPasswords` — that field is irrelevant when `agentAccessEnabled` is `false` to begin with, and keeping it `.allPasswords` (rather than, say, `.askEveryTime`) means the fail-closed struct doesn't imply a scope decision was made where none was.

The app itself is exempt from both scope filtering and approval gating, the same way it's already exempt from `agentAccessEnabled`/`agentWriteAccessEnabled` (`AgentServer.isAppCaller(_:)`): the vault's own item list/detail views go through this exact XPC path, and gating them on a toggle meant for `lilpass`/MCP would break the app whenever a person restricted agent access.

### No existence leak

An agent asking for an item outside the allowlist must not be able to distinguish "that item doesn't exist" from "that item exists but you're not allowed to see it" — otherwise the allowlist becomes an oracle for what's in someone's vault (item titles, whether "aws-root" exists, etc.) even with zero read access to any of it.

Concretely, in `AgentServer.vaultResponse(for:caller:)`, under `.selected`, for a non-app caller:

- `.list`/`.search` filter their result sets down to allowed items before returning — an agent doing `lilpass list` sees only what it's allowed to see, not a truncated-but-otherwise-normal list.
- `.getItem`/`.totpCode`/`.deleteItem` (all of which accept an `ItemReference`) resolve **within the allowed set only**: an id or query that matches a real, existing, but non-allowed item throws `AgentError.notFound` — the exact same error a truly nonexistent id produces. A query is resolved by filtering candidate matches to the allowed set *before* counting them for the `.ambiguous` check, so a query that matches two items, only one of which is allowed, is reported as a single unambiguous match (or "not found" if the allowed one wasn't among the matches) — never as "ambiguous," which would itself leak "there's more than one match" about items the caller can't see.
- `.updateItem` (which carries a full `PasswordItem`, not a reference) checks the item's `id`/`group` against the allowlist before writing, throwing `.notFound` the same way if it isn't allowed.
- `.createItem` is always allowed (subject to the existing `agentWriteAccessEnabled` toggle, unchanged) but the new item is **not** automatically added to the allowlist. An agent that can create is not automatically granted standing read access to what it created — the person has to explicitly flip the per-item toggle afterward. This is a deliberate, narrow inconsistency (an agent can create an item it then can't read back) accepted because the alternative — auto-allowlisting agent-created items — would let a write-capable agent silently expand its own read scope.

### Per-item toggle: the item list's context menu, not the detail pane

The detail pane (`DetailViewController`) is single-selection and already dense (identity view, two `CardView`s, edit-mode draft state); `ItemListViewController` already has a per-row `NSMenu` (`contextMenu`, delegate-driven via `menuNeedsUpdate(_:)`) with an existing precedent for a per-row, non-copy action (`deleteMenuItem`). A new checkable "Allow Agents to Access This Password" item is added there, following that exact pattern: enabled/visible only when `accessScope == .selected`, its checkmark state reflecting current allowlist membership, toggling `allowedItemIDs` via a direct `AgentClient()` read-modify-write of `AgentSettings` — matching the existing convention that each screen constructs its own short-lived `AgentClient` (`SecuritySettingsViewController`, `AgentsSettingsViewController` both already do this; there is no shared/injected `AgentClient` instance to plumb through instead) rather than introducing a new dependency-injection seam for this one control.

### Agent identity for grants: top-level process-chain executable, not pid

851-2429's access log already resolves a full process chain per request (`CallerIdentityResolver.resolveProcessChain(pid:maxDepth:)`, e.g. `["lilpass", "node", "claude"]`, immediate caller first) for *display*. Approval grants need a *key* — something to remember "this agent was already approved" by, so "Allow for 15 minutes" can actually skip the next N requests from the same agent without re-prompting.

A bare pid is wrong for this: pids are reused, and a single agent invocation is usually a fresh `lilpass` process per call, so keying on `lilpass`'s own pid would mean "allow for 15 minutes" almost never actually matches the next request. Keying on the immediate parent (whatever spawned `lilpass` — often a short-lived shell) has the same problem one hop up.

Instead, grants are keyed by the **top-level identifiable process in the chain** — the same "last entry" `resolveProcessChain` already walks to, just resolved as an executable path plus (best-effort) code-signing identifier instead of a display name:

```swift
public struct AgentGrantIdentity: Sendable, Equatable, Hashable {
  public var executablePath: String
  public var codeSigningIdentifier: String?
}

extension CallerIdentityResolver {
  public static func resolveTopLevelAgentIdentity(pid: pid_t, maxDepth: Int = 8) -> AgentGrantIdentity
}
```

`resolveTopLevelAgentIdentity` walks the exact same ancestor loop as `resolveProcessChain` (best-effort at every hop, stopping at an unresolvable ancestor, `launchd`, or `maxDepth`) and returns the executable path and code-signing identifier of the *last successfully-named* ancestor — for `claude → zsh → lilpass`, that's `claude`'s own path (e.g. `/Applications/Claude.app/Contents/MacOS/Claude` or wherever the CLI binary actually lives), not `zsh`'s or `lilpass`'s.

**Honest limitation, documented rather than papered over:** this is an attribution and UX safeguard, not a hard security boundary against a determined local attacker. A process running as the same user can:

- Copy or symlink a binary to a path that makes it *look* like a trusted agent (`cp some-other-tool /usr/local/bin/claude`), since `executablePath` is a plain string, the same limitation `CallerIdentity.processPath` already has and already documents.
- Fork a process tree that mimics a known chain shape, or reparent itself, to influence which ancestor `resolveTopLevelAgentIdentity` lands on.
- Read the code-signing identifier off a *different* legitimately-signed binary it happens to also have on disk, though it can't forge a valid signature for an identifier it doesn't hold the private key for — `codeSigningIdentifier`, when present, is real; its absence (an unsigned agent, the common case for local scripts/MCP servers) is where the spoofing risk concentrates, since the fallback is the bare path string.

This mirrors the exact caveat already accepted for the access log's process-chain display (`AccessLogEntry.callerChain` is explicitly "best-effort... for display," never an authorization input) — `AgentGrantIdentity` is new in that it now *gates* something (whether a prompt is skipped), but what it gates is "skip an extra Touch ID-adjacent prompt for 15 minutes," not "grant access at all." A spoofed identity can, at worst, cause one agent's "allow for 15 minutes" grant to also silently cover a second, impersonating process for that window — it can never grant access `.setAgentSettings`/the allowlist/`agentAccessEnabled` didn't already permit, and it can never skip the *first* prompt for a never-before-seen identity. The real security boundary remains what it always was: `.askEveryTime` requires a human to press "Allow" (or "Allow for 15 minutes") on a Touch ID-gated system dialog at least once per distinct top-level identity: the grant only ever narrows *how often*, never *whether*.

### Approval flow: a queued request over the existing XPC channel, not a reverse connection

The obvious shape for "the helper asks the app to show a dialog" is a second, reverse `NSXPCConnection` (the app exports an object, the helper calls into it) — but that's new infrastructure this codebase has never needed: today exactly one direction exists (app/`lilpass` → helper), `AgentXPCProtocol` is a single flattened `send(_:reply:)` method, and `NSXPCConnection.exportedInterface`/`remoteObjectInterface` would need to be set up and torn down for a *second*, app-hosted listener that the helper connects out to — a nontrivial new moving part (a new Mach service name or endpoint handoff, a new accept path, a new set of caller-identity checks in the reverse direction) for what is, underneath, a single infrequent request/response.

Instead, the approval flow reuses the transport that already exists, in the direction it already flows, plus one small piece of glue:

1. A non-app caller's request arrives at `AgentServer` while `accessScope == .askEveryTime`. `AgentServer` computes an `AgentGrantIdentity` for the caller (above) and asks a new `ApprovalCenter` actor for a decision.
2. `ApprovalCenter` checks its in-memory grant table first — an unexpired "allow for 15 minutes" grant for this exact identity resolves immediately, no prompt. Otherwise it records a `PendingApprovalSummary` (an id, when it was requested, the agent's display name, the item's title if resolvable, and a human description of the operation — e.g. *"claude (via lilpass) wants to read the password for GitHub"*), posts a new Darwin notification (`AgentApprovalNotifications.approvalPending`, the same lightweight, payload-less cross-process signaling `LockStateNotifications` already uses for lock-state changes), and suspends the in-flight request on a `CheckedContinuation`.
3. Because `AgentServer` and `ApprovalCenter` are Swift actors, and actors are **reentrant across an `await` suspension point**, this suspension doesn't block the helper. The app's own subsequent requests — `.pendingApprovals` (list what's waiting) and `.resolveApproval(id:decision:)` (answer one) — arrive as ordinary forward requests on the same XPC channel and are serviced by the same `AgentServer` instance while the original request is still parked. No second channel, no new listener.
4. The app observes the Darwin notification, calls `.pendingApprovals` to fetch the summary, performs `LAContext` biometric/device-owner authentication (the same seam `MainWindowController.makeAuthenticator()` already uses for unlock, including its existing `LILPASSWORDS_FAKE_AUTH=1` DEBUG escape hatch), shows a system-style dialog with Allow / Allow for 15 min / Deny, and sends `.resolveApproval(id:decision:)` with the outcome.
5. `ApprovalCenter` resumes the parked continuation with the resolved outcome. `AgentServer` either proceeds with the original request (recording the grant if "15 minutes" was chosen) or throws the new `AgentError.approvalDeniedOrTimedOut`.

If the app isn't currently running, the helper launches it (a new, narrow `ApprovalAppLaunching` seam, a real `NSWorkspace`-based conformer in production) when it posts the pending-approval notification — cheap and idempotent to call even when the app is already running, since bringing it to the foreground is the desired outcome of a Touch ID-style prompt either way, so this needless-tracking of "is a connection already open" isn't needed either.

The wait is bounded to ~60 seconds (configurable, so tests don't actually wait a minute): `ApprovalCenter.requestApproval(for:summary:timeout:)` races the continuation against a `Task.sleep(for:)` that, on firing first, removes the pending entry and resumes the continuation with `.deniedOrTimedOut` — indistinguishable, deliberately, from an explicit Deny; a caller waiting on the answer has no reason to know which happened, and this codebase's exit-code philosophy already treats "the operation didn't happen" as one outcome, not two (see `LilpassExitCode`). `AgentClient.send(_:)` already has no built-in reply timeout of its own (confirmed against `AgentXPCEndToEndTests`'s harness) and blocks on a single `withCheckedThrowingContinuation` per request, so a ~60-second in-helper wait before replying requires no new client-side plumbing at all — `lilpass`/MCP simply see the XPC call take up to a minute, then get back a typed failure.

**Why not just deny immediately when the app isn't reachable**, rather than trying to launch it? Because `.askEveryTime` is meant to be usable from a locked-screen-adjacent, laptop-lid-open, "I stepped away and an agent tried something" state, not only while the app happens to already be frontmost — launching it (which itself requires no additional authorization beyond what launching any app on your own Mac requires) is what makes the Touch ID prompt actually reachable in the common case, at the cost of a visible app-launch the person didn't otherwise ask for. If launch fails, or the person never responds, the request still times out to `.approvalDeniedOrTimedOut` rather than hanging forever.

### New wire-protocol surface

```swift
// AgentRequest, two new cases — both app-only, alongside .getAgentSettings/.setAgentSettings:
case pendingApprovals
case resolveApproval(id: UUID, decision: ApprovalDecision)

public enum ApprovalDecision: Sendable, Codable, Equatable {
  case allowOnce
  case allowFor15Minutes
  case deny
}

public struct PendingApprovalSummary: Sendable, Codable, Equatable, Identifiable {
  public var id: UUID
  public var requestedAt: Date
  public var agentDescription: String
  public var itemTitle: String?
  public var operationDescription: String
}

// AgentResponse, two new cases:
case pendingApprovals([PendingApprovalSummary])
case approvalResolved

// AgentError, one new case:
case approvalDeniedOrTimedOut  // "approval denied or timed out"
```

`.pendingApprovals`/`.resolveApproval` join the existing lock-lifecycle/helper-configuration dispatch group in `AgentServer.handle` (never reach the access log — same exclusion list `.status`/`.createVault`/`.unlock`/`.lock`/`.getAgentSettings`/`.setAgentSettings`/`.rotateRecoveryKey` already use, extended everywhere that list is matched exhaustively: `AgentServer.handle`, `AgentServer.lifecycleOutcome`'s `default` branch, `AgentServer.vaultResponse`'s own exhaustive-but-unreachable case, and `AccessEventSummary.summarize`), and are restricted to the app's own connection the same way.

### New exit code: 9, `approvalDeniedOrTimedOut`

`LilpassExitCode` is documented as additive-only (851-2430); this adds `case approvalDeniedOrTimedOut = 9` (confirmed unused) and one branch in `LilpassError.from(agentError:)` mapping `AgentError.approvalDeniedOrTimedOut` to it.

### Access log: record mode and approval outcome

`AccessEvent` gains `accessMode: AgentAccessScope` (defaulted to `.allPasswords` so existing call sites/tests keep compiling) and `approvalOutcome: ApprovalOutcome?` (nil unless `.askEveryTime` actually ran an approval for this request):

```swift
public enum ApprovalOutcome: Sendable, Codable, Equatable {
  case grantedByPriorGrant
  case grantedOnce
  case grantedFor15Minutes
  case deniedOrTimedOut
}
```

`AgentServer.vaultOutcome(for:caller:)` reads `accessScope` once per request and threads it, plus whatever `ApprovalOutcome` the approval step produced (if any), into the `AccessEvent` it already unconditionally records — a denied/timed-out approval is still logged, the same way a denied request under the existing toggles already is. `AccessLogEntry` gains the same two fields, both with `decodeIfPresent`-based backward compatibility for on-disk JSONL entries written before this ticket, and `AccessEventSummary.entry(for:)` populates them from the `AccessEvent`.

## Alternatives considered

- **A genuine reverse XPC connection** (app exports an interface, helper calls into it directly). Rejected: doubles the XPC surface this codebase has to secure and test (a second `NSXPCListener`, a second caller-identity check, now in the direction where the *helper* is authenticating the *app* as a legitimate approval-dialog host) for a feature that's fundamentally "one infrequent request, one infrequent response" — exactly what the existing forward channel plus a wake-up signal already does, with zero new attack surface.
- **Polling instead of a Darwin notification.** Rejected: this codebase already solved "cross-process, payload-less, low-latency signal" for lock-state changes (`LockStateNotifications`); reintroducing a poll loop for approvals would be strictly worse (either wasted wake-ups or added latency) for no benefit.
- **Auto-allowlisting agent-created items under `.selected`.** Rejected — see "No existence leak" above: it would let write access silently expand read scope.
- **Keying grants by pid or immediate parent.** Rejected — see "Agent identity for grants" above: both are reused/short-lived in exactly the cases (a fresh `lilpass` invocation per call) "allow for 15 minutes" is meant to help with.
- **Treating a `.query` match against a non-allowed item as `.ambiguous` when combined with an allowed match, or as a distinct "forbidden" error.** Rejected — both leak more than a flat `.notFound` about what exists outside the caller's allowlist; see "No existence leak."

## Consequences

- `AgentSettings`, `AgentRequest`, `AgentResponse`, `AgentError`, `AccessEvent`, and `AccessLogEntry` all grow backward-compatible new fields/cases; no existing stored Keychain item or on-disk access-log entry becomes unreadable.
- `AgentServer.vaultResponse(for:caller:)` gains scope-filtering and approval-gating logic that every non-app vault operation now passes through — a new, security-relevant code path that needs the policy-matrix/allowlist/timeout/expiry test coverage this ticket also adds.
- A new `ApprovalCenter` actor and `ApprovalAppLaunching` seam are the only genuinely new runtime components; everything else is additive surface on types that already existed.
- `.askEveryTime` introduces the first case where a `lilpass`/MCP call can take up to ~60 real seconds before returning — acceptable for an explicitly opt-in, "ask every time" mode, but worth calling out to anyone scripting against `lilpass` who assumes calls are fast.
- The top-level-agent identity used for grants is, as documented above, an attribution/UX mechanism, not a hard security boundary — this must stay true in every future change that touches `ApprovalCenter`; it must never become the sole gate on something more consequential than "skip a redundant prompt for 15 minutes."
