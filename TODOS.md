# Tmux Rooms — Follow-up TODOS


## Additional terminal adapters

- **What:** Add exact-TTY focus adapters for Terminal.app, Ghostty, and WezTerm.
- **Why:** Core v1 supports only the locally verified iTerm scripting surface.
- **Pros:** More existing tmux clients can be opened in their original terminal tab/window.
- **Cons:** Each terminal has different automation APIs, permission behavior, and verification limits.
- **Context:** An adapter must enumerate tabs/sessions, match exact TTY, select the exact target, activate its window/application, and verify the result. Unsupported clients must remain visible and must not silently trigger Duplicate.
- **Depends on / blocked by:** Stabilized `TerminalControlling` contract and shipped iTerm-first core.

## Claude/Codex agent enrichment

- **What:** Add verified agent kind and `working`/`needs input` attention state, including an optional menu-bar `!N` badge.
- **Why:** Make the tmux roster read more like AI chat session rooms after core lifecycle behavior is trustworthy.
- **Pros:** Quickly identifies which agent room needs attention.
- **Cons:** Adds provider hooks, event identity, freshness, restart, and stale-state policy.
- **Context:** Never synthesize attention state from a process name. Missing, expired, out-of-order, or identity-mismatched events resolve to `unknown`; room inventory remains tmux-authoritative.
- **Depends on / blocked by:** Stable server/session identity model and shipped core room actions.

## Exact detach for existing clients

- **What:** Detach one selected existing non-app-owned tmux client without affecting the session or other clients.
- **Why:** Allow attached windows to be cleaned up from the menu-bar app.
- **Pros:** Completes client management beyond status and focus.
- **Cons:** tmux 3.6b cannot atomically bind full client identity validation to `detach-client`; a TTY-only target has a reuse race.
- **Context:** Core v1 shows client TTY, terminal, session, and focusability but exposes no arbitrary Detach action. Do not implement broad session detach or a silent best-effort approximation.
- **Depends on / blocked by:** A proven race-safe client-context primitive, a future tmux capability, or a separately approved ownership/control design.

## Public or multi-user hardening

**Scope:** Core v1 local single-user 기능 완료를 차단하지 않음.

- Before any public or multi-user deployment, revisit the threat model and reassess sandboxing, Developer ID signing, notarization, and key lifecycle management.
- Inventory TTY, path, and session metadata in logs and evidence; define redaction, retention, and user opt-out behavior before those artifacts leave the local single-user boundary.
- Harden any public updater and its software supply chain before distributing updates outside the local development workflow.

**Provenance:** This repo-local append intentionally changes `TODOS.md` byte identity; the external source follow-up artifact remains unchanged.

## Menu bar panel that survives focus changes

- **What:** Replace `MenuBarExtra` with an app-owned `NSStatusItem` plus an `NSPanel` so the room list stays on screen when another app takes focus.
- **Why:** Open, Preview, and Close Preview all end with iTerm activating, and the SwiftUI panel dismisses itself the moment the app deactivates, so the list disappears on every action.
- **Pros:** The user can act on several rooms in a row, and Close Preview stops being a one-shot that hides its own result.
- **Cons:** The app takes over panel placement, lifetime, and dismissal rules that SwiftUI currently owns, including status item click, Escape, and click outside.
- **Context:** `MenuBarExtra` with `.menuBarExtraStyle(.window)` exposes no public knob for staying open; the panel is owned by SwiftUI and closes on resign key. An owned panel would set `hidesOnDeactivate` to false and a floating window level. The DEBUG fixture window scene and the XCUITests run against that separate scene, so they are unaffected.
- **Depends on / blocked by:** Nothing in core v1. Deferred on 2026-09-01 while the Close Preview toggle shipped against the existing focus policy.
