# Modernization & Security Backlog — executed next, after the in-flight Laya build lands

Worklist, not report. Each item = one agent batch, suite-gated, shipped.

## Modernization (verify each against current code first; fix where real)

1. **Swift concurrency correctness**: audit async paths for main-thread
   UI work and unstructured Task leaks (ChatNative streaming,
   Server process watchers). Modernize to structured concurrency,
   actor isolation where state is shared.
2. **SwiftUI data flow**: replace remaining imperative state mutations
   with @Observable/single-source patterns where the codebase's
   ObservableObject usage causes stale-UI bugs (context bar class).
3. **URLSession consolidation**: one shared session with sane timeouts
   instead of ad-hoc URLRequest construction scattered across services
   (Laya client, MemoryArchiveHook, update checker, remote providers).
4. **Error typing**: replace stringly-typed failure states with typed
   errors surfaced uniformly in the UI (no silent try?).
5. **Toolchain**: build against the newest installed Swift; adopt new
   guard-syntax/API where it removes code.

## Security (verify + harden)

1. Secrets: atomic 0600 creation everywhere (no write-then-chmod window);
   verify with a permission-check test over every secret path.
2. Redaction: single redaction function for argv/env/URLs used by ALL
   log and export surfaces (one implementation — no parallel copies).
3. Child processes: explicit env allow-list for spawned binaries
   (inherit nothing by default), pinned binary paths.
4. Endpoints: loopback-only unless the operator enables LAN with a key;
   test both configurations.
5. Supply chain: engine binaries byte-verified; scripts reviewed for
   unquoted expansions.

## Bug-free sweep

1. Force-unwrap and try?-swallow inventory: every instance fixed or
   consciously typed.
2. Edge cases on the flow paths: model switch mid-chat, server stop
   mid-stream, empty document, oversized paste, rapid start/stop.
3. UI truth re-audit on the shipped build (every control does what it
   says, every state reachable).

Execution contract unchanged: suite green per batch, checks pin every
fix, build + install at the end, receipts with real output.
