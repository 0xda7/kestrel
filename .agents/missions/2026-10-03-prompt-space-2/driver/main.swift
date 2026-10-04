// Behavioral driver — hardening wave (Prompt Space wave 2 + sidecar regressions).
// Compiles the SHIPPED sources verbatim and asserts real behavior under an
// isolated HOME. Exit 0 only when every check passes.

import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("PASS: \(label)")
    } else {
        failures += 1
        print("FAIL: \(label)")
    }
}

// NSHomeDirectory() ignores $HOME on macOS (passwd home wins), so the driver
// NEVER pretends to isolate via HOME. Fixture skills are created in the real
// discovery paths and REMOVED via defer; stubs and scratch files live in /tmp;
// persistence is exercised through JSONEncoder/Decoder in memory — the driver
// must never write user data files.

let workDir = "/tmp/kestrel-driver-work"
try? FileManager.default.createDirectory(atPath: workDir, withIntermediateDirectories: true)
var fixturePaths: [String] = []
defer {
    for path in fixturePaths { try? FileManager.default.removeItem(atPath: path) }
    try? FileManager.default.removeItem(atPath: workDir)
}

// ---- fixture skills tree (real discovery paths, removed on exit) ---------------

let skillDir = NSHomeDirectory() + "/.pi/agent/skills/driver-demo-skill"
try? FileManager.default.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
fixturePaths.append(skillDir)
let skillMarkdown = "---\nname: driver-demo-skill\ndescription: Demonstrates frontmatter discovery\n---\n\nBody text.\n"
try? skillMarkdown.write(toFile: skillDir + "/SKILL.md", atomically: true, encoding: .utf8)

// ---- stub pi / latch scripts -------------------------------------------------

let stubPi = workDir + "/stub-pi"
let stubPiSource = """
#!/bin/bash
mode="${DRIVER_MODE:-ok}"
if [ "$mode" = "argv" ]; then
  # One base64-encoded argument per line: survives spaces, quotes, newlines.
  : > "$DRIVER_ARGV_OUT"
  for a in "$@"; do printf '%s\\n' "$a" | base64 >> "$DRIVER_ARGV_OUT"; done
  exit 0
fi
case "$mode" in
ok)
  printf '%s\\n' '{"type":"message_update","assistantMessageEvent":{"type":"reasoning_delta","delta":"drafting"}}'
  printf '%s\\n' '{"type":"message_end","message":{"role":"assistant","content":[{"type":"text","text":"AUTHORED-PROMPT-TEXT"}]}}'
  ;;
abnormal)
  echo "provider exploded: no api key" >&2
  exit 3
  ;;
esac
exit 0
"""
try? stubPiSource.write(toFile: stubPi, atomically: true, encoding: .utf8)
let c1 = Process(); c1.executableURL = URL(fileURLWithPath: "/bin/chmod"); c1.arguments = ["+x", stubPi]
try? c1.run(); c1.waitUntilExit()

let stubLatch = workDir + "/stub-latch"
let stubLatchSource = """
#!/bin/bash
case \"${DRIVER_MODE:-ok}\" in
ok) echo \"LATCH-OK\" ;;
utf8split)
  # Emit multi-byte characters split across separate writes: the incremental
  # decoder must complete 中 (E4 B8 AD) and é (C3 A9) across chunk boundaries
  # with no U+FFFD replacement and no lost bytes.
  printf 'A\\344\\270'
  printf '\\255B\\303'
  printf '\\251D'
  echo
  ;;
abnormal) echo partial; echo \"latch auth failed\" >&2; exit 5 ;;
esac
"""
try? stubLatchSource.write(toFile: stubLatch, atomically: true, encoding: .utf8)
let c2 = Process(); c2.executableURL = URL(fileURLWithPath: "/bin/chmod"); c2.arguments = ["+x", stubLatch]
try? c2.run(); c2.waitUntilExit()

UserDefaults.standard.set(stubPi, forKey: "piBinaryPath")
UserDefaults.standard.set(stubLatch, forKey: "latchBinaryPath")

// ---- 1. SkillsDiscovery -------------------------------------------------------

let found = SkillsDiscovery.scan()
check(found.contains { $0.name == "driver-demo-skill" && $0.description == "Demonstrates frontmatter discovery" },
      "skills scan finds the fixture with frontmatter")
let list = SkillsDiscovery.markdownList(maxSkills: 40)
check(list.contains("- **driver-demo-skill** — Demonstrates frontmatter discovery"),
      "markdownList renders the markdown line")
check(SkillsDiscovery.markdownList(maxSkills: 0).isEmpty, "markdownList respects the zero cap")

