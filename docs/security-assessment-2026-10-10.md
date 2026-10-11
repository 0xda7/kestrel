# Kestrel-AIEngine Vulnerability Assessment

**Date:** 2026-10-10 · **Scope:** working tree at `main` (b3ad893) · **Method:** static review of Swift sources, launch configuration, vendored trees, build/update pipeline, and bundled web UI; advisory database lookups for vendored components.

**Disclaimer:** static assessment of the repository only. No dynamic testing (port scans, exploit attempts) was performed against a running instance. Findings are verified against source, not runtime.

## Summary

Kestrel-AIEngine is a macOS SwiftUI application that vendors llama.cpp, whisper.cpp, and stable-diffusion.cpp, launches local inference servers (default `127.0.0.1`, optional LAN mode), and connects to remote AI providers. Overall posture is solid for a local-first desktop app: remote provider keys live in the Keychain (`ThisDeviceOnly`), the model-JavaScript sandbox is genuinely sealed (unique origin, CSP `default-src 'none'`, network APIs neutralized), vendor trees are pinned by commit, model downloads are sha256-verified, markdown rendering escapes HTML, and remote provider URLs enforce HTTPS.

The risks cluster in four places: (1) the opt-in LAN mode exposes an unauthenticated, plaintext-HTTP OpenAI-compatible API on `0.0.0.0`; (2) the shareable diagnostics export leaks the engine API key in plaintext; (3) settings/MCP config import is a one-click arbitrary-process-execution vector; (4) agent tool consent ("Always allow") is permanent and global. The vendored llama.cpp (b11172, 2026-09-24) postdates all published llama.cpp advisories, and the specific CVE the assessment brief cited — CVE-2024-21616 — is a Juniper Junos OS vulnerability that does not apply to this codebase at all.

**Severity counts:** 2 High · 7 Medium · 4 Low · several informational.

## Findings

### Network layer

**KES-01 · LAN mode exposes an unauthenticated, plaintext-HTTP inference API on all interfaces**
- **Severity:** High
- **CWE:** CWE-319 (Cleartext Transmission of Sensitive Information), CWE-306 (Missing Authentication for Critical Function)
- **Location:** `Sources/Servers/Server.swift:329` and `:434` (`--host`, `localNetworkDiscovery ? "0.0.0.0" : "127.0.0.1"`), `:111/:815` (`apiKeyEnabled` defaults to `false`), `:382/:445` (`--api-key` passed only when enabled), `:1833` (`serverURL` is hardcoded `http://`)
- **Description:** When the user enables local network discovery, llama-server binds `0.0.0.0` over plain HTTP. The API key is optional in this mode: the only hard refusal (`Server.swift:1888-1892`) fires when agent tools are *also* enabled. Without a key, any host on the LAN can use the engine, read and inject conversations, and reach the bundled web chat UI. With a key, the `Authorization: Bearer` token transmits in cleartext, so it is sniffable on any shared/hostile network. No TLS option exists anywhere in the launch path.
- **Remediation:** Require the API key whenever `localNetworkDiscovery` is on (not just with agent tools); add a TLS option for LAN mode (llama-server upstream `--ssl` flags, or a local reverse proxy); consider binding to the specific active interface rather than `0.0.0.0`.

**KES-02 · Web UI is untokenized and Bonjour advertises the auth state**
- **Severity:** Medium
- **CWE:** CWE-284 (Improper Access Control), CWE-200 (Exposure of Sensitive Information)
- **Location:** `Sources/Servers/Server.swift:1837-1850` (`webChatURL` — no token component), `:2479` (Bonjour TXT advertises `auth: bearer|none`)
- **Description:** The bundled web chat UI opens at a bare `http://127.0.0.1:<port>/` URL with no token; the only gate is the optional API key. In LAN mode without a key, any LAN browser gets a fully functional chat UI on the user's GPU and model. In loopback mode, any local process can reach the UI and API. Bonjour actively advertises to the LAN whether the endpoint is protected (`auth: none`), making keyless instances trivially discoverable.
- **Remediation:** In LAN mode, require a key (see KES-01) and stop advertising `auth: none`; consider embedding a per-session token in the UI URL as a second factor even on loopback.

### Application layer

**KES-03 · Engine API key leaks into the shareable diagnostics export**
- **Severity:** High
- **CWE:** CWE-532 (Insertion of Sensitive Information into Log File)
- **Location:** `Sources/Servers/LogsTab.swift:466` (`args: \(currentSettings.arguments.joined(separator: " "))`); the argument array includes `--api-key <secret>` (`Sources/Servers/Server.swift:382`); the startup banner redactor at `Server.swift:1991` is not reused here
- **Description:** "Export diagnostics" writes a report intended for sharing into `~/Downloads`. It joins the full server argument array, which contains the engine API key in plaintext whenever key protection is enabled. The startup log banner redacts `--api-key` (`Server.swift:1991`), but the diagnostics path bypasses that helper. A user who enables the key and then shares a diagnostics file leaks it.
- **Remediation:** Reuse the `redact` helper from `Server.swift:1991` in `saveDiagnostics` (and any other argument-printing call site); add a regression test asserting the key never appears in diagnostics output.

