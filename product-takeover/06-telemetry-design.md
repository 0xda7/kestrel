# 06 — Opt-in Telemetry Design (privacy-preserving install metrics)

Why: the product cannot be priced, pitched to AMD/OEMs, or sponsored without
knowing the install base. SECURITY.md promises "no telemetry" — this design
keeps that promise *in spirit*: nothing is sent unless the user flips one
switch, and what is sent cannot identify a person or a conversation.

## Principles (non-negotiable)

1. **Off by default.** Settings toggle: "Share anonymous usage counts
   (helps development)". Plain-language, bilingual EN/ES like the rest.
2. **No content, ever.** No chat text, no model names' user paths, no file
   names, no free-form fields.
3. **No persistent identifier.** A random ID regenerated every 30 days,
   stored only in UserDefaults, never synced with anything.
4. **One request a day, 200 bytes.** Failure is silent and free.
5. **Open data.** Aggregates are published (a public JSON on the landing
   page) so the community sees exactly what was collected — trust is the
   product.

## The payload (complete — nothing else)

```json
{
  "day": "2026-11-16",
  "id": "b3f1c2…(random 64-bit hex, rotates monthly)",
  "os": "26.2",
  "arch": "x86_64",
  "gpu": { "vendor": "AMD", "class": "RDNA2", "vramGB": 4 },
  "cpu": { "cores": 16, "avx2": true },
  "ramGB": 32,
  "app": "0.90.1",
  "channel": "noavx2|standard",
  "engines": { "llm": 1, "image": 0, "audio": 0 },
  "sessions": 2
}
```

GPU **class** (RDNA2/GCN/Vega), not the exact model: class is what the
kernel work targets, and it is one less thing that could feel personal.
Endpoint: `POST https://northlatchlabs.com/kestrel/count` (existing domain),
plain HTTPS, no cookies, no redirects, logged raw for 90 days then deleted.

## Derived business metrics

- Installs ≈ distinct monthly ids
- Retention ≈ ids seen ≥ N days
- GPU-class distribution = the support matrix + the OEM pitch
- Version adoption = update propagation (fixes the "never updates" blind spot)

## Implementation order

1. `Sources/Telemetry/CountPing.swift` — payload builder (pure, testable:
   hardware info already exists in HardwareInfo) + URLSession POST, 5 s
   timeout, total silence on failure.
2. Settings toggle + Localization entries (EN/ES).
3. Daily Timer + "send on app quit if unsent" (one attempt per day max).
4. Server endpoint (tiny; can start as a Cloudflare Worker).
5. Public aggregates page.
6. Checks: payload builder tests (exact key set, no surprises), toggle-off
   sends nothing, monthly id rotation.

## Effort

~1–2 days of focused work. Blocks: owner decision (toggle wording + OK).