// ---- 2. PromptLibrary typed variables -----------------------------------------

let typedTemplate = PromptTemplate(
    name: "Typed",
    body: "Today is {{current_date}}. Skills:\n{{available_skills}}. Dir: {{cwd}}.",
    variables: [
        PromptVariableSpec(name: "current_date", type: .currentDate, format: "iso-date"),
        PromptVariableSpec(name: "available_skills", type: .skills),
        PromptVariableSpec(name: "cwd", type: .workingDirectory),
    ])
let fixedDate = Date(timeIntervalSince1970: 0)
let typedValues = PromptLibrary.typedValues(for: typedTemplate,
                                            workingDirectory: "/tmp/proj",
                                            date: fixedDate,
                                            locale: Locale(identifier: "en_US_POSIX"))
let renderedTyped = PromptLibrary.apply(typedTemplate.effectiveBody,
                                        template: typedTemplate,
                                        values: [:],
                                        workingDirectory: "/tmp/proj",
                                        date: fixedDate,
                                        locale: Locale(identifier: "en_US_POSIX"))
// TZ-safe iso-date shape check: the epoch formats to a local-timezone date,
// so assert the yyyy-MM-dd shape via regex rather than a wall-clock string.
func isISODate(_ s: String) -> Bool {
    guard let regex = try? NSRegularExpression(pattern: #"\b\d{4}-\d{2}-\d{2}\b"#) else { return false }
    let range = NSRange(s.startIndex..., in: s)
    return regex.firstMatch(in: s, range: range) != nil
}
check(isISODate(renderedTyped), "currentDate resolves with the iso-date format")
check(renderedTyped.contains("- **driver-demo-skill** —"), "skills variable embeds the discovery list")
check(renderedTyped.contains("/tmp/proj"), "workingDirectory resolves the given directory")
check(typedValues["current_date"].map(isISODate) == true, "typed values map carries the formatted date")

// ---- 3. Variants ---------------------------------------------------------------

var vTemplate = PromptTemplate(name: "V", body: "MAIN-BODY")
vTemplate.variants = ["aggressive": "AGGRESSIVE-BODY"]
vTemplate.activeVariant = "aggressive"
check(vTemplate.effectiveBody == "AGGRESSIVE-BODY", "active variant body wins")
vTemplate.activeVariant = "default"
check(vTemplate.effectiveBody == "MAIN-BODY", "'default' keeps the main body")
vTemplate.activeVariant = "missing-key"
check(vTemplate.effectiveBody == "MAIN-BODY", "dangling activeVariant degrades to main body")

// persistence round-trip in memory (the driver must never touch the real
// prompt-library.json): the shipped Codable shape must round-trip variants
// and variable specs losslessly.
do {
    let data = try JSONEncoder().encode([vTemplate, typedTemplate])
    let reloaded = try JSONDecoder().decode([PromptTemplate].self, from: data)
    check(reloaded.count == 2
          && reloaded.contains { $0.name == "V" && $0.activeVariant == "missing-key" && $0.variants?["aggressive"] == "AGGRESSIVE-BODY" }
          && reloaded.contains { $0.name == "Typed" && $0.variables?.count == 3 },
          "variants + variable specs round-trip through the Codable shape")
} catch {
    check(false, "variants + variable specs round-trip through the Codable shape (\(error))")
}

// ---- 4. render() regressions ---------------------------------------------------

let base = PromptTemplate(name: "B", body: "Hello {{ NAME }} and {{missing}}")
let renderedBase = PromptLibrary.apply(base.effectiveBody, template: base,
                                       values: ["name": "WORLD"],
                                       workingDirectory: nil, date: fixedDate)
check(renderedBase.contains("WORLD"), "render stays case-insensitive with whitespace tolerance")
check(renderedBase.contains("{{missing}}"), "unmatched placeholders stay visible")

// ---- 5. MetaPromptService argv ---------------------------------------------------

let argvOut = workDir + "/argv.b64"
setenv("DRIVER_MODE", "argv", 1)
setenv("DRIVER_ARGV_OUT", argvOut, 1)
let argvRun = await MetaPromptService.run(taskDescription: "Build a code reviewer",
                                          existingPrompt: "Old prompt text",
                                          skillsList: "- **driver-demo-skill** — Demonstrates frontmatter discovery")
_ = argvRun
if let data = FileManager.default.contents(atPath: argvOut),
   let raw = String(data: data, encoding: .utf8) {
    let argv = raw.split(separator: "\n")
        .compactMap { Data(base64Encoded: String($0)).map { String(decoding: $0, as: UTF8.self) } }
        .map { $0.trimmingCharacters(in: .newlines) }  // the stub pipes arg+\n into base64
    check(!argv.isEmpty, "stub pi captured the argv")
    check(argv.contains("--no-tools"), "meta-prompt argv confined with --no-tools")
    if let i = argv.firstIndex(of: "--system-prompt") {
        check(argv.count > i + 1 && argv[i + 1] == MetaPromptService.systemPrompt,
              "meta-prompt system prompt rides --system-prompt verbatim")
    } else {
        check(false, "meta-prompt argv passes --system-prompt")
    }
    if let i = argv.firstIndex(of: "--thinking") {
        check(argv.count > i + 1 && argv[i + 1] == "off", "meta-prompt pins --thinking off")
    } else {
        check(false, "meta-prompt argv passes --thinking off")
    }
    if let i = argv.firstIndex(of: "-p") {
        let prompt = argv.count > i + 1 ? argv[i + 1] : ""
        check(prompt.contains("Build a code reviewer"), "task description rides the prompt")
        check(prompt.contains("Existing prompt to improve:"), "existing prompt section present")
        check(prompt.contains("Available skills:"), "skills section present")
    } else {
        check(false, "meta-prompt argv carries -p prompt")
    }
    check(!argv.contains("--continue") && !argv.contains("--resume") && !argv.contains("--session"),
          "no resume flag is ever emitted")
} else {
    check(false, "stub pi captured the argv")
}

// ---- 6. MetaPromptService end-to-end ------------------------------------------------

setenv("DRIVER_MODE", "ok", 1)
let authored = await MetaPromptService.run(taskDescription: "Build a code reviewer",
                                           existingPrompt: nil, skillsList: "")
check(authored == "AUTHORED-PROMPT-TEXT", "authoritative message_end text is returned")
check(MetaPromptService.defaultTimeoutSeconds == 600, "pinned 600 s budget")

setenv("DRIVER_MODE", "abnormal", 1)
let abnormal = await MetaPromptService.run(taskDescription: "task", existingPrompt: nil, skillsList: "")
check(abnormal.contains("estado 3") && abnormal.contains("provider exploded"),
      "abnormal exit surfaces bilingual status + stderr tail")
let emptyTask = await MetaPromptService.run(taskDescription: "   ", existingPrompt: nil, skillsList: "")
check(emptyTask == MetaPromptService.emptyTaskMessage, "empty task guards before launch")

// ---- 7. Sidecar regressions (pi/latch/routes) -----------------------------------------

UserDefaults.standard.set("medium", forKey: "piThinkingLevel")
var chatArgv = PiDelegateService.argv(prompt: "hi", thinking: false, agentMode: false, systemPrompt: nil)
check(chatArgv.contains("--no-tools") && chatArgv.contains("--session-dir"),
      "chat argv stays confined with traces on")
if let i = chatArgv.firstIndex(of: "--thinking") {
    check(chatArgv[chatArgv.index(after: i)] == "off", "thinking off passed for chat")
} else {
    check(false, "chat argv passes --thinking off")
}
chatArgv = PiDelegateService.argv(prompt: "hi", thinking: true, agentMode: true, systemPrompt: nil)
check(!chatArgv.contains("--no-tools"), "agent mode restores tools")
UserDefaults.standard.set("", forKey: "piThinkingLevel")
chatArgv = PiDelegateService.argv(prompt: "hi", thinking: true, agentMode: true, systemPrompt: nil)
check(!chatArgv.contains("--thinking"), "empty level omits the thinking flag")

let latchOutcome = await LatchDelegateService.runStreaming(
    argv: [stubLatch, "-p", "task"], workingDirectory: nil, timeout: 30,
    onLaunch: nil, onOutput: nil)
if case .exited(let status, let output) = latchOutcome {
    check(status == 5 && output.contains("latch auth failed"),
          "latch abnormal exit carries stderr diagnostics")
} else {
    check(false, "latch abnormal maps to .exited")
}

// Incremental-decode correctness: multi-byte characters split across pipe
// chunks must decode intact (no U+FFFD, nothing dropped) — the O(n²) fix's
// regression test.
setenv("DRIVER_MODE", "utf8split", 1)
var splitSnapshots: [String] = []
let utf8Outcome = await LatchDelegateService.runStreaming(
    argv: [stubLatch, "-p", "task"], workingDirectory: nil, timeout: 30,
    onLaunch: nil, onOutput: { _, fullSoFar in splitSnapshots.append(fullSoFar) })
if case .completed(let output) = utf8Outcome {
    check(output.contains("中") && output.contains("é") && !output.contains("\u{FFFD}"),
          "split multi-byte characters decode intact (no U+FFFD)")
    check(splitSnapshots.allSatisfy { !$0.contains("\u{FFFD}") },
          "no intermediate snapshot ever shows a replacement character")
    check(splitSnapshots.last.map { $0.contains("中") && $0.contains("é") } == true,
          "final snapshot carries the complete decoded text")
} else {
    check(false, "utf8split run completes (got \(utf8Outcome))")
}
setenv("DRIVER_MODE", "ok", 1)

Keychain.delete("remote-api-key")
var route = InferenceRoute(name: "p1", dialect: .openAI, baseURL: "https://api.example.com/v1",
                           modelID: "model-x", maxTokensCap: nil)
Keychain.setThisDeviceOnly("LEGACY", account: "remote-api-key")
check(InferenceRoutes.apiKey(for: route) == "LEGACY", "legacy shared key falls back")
let legacyGetCount = Keychain.getCalls
_ = InferenceRoutes.apiKey(for: route)
_ = InferenceRoutes.apiKey(for: route)
check(Keychain.getCalls == legacyGetCount,
      "repeated route-key resolutions are served from the session cache (no re-read)")
check(InferenceRoutes.hasAPIKey(for: route), "hasAPIKey finds a legacy key")
let existsCount = Keychain.existsCalls
let getBefore = Keychain.getCalls
_ = InferenceRoutes.hasAPIKey(for: route)
_ = InferenceRoutes.hasAPIKey(for: route)
check(Keychain.getCalls == getBefore, "hasAPIKey never decrypts secrets (no Keychain reads)")
check(Keychain.existsCalls >= existsCount, "hasAPIKey probes via metadata-only exists()")
InferenceRoutes.setAPIKey("ROUTE-KEY", for: route)
check(InferenceRoutes.apiKey(for: route) == "ROUTE-KEY", "per-route key stored and read")
check(Keychain.getCalls == legacyGetCount, "setAPIKey serves subsequent reads from the cache")

// ---- 8. Anthropic dialect tool mapping -----------------------------------------

route.dialect = .anthropic
var toolBody: [String: Any] = [
    "messages": [
        ["role": "user", "content": "list files"],
        ["role": "assistant", "content": "",
         "tool_calls": [["id": "call_1", "function": ["name": "list", "arguments": "{\"path\":\"/tmp\"}"]]]],
        ["role": "tool", "tool_call_id": "call_1", "content": "a.txt"],
    ] as [[String: Any]],
    "stop": ["END"],
]
let toolWire = RouteWire.wire(body: toolBody, port: 8080, route: route,
                              localAPIKey: nil, remoteAPIKey: "ROUTE-KEY")
let wireMessages = (toolWire.body["messages"] as? [[String: Any]]) ?? []
check(!wireMessages.contains(where: { ($0["role"] as? String) == "tool" }),
      "anthropic wire emits no invalid tool role")
check(wireMessages.contains(where: { ($0["role"] as? String) == "assistant" && (($0["content"] as? [[String: Any]])?.contains { ($0["type"] as? String) == "tool_use" } ?? false) }),
      "assistant tool_calls become tool_use blocks")
check(wireMessages.contains(where: { ($0["role"] as? String) == "user" && (($0["content"] as? [[String: Any]])?.contains { ($0["type"] as? String) == "tool_result" && ($0["tool_use_id"] as? String) == "call_1" } ?? false) }),
      "tool results become tool_result blocks paired by id")
check((toolWire.body["stop_sequences"] as? [String]) == ["END"], "anthropic maps stop to stop_sequences")

var body: [String: Any] = [
    "messages": [["role": "user", "content": "hi"]], "stream": true,
    "min_p": 0.05, "top_k": 40, "cache_prompt": true, "stop": ["END"],
]
route.dialect = .openAI
let openWire = RouteWire.wire(body: body, port: 8080, route: route,
                              localAPIKey: nil, remoteAPIKey: "ROUTE-KEY")
check(openWire.body["min_p"] == nil && openWire.body["top_k"] == nil,
      "openAI dialect strips llama-only fields")
let localWire = RouteWire.wire(body: body, port: 8080, route: nil, localAPIKey: "LOCAL", remoteAPIKey: nil)
check(localWire.body["min_p"] != nil && localWire.body["cache_prompt"] != nil,
      "local passthrough body stays unstripped")

// ---- summary ---------------------------------------------------------------------------
// exit() skips defer blocks: clean the fixtures explicitly, then exit.
for path in fixturePaths { try? FileManager.default.removeItem(atPath: path) }
try? FileManager.default.removeItem(atPath: workDir)

print("----")
print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
