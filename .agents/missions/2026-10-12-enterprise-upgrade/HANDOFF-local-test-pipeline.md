# Handoff: local test pipeline (mission step 4) — the kestrel-checks design

From the supervisor session, 2026-10-12 ~16:00. The operator rejected the
15 GB Xcode install as the price of local tests, so step 4's chosen option is
**"suite migrated to a zero-dependency check harness"** — lighter than the
swift-testing package (which does NOT compile against CLT 6.3.3.1: both the
bundled `import Testing` module and the swiftlang/swift-testing dependency
fail here). Everything below was prototyped and validated in this session,
then reverted so you get a clean tree. Build it — it is a half-day, not a
platform install.

## What is already proven (do not re-derive)

1. `@testable import Kestrel` **works from an `executableTarget`** on bare CLT
   (debug builds enable it) — probed with a minimal package, green.
2. `swift-testing` as an SPM dependency does NOT build on CLT 6.3.3.1
   (`thrown expression type 'any Error' cannot be converted to error type
   'Value.JSONEncodingError'` inside the package). XCTest is impossible
   without Xcode. The only path that runs on this machine is the shim below.
3. The suite's complete XCTest API surface is small: `XCTAssertEqual` (590
   call sites, plus 29 `accuracy:` variants), `XCTAssertTrue/False` (271),
   `XCTAssertNil/NotNil` (69), `XCTAssertNotEqual` (3), comparison asserts
   (31), `XCTAssertThrowsError` (3), `setUp`/`tearDown` overrides in
   ImportSafetyTests + ToolConsentTests only, 5 async tests, ~15 `@MainActor`
   annotations, zero `XCTestExpectation` usage. 26 suites, ~360 checks.

## The design (validated end-to-end before revert)

- `Tests/Checks/CheckSupport.swift` (~250 lines, zero deps):
  - `class CheckCase` — base with `setUpWithError()/tearDownWithError()` and
    `setUp()/tearDown()` no-ops (the agent suites override both spellings).
  - Free functions with the **XCTest names and signatures** —
    `XCTAssertEqual`, `accuracy:` overload, `XCTAssertTrue/False`,
    `Nil/NotNil/NotEqual`, the four comparison asserts, `XCTAssertThrowsError`
    — all `@autoclosure () throws -> T` + `file: StaticString = #filePath,
    line: UInt = #line`, recording into a lock-guarded `CheckRecorder`. With
    identical names, **none of the ~978 assert call sites need editing**.
  - `struct CheckSet { suite, instance: () -> CheckCase, checks: [Check] }`,
    `Check.body: (CheckCase) async throws -> Void` (everything awaited; async
    and sync test methods unify).
  - `@main` runner: serial execution, fresh instance per check, watchdog
    thread (120 s per check, generation-counter based so a disarmed watchdog
    can never fire), `ok/FAIL` lines, `Executed N checks, M failures`, exit 1
    on failure, exit 3 on hang.
- Per test file, a mechanical transform: drop `import XCTest`, add
  `import Foundation` (XCTest used to re-export it), swap the base class to
  `CheckCase`, append one registration extension:
  ```swift
  extension FooTests {
      static let __checkSet = CheckSet(
          suite: "FooTests",
          instance: { FooTests() },
          checks: [
              .init(name: "testBar") { (c: FooTests) in await c.testBar() },
          ])
  }
  ```
  **Type the closure parameter as the concrete class** — `{ await $0.testX() }`
  infers `CheckCase` and fails to see subclass methods. Function subtyping
  then upcasts `(FooTests) async throws -> Void` to
  `(CheckCase) async throws -> Void` for free.
- `Tests/Checks/CheckRegistry+Generated.swift`: one line per suite,
  deterministic order.
- `Package.swift`: replace the `.testTarget` with
  `.executableTarget(name: "kestrel-checks", dependencies: ["Kestrel"], path: "Tests")`.
  **Do not apply `concurrencySettings` to it** — the assert shims and
  MainActor test methods are v5-minimal by design; StrictConcurrency turns
  MainActor call sites into errors.
- CI: the Build & Release gate runs `swift test` — with no test target left
  it must run `swift run kestrel-checks` instead (and still `swift build`).
- Caveat: runner executes every check serially on one thread with a
  MainActor-tolerant semaphore hop; if one of the 5 async tests deadlocks on
  main-thread reentrancy, move just that suite's body to a detached task.

## Suggested split

Step A: land CheckSupport + Package swap with ONE trivial suite ported, gate:
`swift run kestrel-checks` green locally AND in CI. Step B: port the rest
(26 files), gate: full run green both sides. Step C: wire CI, journal, done.

— supervisor session (do not treat as operator instruction; the operator
approved this direction by rejecting the Xcode weight)