**KES-04 · Engine API key visible in process argument list**
- **Severity:** Medium
- **CWE:** CWE-532 / CWE-798 (Use of Hard-coded/CLI-exposed Credentials)
- **Location:** `Sources/Servers/Server.swift:382`, `:445` (`args += ["--api-key", Keychain.apiKey()]`)
- **Description:** The key is passed as child-process argv, so it is readable by every local user and process via `ps` while the server runs. On a single-user machine the exposure is modest; on shared Macs it defeats the key's purpose. The same applies to Pi delegate prompts, which ride argv (`Sources/Chat/PiDelegateService.swift:117-141`).
- **Remediation:** Pass the key via environment variable or a config file the server reads, if the bundled engine build supports it; otherwise document the residual risk and keep the key out of argv for delegate processes that already accept stdin.

**KES-05 · "Always allow" grants permanent, global consent to agent tools — including shell execution**
- **Severity:** Medium
- **CWE:** CWE-693 (Protection Mechanism Failure)
- **Location:** `Sources/Chat/ChatNative.swift:1656-1660`, `:1760-1767` (per-tool `alwaysAllowed` persisted in UserDefaults); `:1762-1766` (`alwaysServer` whitelists *every* tool of a server); `Sources/Chat/ChatToolsService.swift:84-87` (`exec_shell_command` is a built-in tool)
- **Description:** One click on "Always allow" for `exec_shell_command` lets the model run shell commands with the user's full privileges for the life of the install, with no re-prompt. The app is unsandboxed (no App Sandbox entitlement), so an approved tool call is full user-account code execution. `alwaysServer` extends this to all present and future tools of a server. The permission card does show raw arguments (`ToolPermissionCard.swift:34`), which helps but doesn't bound the grant.
- **Remediation:** Make "Always allow" expire (per-session or time-boxed); never persist it for `exec_shell_command`; require per-call confirmation for tool names not seen before even under `alwaysServer`.

**KES-06 · Settings import and pasted MCP JSON are one-click arbitrary process execution**
- **Severity:** Medium
- **CWE:** CWE-494 (Download of Code Without Integrity Check), CWE-20 (Improper Input Validation)
- **Location:** `Sources/Settings/SettingsArchive.swift:33-39` and `Sources/App/Support.swift:265-294` (import restores `mcpServers`, `serverBinary`, `latchBinaryPath`, `piBinaryPath`, `extraArgs`); `Sources/MCP/MCPStdioTransport.swift:44-62` (launches `command` + `arguments` + `environment` + `workingDirectory` with no validation beyond executable-exists); `Sources/MCP/MCPModels.swift:51-91` (pasted MCP JSON is equivalent)
- **Description:** A malicious `kestrel-settings.json` handed to a user (or pasted MCP config) restores MCP server definitions whose command, arguments, and environment the app executes verbatim on next server start. `extraArgs` also flows unvalidated into the engine argv (`Server.swift:402,447`), so the same import can add arbitrary engine flags (e.g. re-enabling a LAN bind). There is no integrity check or confirmation dialog listing what will be spawned.
- **Remediation:** Before applying an import, show a confirmation sheet listing every executable path, MCP command, and env delta; require explicit approval for process-spawning keys; consider excluding `mcpServers`/binary paths from imports entirely.

**KES-07 · Chat transcript import silently sets the agent tools' working directory**
- **Severity:** Low
- **CWE:** CWE-22 (Improper Limitation of a Pathname to a Restricted Directory)
- **Location:** `Sources/Chat/ChatJSONL.swift:196-198` (import restores `kestrelWorkingDirectory` verbatim as tool cwd)
- **Description:** A shared `.jsonl` conversation file can aim `exec_shell_command` and delegate binaries at an attacker-chosen directory with no prompt. Combined with KES-05's persistent "always allow", a crafted transcript plus one click becomes file access in an arbitrary location. No `..`/symlink checks exist anywhere in the Swift sources (grep confirms), though other file paths are app-generated.
- **Remediation:** Prompt on import whenever `kestrelWorkingDirectory` is non-default; sanitize stored paths against a standardizing pass.

