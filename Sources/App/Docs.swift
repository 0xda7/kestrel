// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// Built-in app documentation. English only (operator directive
/// 2026-10-14): the Spanish half that used to live here was unreachable at
/// runtime once the language picker was removed.
struct DocsView: View {
    @State private var selected: Int = 0

    var body: some View {
        let sections = DocsContent.sections()
        HSplitView {
            List(0..<sections.count, id: \.self, selection: Binding(
                get: { selected }, set: { selected = $0 ?? 0 })
            ) { i in
                Label(sections[i].title, systemImage: sections[i].icon).tag(i)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 280)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(sections[selected].title).font(.title.bold())
                    RichText(text: sections[selected].body)
                        .frame(maxWidth: 700, alignment: .leading)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

struct DocSection {
    let title: String
    let icon: String
    let body: String
}

enum DocsContent {
    static func sections() -> [DocSection] { en }

    static let en: [DocSection] = [
        DocSection(title: "What is Kestrel", icon: "sparkles", body: """
Kestrel runs large language models (LLMs) **locally** on Intel Macs with AMD GPUs, using Metal acceleration. Nothing leaves your machine: no cloud, no accounts, no per-token costs.

Under the hood it uses **llama.cpp** with patches specific to discrete AMD GPUs on macOS, bundled inside the app itself — nothing else to install.

**Requirements:**
- Mac with macOS 14 or later
- AMD GPU with Metal support (tested on RX 6700 XT 12 GB)
- 16 GB RAM minimum (32 GB recommended for large MoE models)
"""),
        DocSection(title: "Quick start", icon: "play.circle", body: """
1. Go to **Models** and download one from the catalog (the app shows which ones fit your machine with color badges).
2. Press **Use** on the downloaded model — parameters adjust automatically.
3. Go to **Home** and press **Start server**.
4. Open **Chat** and talk.

Each model's badge shows compatibility:
- **Full GPU**: fits entirely in VRAM, maximum speed
- **GPU+CPU hybrid**: MoE models split between VRAM and RAM, good performance
- **Slow**: works but with limited speed
- **Won't fit**: exceeds your machine's memory
"""),
        DocSection(title: "The tabs", icon: "square.grid.2x2", body: """
**Home** — Detected hardware summary (CPU, RAM, GPU, VRAM), server control, live stats and the recommended model for your hardware.

**Chat** — Conversations with the model: persistent history, multiple chats (⌘N), system prompt, regenerate responses, copy messages and code blocks, per-message speed, attach images (vision models) and text/PDF files (up to 40 MB, with automatic OCR for scanned PDFs).

**Models** — Local models detected in `~/models` (you can change the folder in Settings), curated catalog with memory estimates for your machine, Hugging Face search and downloads with progress. You can delete models (they go to Trash).

**Benchmarks** — Measures real speed of the active model (prompt processing and generation) with your current settings. Keeps comparative history with a chart.

**Settings** — All engine parameters, savable profiles and app options. Every option has a tooltip on hover.
"""),
        DocSection(title: "MoE models & memory", icon: "memorychip", body: """
**MoE (Mixture of Experts)** models like Qwen3.6-35B-A3B have many total parameters (35B) but only activate a few per token (3B). This gives big-model quality at small-model speed.

The trick for low-VRAM GPUs is **splitting the model**:
- Attention and as many experts as fit go to **VRAM** (fast)
- The remaining experts stay in **RAM**, processed by the CPU

The **MoE experts on CPU** parameter (`--n-cpu-moe`) controls how many expert layers go to the CPU. The app calculates it automatically when you pick a model. If VRAM saturates (speed suddenly collapses), raise it; if you have VRAM headroom, lower it.

**Important**: in this mode, generation speed is limited by your **RAM bandwidth**, not the GPU. With DDR4 expect ~15-25 t/s on 35B models; DDR5 machines reach ~38 t/s with the same setup.
"""),
        DocSection(title: "Image generation", icon: "photo.on.rectangle.angled", body: """
The **Chat / Images** toggle at the top of the window switches to the image studio (beta, `stable-diffusion.cpp` engine on the same Metal stack).

**Catalog**: the app recommends a model based on your VRAM (Z-Image Turbo, Flux.2 klein, Flux.2 dev, Qwen-Image, SDXL Turbo…). Each one's badge shows whether it fits your GPU; there's a tolerance margin since macOS reports somewhat less usable VRAM than the card's physical amount.

**Main controls**: aspect ratio/size (snapped to the model's grid and capped by your VRAM), steps, CFG, seed (fix one to reproduce the same result) and output format. **Image to image**: upload a starting image and adjust Strength (low keeps the composition, high reinvents it). **Offload to CPU**: keeps weights in RAM and streams them to VRAM per stage, for large models on GPUs with limited memory (slower, but it fits).

**Parallel instances**: on Macs with several GPUs you can add extra instances, each with its own model, GPU and settings, and generate multiple variations at once from a single Generate button. Two instances on the same GPU show a warning (can hang the card on AMD GPUs).
"""),
        DocSection(title: "Parameters explained", icon: "slider.horizontal.3", body: """
**GPU layers (-ngl)** — How many layers go to VRAM. 99 = all (recommended). Any value above the model's layer count means "all".

**MoE experts on CPU** — See the MoE section.

**VRAM reserve** — Memory left free for the system. 1024 MB is safe.

**Copy weights to VRAM (--no-mmap)** — Essential on discrete GPUs: without it, weights are read over PCIe on every token and speed drops ~6×.

**Lock model in RAM (--mlock)** — Prevents macOS from swapping the model out. Useful with large MoE if you have spare RAM.

**Context** — Maximum conversation size in tokens. More context = more KV cache memory.

**KV cache keys/values (-ctk / -ctv)** — Quantization of attention memory. The best combo depends on whether you use the **AMD Flash Attention kernel**:
- **With the kernel** (how it ships): any standard combination (`f16`/`q8_0`/`q4_0` for keys and values) runs on the GPU at full speed. Maximum savings: `q8_0/q8_0` or `q4_0/q4_0`; compress only the keys while keeping value quality: `q8_0/f16` or `q4_0/f16`.
- **Without the kernel** (if you turn it off): quantize keys only — `q8_0` (half the memory at near-zero cost) or `q4_0` (a quarter), keeping values at `f16`. Quantizing values too would force Flash Attention onto the CPU (~3× slower).

**Flash Attention** — Memory-efficient attention. `auto` is right on AMD GPUs.

**AMD dGPU stability** — The bundled engine disables unsafe Metal concurrency automatically on discrete GPUs.

**CPU threads** — For the CPU-side work. Physical core count is usually optimal.
"""),
        DocSection(title: "Inference engines", icon: "engine.combustion", body: """
The app ships **two engines** and supports external ones (Settings → Advanced):

**Bundled (official)** — Official llama.cpp with AMD patches. Recommended for everything. Supports the newest architectures (Qwen 3.6, MTP).



The **AMD Flash Attention kernel** toggle runs attention — both prompt processing and generation — on the AMD GPU via a custom Metal kernel (head dims 64, 72, 128, 256 and 512 — covers Gemma 4 and the vision encoders; KV types f16, q8_0, q4_0 in any keys/values combination). It matters most with quantized KV: those types **require** Flash Attention, so without the kernel attention falls back to the CPU and collapses with depth; with it everything stays on the GPU and generation holds up with depth (e.g. ~33 t/s at 4k context on an 8B).

**External** — Any `llama-server` binary of yours, for testing custom builds.

**KestrelGEMM**, on by default, is a custom tiled matrix-multiply kernel for prompt processing on AMD GPUs; on this GPU it took an 8B's prompt speed from ~101 to ~470 t/s (~5×). It's not a toggle: it always runs when a model processes its prompt on the GPU.

For MoE models with experts in RAM (ncmoe > 0), the **MoE expert prefetch** toggle (Settings → Inference & context, on by default) raises prompt processing an additional 1.8×-4.4× on top of KestrelGEMM, at no generation cost, by overlapping weight uploads to the GPU with compute.
"""),
        DocSection(title: "Profiles", icon: "person.2", body: """
A profile saves **everything**: model, engine, memory and context parameters. Create them in Settings → Profiles by typing a name and pressing "Save current".

Typical profiles:
- **Daily**: your go-to model with its context and experts already tuned → fastest chat

After applying a profile, restart the server for it to take effect.
"""),
        DocSection(title: "Router: multiple models, no restart", icon: "arrow.triangle.2.circlepath", body: """
Turn on **Router (multi-model)** in **Home → server card → Advanced options** (not in Settings) so one server serves **all** your downloaded models at once, with no need to pick a fixed one.

How it works: the server loads a model the first time it's requested (by name) and keeps it in memory; requesting a different one unloads the previous model and loads the new one automatically. **Models loaded at once** controls how many it keeps resident (1 is safest on a single GPU).

Inside the app, chat shows a model picker (box icon) next to the message field when the router is on. From an external client (VS Code, Continue…), just put the model's name in the request's `model` field; the app derives that name from the .gguf filename (e.g. `Qwen3.6-14B-A3B.gguf` → `qwen3-6-14b-a3b`), which you can check via `GET /v1/models`.

Each model keeps its own MoE experts, vision and MTP config, computed automatically.
"""),
        DocSection(title: "MTP: faster generation", icon: "hare", body: """
**MTP (Multi-Token Prediction)** is a technique where the model predicts several tokens per pass and then verifies them — with zero quality loss (it only accepts what it would have generated anyway).

Last measurement on this machine: **+34% generation speed** (19.3 → 25.7 t/s on Qwen3.6-35B) with 82% acceptance. That figure predates the persistent-staging fix, which alone already raised the "without MTP" baseline from ~19 to ~25 t/s. MTP's real gain over the current engine still needs re-measuring.

You need a GGUF with the MTP head: look for repos with "MTP" in the name, e.g. unsloth's `Qwen3.6-35B-A3B-MTP-GGUF`, since regular GGUFs don't include it.

There is nothing to switch on. MTP engages by itself whenever the GGUF ships the head, for both dense and MoE models. `llama-bench` can't measure it: always compare using real generation from chat or the server.
"""),
        DocSection(title: "API for developers", icon: "terminal", body: """
With the server running, you get an **OpenAI-compatible API** at `http://127.0.0.1:8080` (configurable port). Works with any library or app that speaks the protocol.

By default it only accepts connections from this Mac. To expose the local API on the network, enable **Discoverable on local network** in Settings and restart the server. Kestrel will listen on all interfaces and advertise `Kestrel API` through Bonjour. Connect to `http://<Mac-IP>:8080/v1`, and enable **Protect the API with a key** before exposing it, especially outside a trusted network.

Example with curl:

```bash
curl http://127.0.0.1:8080/v1/chat/completions \\
  -H "Content-Type: application/json" \\
  -d '{
    "messages": [{"role": "user", "content": "Hello"}],
    "stream": true,
    "temperature": 0.7
  }'
```

Example with Python (the official `openai` library, just pointing it at the local base URL):

```python
from openai import OpenAI

client = OpenAI(base_url="http://127.0.0.1:8080/v1", api_key="not-needed")
stream = client.chat.completions.create(
    model="local",  # ignored unless Router mode is on, see that section
    messages=[{"role": "user", "content": "Hello"}],
    stream=True,
)
for chunk in stream:
    print(chunk.choices[0].delta.content or "", end="")
```

**Streaming (SSE):** with `"stream": true`, each line arrives as `data: {...}` with an incremental delta (`choices[0].delta.content`); the end is marked by `data: [DONE]`. With reasoning models, thinking arrives in `delta.reasoning_content` (a separate field, never mixed into `content`) unless you enable "Reasoning as plain text" in Settings, which inlines it into `content` between `<think>` tags instead.

Useful endpoints:
- `POST /v1/chat/completions` — chat (optional streaming)
- `POST /v1/completions` — plain text completion (no chat template)
- `POST /v1/embeddings` — embedding vectors, if you enabled **Embeddings server** (Home → server card → Advanced options; use it with a dedicated embedding model, not a chat one)
- `GET /v1/models` — loaded model(s) and advertised capabilities
- `POST /tokenize` / `POST /detokenize` — convert text ↔ token ids for the active model
- `GET /health` — server status
- `GET /props` — model metadata (context size, chat template, etc.)

**Images / vision:** load a model with its `mmproj` and send OpenAI `image_url` content (a remote URL or `data:image/...;base64,...`). Configurable clients such as Raycast must also declare that the model supports vision. Use the model `id` returned by `/v1/models`. While an `mmproj` is loaded, Kestrel disables cache-reuse and persistent conversation caching because `llama.cpp` cannot save/restore multimodal slots; normal in-memory prompt caching remains enabled.

There's also a minimal web chat at the root (`http://127.0.0.1:8080`) for browser use.

**Concurrent requests:** the setting of the same name (Settings → Inference & context) controls how many concurrent requests the server accepts. At 1 (the default), requests queue instead of competing for the GPU, and a request cut off by a timeout resumes processing where it stopped on the next attempt.

#### Connecting external clients

Any OpenAI-compatible client (VS Code + Continue/Cline/Copilot with a custom model, and generally almost everything else):
- Base URL: `http://127.0.0.1:8080/v1` · model name: the `id` from `/v1/models` · API key: the one in Settings only if you enabled protection.
- **Raise Context to 32k or more**: these clients send huge prompts (instructions + open files) and at 16k the server rejects the request. Offset the memory by quantizing KV cache keys to `q8_0`.
- Reasoning models "think" before answering and many clients don't display that phase: it **looks hung** while it's actually generating. Enable "Reasoning as plain text" in Settings → Inference, or use a non-reasoning model for coding.
- The **first response takes a while**: on this class of GPU prompts process at ~80-120 t/s, so 16k tokens take 2-4 minutes. **Limit the client's input tokens** (e.g. `maxInputTokens: 8000`) so the first request drops to ~1-2 min; later ones reuse the cache and are incremental.
- If the client times out, retry: with "Concurrent requests" at 1 (the default), the retry **resumes processing where it stopped** instead of starting over.
- **Need to switch models without restarting the server?** Turn on Router mode (see "Router: multiple models, no restart") and put whichever model name you want in each request.

##### OpenCode (CLI)
- Edit `~/.config/opencode/opencode.json` (or the project's `opencode.json`) and add a provider with `"npm": "@ai-sdk/openai-compatible"` and `"options": {"baseURL": "http://127.0.0.1:8080/v1"}`.
- You can also run `/connect` inside OpenCode and pick "Other".
- Restart OpenCode after editing the config; model names must match the `id` from `/v1/models` exactly.

##### Google Antigravity
- Settings → Custom Models → add one with provider **OpenAI Compatible**.
- Endpoint: `http://127.0.0.1:8080/v1` · model: the `id` from `/v1/models`.

##### Cursor
- Settings (⌘,) → Models tab → OpenAI section → enable **Override Base URL** and paste `http://127.0.0.1:8080/v1`.
- The API key field can't be empty (type anything if you didn't protect the API).
- **A real Cursor limitation, not Kestrel's**: it requires HTTPS for that URL. A plain local HTTP endpoint won't connect directly, you'll need a TLS proxy in front (e.g. Caddy or an ngrok-style tunnel) pointing at `127.0.0.1:8080`.

##### Raycast
- Settings → AI → Custom Providers.
- Base URL: `http://127.0.0.1:8080/v1` · model: the `id` from `/v1/models`.
- For images, see the vision note above.

##### Anthropic API clients
Terminal agents and SDKs built on the Anthropic format, not just OpenAI's. The engine also implements native `/v1/messages`, including streaming and tool calls.
- Most of these clients redirect via two standard SDK environment variables: `ANTHROPIC_BASE_URL=http://127.0.0.1:8080` and `ANTHROPIC_AUTH_TOKEN=any-text` (or the real key if you enabled protection).
- The server accepts both `Authorization: Bearer` and `x-api-key`, the header these clients use.
- Check your client's docs for its exact config file name; many only read those variables at startup, so restart it after changing them.
"""),
        DocSection(title: "Reference performance", icon: "gauge.high", body: """
Numbers measured on the development machine (RX 6700 XT 12 GB, DDR4, macOS):

**Qwen3-8B Q4** (fully in VRAM, with KestrelGEMM): ~476 t/s prompt, ~60 t/s generation

**Qwen3.6-35B-A3B Q4** (hybrid MoE, ncmoe 24):
- Normal: ~197 t/s prompt, ~25 t/s generation
- With MoE expert prefetch: ~470 t/s prompt (2.4×), generation unchanged
- With MTP: not re-measured since the KestrelGEMM/staging fixes; the last measurement (+34%, 19.3→25.7 t/s) predates those and isn't comparable to the "Normal" line above anymore

Hybrid MoE generation is RAM-bandwidth-bound: a faster GPU won't improve it, but DDR5 RAM will (up to ~2×).
"""),
        DocSection(title: "Troubleshooting", icon: "wrench.and.screwdriver", body: """
**macOS blocks the app on install** — From 0.86.5 releases are signed and notarized by Apple, so they open straight away. Coming from an earlier one: System Settings → Privacy & Security, then "Open Anyway".

**Output is gibberish** — Save the server log and report the model, quantization and GPU; the bundled engine already applies the discrete-GPU safety mode.

**Very slow (2-8 t/s)** — Enable "Copy weights to VRAM (--no-mmap)". If already on, VRAM may be saturated: raise "MoE experts on CPU" a couple of layers.

**Speed suddenly collapses** — VRAM overflow. Raise ncmoe or reduce context.

**Model won't load** — May be an architecture too new for the engine. Try the Bundled engine (it's the most up to date). "MTP" variants require recent engines.

**Error with quantized KV values** — Quantized values require Flash Attention `on`. On AMD GPUs that reduces speed; consider whether you need it.

**Server ignores new settings** — Changes apply on server restart (Stop → Start).

**Speed degrades over time / the engine reaches 25-30 GB of RAM** — Two causes add up: context grows with the conversation (normal, auto-compaction mitigates it) and the engine keeps a prompt cache in RAM that grows with use. Cap "Prompt cache in RAM" in Settings (2 GB by default) and, if you have headroom, enable --mlock so the model never falls into swap.

**It hangs "thinking" from VS Code or another client** — The model is reasoning or processing a huge prompt; the client doesn't display that phase. See the "API for developers" section.
"""),
        DocSection(title: "Credits & licenses", icon: "heart", body: """
Kestrel is developed by **Northlatch Labs** ([@Northlatch-Labs-LLC](https://github.com/Northlatch-Labs-LLC)).

Built on the work of:
- **llama.cpp** (ggml-org) — the inference engine
- **iRon-Llama** (Basten7) — Metal patch research for AMD GPUs on Intel Macs

If the app is useful to you, you can support development from **About → Donate**.
"""),
    ]
}