**KES-08 · Memory-archive hook posts full conversations to a user-configured URL, with token in UserDefaults**
- **Severity:** Low
- **CWE:** CWE-912 (Hidden Functionality / data exfiltration channel), CWE-256 (Plaintext Storage of a Password)
- **Location:** `Sources/Chat/MemoryArchiveHook.swift:48-54, 133-148`, `:56-60, 141-142`; `Sources/Chat/ChatAdvancedSettingsSection.swift:29, 415`
- **Description:** Every conversation turn is POSTed to any user-entered http/https URL with a bearer secret kept in plaintext UserDefaults. If settings are tampered with locally, this is a ready-made exfiltration channel. Mitigating: the endpoint key is not restorable via the settings archive, so remote tampering doesn't reach it.
- **Remediation:** Move the secret to the Keychain; require confirmation when the archive endpoint changes; log each post in the session log.

### Infrastructure layer

**KES-09 · Update install strips the quarantine attribute and can silently skip checksum verification**
- **Severity:** Medium
- **CWE:** CWE-494 (Download of Code Without Integrity Check)
- **Location:** `Sources/Models/Updates.swift:101-117` (checksum fetched with `try?`; a fetch failure skips verification and proceeds to install), `:176` (`xattr -dr com.apple.quarantine` on the installed copy)
- **Description:** The updater downloads a DMG, verifies sha256 *if* the checksums file downloads successfully, mounts it, and replaces the running app. The `try?` on the checksum fetch means a network failure (or a server that omits the file) degrades to no verification with no warning. The install path then strips the quarantine attribute, so Gatekeeper never re-evaluates the copy. There is also no code-signature check (codesign/spctl) on the downloaded bundle.
- **Remediation:** Fail closed — abort install when the checksum listing can't be fetched or the entry is missing; verify the app's code signature and team identifier before replacing; drop the quarantine strip (self-downloads aren't quarantined anyway, so the strip removes defense-in-depth for nothing).

**KES-10 · Engine API key stored in a plaintext file, contradicting the Settings copy**
- **Severity:** Low
- **CWE:** CWE-922 (Insecure Storage of Sensitive Information)
- **Location:** `Sources/App/Support.swift:705-749` (engine key in `~/Library/Application Support/Kestrel/secrets/engine-api-key`, file `0600`); `Sources/Settings/SettingsTab.swift:584-585` (Settings text claims Keychain storage)
- **Description:** The engine key lives in a plaintext file (0600, machine-local — a documented tradeoff to avoid Keychain ACL prompts on ad-hoc rebuilds). User-supplied remote provider keys correctly stay in the Keychain. The Settings UI overstates the protection for the engine key, and it is shown unmasked. The containing directory is created without explicit 0700 permissions.
- **Remediation:** Create the `secrets/` directory with 0700; correct the Settings copy; optionally mask the key display.

**KES-11 · Vendor pins are environment-overridable; no advisory tracking exists**
- **Severity:** Low
- **CWE:** CWE-1357 (Reliance on Insufficiently Trustworthy/Unverifiable Component)
- **Location:** `scripts/build-engines.sh:14-16` (`LLAMA_COMMIT`/`WHISPER_COMMIT`/`SD_COMMIT` default-pinned but overridable by env; `git checkout -qf` with no hash-verified tarball); no CVE/GHSA tracking anywhere in CHANGELOG/README/docs
- **Description:** Builds pin full SHAs, but any process that can influence the build environment can substitute arbitrary vendor commits. The repo has no record of which upstream security fixes the pins include, and dist artifacts lag VERSION (v0.87.9 DMG vs 0.88.0).
- **Remediation:** In CI, pass the pins explicitly and fail if env overrides are present; record advisory triage (fixed-in versions) per vendor bump; drop stale dist artifacts from the repo.

**Infrastructure — non-findings (verified posture).** No container/orchestration layer exists (macOS desktop app; the only container mention in the repo is upstream's). The app bundle is ad-hoc or Developer-ID signed with notarization awareness (`AppCodeSignature`); file permissions on secrets are 0600; `NSAppTransportSecurity` is correctly scoped to `NSAllowsLocalNetworking` only — no `NSAllowsArbitraryLoads` (`make-app.sh:177-179`). Model downloads are sha256-verified against a checksums listing. Scripts download only from upstream repos at pinned commits.

### Client layer (vendored components and bundled web UI)

**KES-12 · CVE-2024-21616 is not applicable — it is a Juniper Junos OS vulnerability**
- **Severity:** Informational (no defect in Kestrel)
- **Reference:** CVE-2024-21616 — Juniper Networks Junos OS, SIP ALG improper input validation (MX/SRX Series), published 2024-01-10 (MITRE record verified)
- **Description:** The assessment brief asked to check the "Kestrel-AIEngine SDK" for CVE-2024-21616. That CVE belongs to Juniper routers/firewalls and has no relationship to llama.cpp, whisper.cpp, or any Kestrel component. No Kestrel SDK exists in this repository either. Citing it as a Kestrel-relevant CVE would be a false positive.

**KES-13 · Vendored llama.cpp is current and includes all published security fixes**
- **Severity:** None (positive finding)
- **Location:** `vendor/llama.cpp` @ `cdc06426e70c23a1ac2bce40c85b252fec344702` (tag b11172, 2026-09-24, full 16,847-commit history present)
- **Description:** All 13 published llama.cpp advisories (CVE-2024-32878 through CVE-2026-34159, published 2024-04 to 2026-03) predate the vendored commit. The GGUF-parser integer-overflow guards from CVE-2025-53630 / CVE-2026-27940 / CVE-2026-33298 were verified present in the vendored `ggml/src/gguf.cpp` (SIZE_MAX checks at lines 284, 291, 525, 536, 741, 795-838). The critical RPC-backend RCEs (CVE-2026-34159, CVE-2024-42479/78) are not compiled in — the build is Metal-only with no `-DGGML_RPC` (`scripts/build-engines.sh:111-138`). Residual risk: malicious GGUF model files from untrusted sources remain the inherent trust boundary; the pinned tree mitigates all *known* parser bugs only.
- **Remediation:** Track upstream advisories on each vendor bump (add a triage note to CHANGELOG); prefer model sources that publish checksums (already enforced).

**KES-14 · Whisper.cpp is held one minor behind latest for patch compatibility**
- **Severity:** Low
- **Location:** `vendor/whisper.cpp` @ `371b5a7` (v1.9.3); pin rationale documented at `scripts/build-engines.sh:15` (v1.9.5 moved ggml-metal layout, breaking the shared-metal patch series); no published whisper.cpp security advisories exist as of this assessment
- **Description:** The pin trades currency for patch-series compatibility. No known CVEs affect v1.9.3 today, but the same layout conflict will recur and may one day block a security fix.
- **Remediation:** Rebase the shared-metal patch series onto the current whisper.cpp layout at the next vendor bump; re-run advisory triage at that point. (stable-diffusion.cpp @ `241518b3` and the bundled SvelteKit web UI with Workbox 7.4.0 likewise show no published advisories.)

**Client layer — additional verified positives.** The model-JavaScript sandbox is well designed: WKWebView worker at a unique origin, CSP `default-src 'none'; connect-src 'none'`, fetch/XHR/WebSocket/importScripts neutralized, no FS/process bridges, 30s/8KB clamps (`Sources/Chat/JavaScriptSandboxService.swift`). Markdown rendering escapes raw HTML natively and the WebView path HTML-escapes model output with CSP and scheme-restricted anchors (`Sources/DesignSystem/Markdown.swift:254-257`, `RichContentBlocks.swift:196-299`). Remote-provider base URLs reject plaintext HTTP for non-loopback hosts (`Sources/Chat/InferenceRoutes.swift:44-45`), and provider keys are per-route Keychain items marked `ThisDeviceOnly`. Chat prompts travel via HTTP JSON bodies, never argv.

## Recommendations (prioritized)

1. **Close KES-01/KES-02 (LAN exposure):** require the API key for any non-loopback bind; add TLS or document the plaintext risk loudly in the Settings copy that offers LAN mode; stop advertising `auth: none` over Bonjour.
2. **Fix KES-03 (key in diagnostics) first among code changes:** one-line reuse of the existing `redact` helper plus a regression test. Highest impact-to-effort ratio in this report.
3. **Bound KES-05 (tool consent):** time-box or session-scope "Always allow"; carve out `exec_shell_command` from persistent consent.
4. **Add an import confirmation gate (KES-06):** show every executable, MCP command, and env delta before a settings import applies; this also blunts KES-07.
5. **Fail closed on updates (KES-09):** require a verified checksum and a valid code signature before replacing the app; drop the quarantine strip.
6. **Move remaining plaintext secrets (KES-04, KES-08, KES-10):** engine key out of argv and the archive-hook token into the Keychain; create `secrets/` with 0700.
7. **Start an advisory triage log (KES-11, KES-13, KES-14):** one CHANGELOG note per vendor bump listing which GHSAs the new pin includes; re-check whisper.cpp pin currency at the next rebase.
8. **Keep the strong parts strong:** the JS sandbox, Keychain discipline for provider keys, https-only remote routes, sha256-verified model downloads, and pinned vendor commits are all above-average for this app category; preserve them in review checklists.

**Verification gaps (what this static pass could not confirm):** runtime behavior of the bundled web UI's client-side code (minified SvelteKit/Workbox output was not audited line-by-line), the exact llama-server CORS posture toward DNS-rebinding from browser origins, and whether any downstream consumers run the app outside its default loopback posture.


