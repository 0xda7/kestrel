#!/usr/bin/env python3
"""A3 scope rebrand: case-explicit, count-verified replacements.

Rules honored:
- TOSH_* env names NEVER change.
- Hackintosh / Hackintoshes / notesToShow are false positives (contain 'tosh'
  as substring of unrelated words) - never touched.
- Every pattern lists the file, exact old string, exact new string, and the
  expected number of occurrences. The script hard-fails on any mismatch.
- Header lines handled exactly; trailing newline preserved via full-text ops.
"""
import sys, pathlib

ROOT = pathlib.Path("/Users/admin/KimiK3_Nvidia/toshllm-main")

HDR1_OLD = "// ToshLLM - run LLMs locally on Intel Macs with AMD GPUs"
HDR1_NEW = "// Kestrel - run LLMs locally on Intel Macs with AMD GPUs"
HDR2_OLD = "// Copyright (C) 2026 Engelbert Delgado <engeldlgado@gmail.com>"
HDR2_NEW = "// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>"

# Per-file, case-explicit, count-checked replacements (beyond the two headers).
EDITS = {
    "Sources/Models/Updates.swift": [
        ('https://api.github.com/repos/engeldlgado/toshllm/releases/latest',
         'https://api.github.com/repos/northlatchlabs/kestrel/releases/latest', 1),
        ('https://api.github.com/repos/engeldlgado/toshllm/releases?per_page=30',
         'https://api.github.com/repos/northlatchlabs/kestrel/releases?per_page=30', 1),
        ('https://github.com/engeldlgado/toshllm/releases/tag/',
         'https://github.com/northlatchlabs/kestrel/releases/tag/', 1),
    ],
    "Sources/Models/ModelFileIndex.swift": [
        ("ToshLLM's managed media folders", "Kestrel's managed media folders", 1),
    ],
    "Sources/Models/LocalModelDetailsSheet.swift": [
        ('loc.t("Descargado con ToshLLM", "Downloaded with ToshLLM")',
         'loc.t("Descargado con Kestrel", "Downloaded with Kestrel")', 1),
    ],
    "Sources/Benchmarks/Benchmark.swift": [
        ("=== ToshLLM benchmark \u00b7 ", "=== Kestrel benchmark \u00b7 ", 1),
        ('"toshllm-sweep-\\(UUID().uuidString).log"', '"kestrel-sweep-\\(UUID().uuidString).log"', 1),
    ],
    "Sources/Benchmarks/BenchmarksTab.swift": [
        ('loc.t("Publica una medici\u00f3n verificable en toshllm.com",',
         'loc.t("Publica una medici\u00f3n verificable en northlatchlabs.com/kestrel",', 1),
        ('"Publish a verifiable measurement on toshllm.com"))',
         '"Publish a verifiable measurement on northlatchlabs.com/kestrel"))', 1),
        ('loc.t("Versi\u00f3n de ToshLLM que hizo esta medici\u00f3n",',
         'loc.t("Versi\u00f3n de Kestrel que hizo esta medici\u00f3n",', 2),
        ('"ToshLLM version that produced this run"))',
         '"Kestrel version that produced this run"))', 2),
    ],
    "Sources/Benchmarks/BenchmarkComparisonCard.swift": [
        ("ToshDropdown", "KestrelDropdown", 3),
    ],
    "Sources/Benchmarks/BenchmarkSharing.swift": [
        ('static let baseURL = "https://toshllm.com"',
         'static let baseURL = "https://northlatchlabs.com/kestrel"', 1),
        ('private static let bundleID = "dev.engel.toshllm"',
         'private static let bundleID = "com.northlatchlabs.kestrel"', 1),
        ('"engineVersion": "ToshLLM \\(AppInfo.version)"',
         '"engineVersion": "Kestrel \\(AppInfo.version)"', 1),
        ('Data("toshllm-benchmark-v2\\n', 'Data("kestrel-benchmark-v2\\n', 1),
        ('"toshllm-benchmark-\\(UUID().uuidString).log"',
         '"kestrel-benchmark-\\(UUID().uuidString).log"', 1),
    ],
    "Sources/Benchmarks/BenchmarkShareCard.swift": [
        ("ToshLLM nunca recibe tu contrase\u00f1a.", "Kestrel nunca recibe tu contrase\u00f1a.", 1),
        ("ToshLLM never receives your password.", "Kestrel never receives your password.", 1),
    ],
    "Sources/Benchmarks/BenchmarkShareReviewSheet.swift": [
        ('loc.t("ToshLLM no incluye chats, prompts, nombres de cuenta ni rutas locales.',
         'loc.t("Kestrel no incluye chats, prompts, nombres de cuenta ni rutas locales.', 1),
        ('"ToshLLM does not include chats, prompts, account names, or local paths.',
         '"Kestrel does not include chats, prompts, account names, or local paths.', 1),
    ],
    "Sources/Images/ImageGen.swift": [
        ('return NSString(string: "~/dev/repositorios/toshllm/vendor/stable-diffusion.cpp/build-static/bin/sd-cli")',
         'return NSString(string: "~/dev/repositorios/kestrel/vendor/stable-diffusion.cpp/build-static/bin/sd-cli")', 1),
        ('dir.appendingPathComponent("toshllm_\\(fmt.string(from: Date()))_\\(token).\\(format.ext)")',
         'dir.appendingPathComponent("kestrel_\\(fmt.string(from: Date()))_\\(token).\\(format.ext)")', 1),
        ('.appendingPathComponent("toshllm-preview-\\(token).png")',
         '.appendingPathComponent("kestrel-preview-\\(token).png")', 1),
        ("/// Deletes generated outputs (`toshllm_*`) from the imagen folder, when the",
         "/// Deletes generated outputs (`kestrel_*`) from the imagen folder, when the", 1),
        ('guard name.hasPrefix("toshllm_"), !name.contains("-x2"), !name.contains("-x4") else { continue }',
         'guard name.hasPrefix("kestrel_"), !name.contains("-x2"), !name.contains("-x4") else { continue }', 1),
    ],
    "Sources/Images/ImageGenTab.swift": [
        ("(toshllm_*) de la carpeta de salida", "(kestrel_*) de la carpeta de salida", 1),
        ("(toshllm_*) from the output folder", "(kestrel_*) from the output folder", 1),
        ('panel.nameFieldStringValue = "toshllm.\\(format.ext)"',
         'panel.nameFieldStringValue = "kestrel.\\(format.ext)"', 1),
    ],
    "Sources/Audio/AudioControls.swift": [
        ("ToshLLM extrae el audio localmente sin modificar el original.",
         "Kestrel extrae el audio localmente sin modificar el original.", 1),
        ("ToshLLM extracts audio locally without changing the original.",
         "Kestrel extracts audio locally without changing the original.", 1),
        ("ToshDropdown", "KestrelDropdown", 2),
        ('static let customValue = "__toshllm_custom_language__"',
         'static let customValue = "__kestrel_custom_language__"', 1),
    ],
    "Sources/Audio/AudioCanvas.swift": [
        ('panel.nameFieldStringValue = "\\(base).tosh-audio.json"',
         'panel.nameFieldStringValue = "\\(base).kestrel-audio.json"', 1),
    ],
    "Sources/Audio/AudioVADCalibrationView.swift": [
        ("calibraci\u00f3n de ToshLLM.", "calibraci\u00f3n de Kestrel.", 1),
        ("applies a ToshLLM calibration.", "applies a Kestrel calibration.", 1),
        ('loc.t("ToshLLM ajusta la sensibilidad', 'loc.t("Kestrel ajusta la sensibilidad', 1),
        ('"ToshLLM adjusts speech sensitivity', '"Kestrel adjusts speech sensitivity', 1),
    ],
    "Sources/Audio/AudioStudioController.swift": [
        ('.appending(path: "ToshLLM", directoryHint: .isDirectory)',
         '.appending(path: "Kestrel", directoryHint: .isDirectory)', 1),
        ('"ToshLLM-audio-\\(id.uuidString)"', '"Kestrel-audio-\\(id.uuidString)"', 1),
        ('"ToshLLM-vad-preview-\\(id.uuidString)"', '"Kestrel-vad-preview-\\(id.uuidString)"', 1),
    ],
    "Sources/Audio/AudioRecorder.swift": [
        ('"ToshLLM-recording-\\(UUID().uuidString).wav"', '"Kestrel-recording-\\(UUID().uuidString).wav"', 1),
    ],
    "Sources/Audio/SpeechDictation.swift": [
        ('error = "No se encontr\u00f3 el motor de Whisper.cpp. Vuelve a instalar ToshLLM / the Whisper.cpp engine is missing. Reinstall ToshLLM."',
         'error = "No se encontr\u00f3 el motor de Whisper.cpp. Vuelve a instalar Kestrel / the Whisper.cpp engine is missing. Reinstall Kestrel."', 2),
        ('"ToshLLM-whisper-\\(UUID().uuidString).wav"', '"Kestrel-whisper-\\(UUID().uuidString).wav"', 2),
        ('"ToshLLM-transcript-\\(UUID().uuidString)"', '"Kestrel-transcript-\\(UUID().uuidString)"', 1),
        ('let boundary = "ToshLLM-\\(UUID().uuidString)"', 'let boundary = "Kestrel-\\(UUID().uuidString)"', 1),
    ],
    "Sources/Workspace/WorkspaceSidebar.swift": [
        ("ToshLLMLogo(size: 38)", "KestrelLogo(size: 38)", 1),
        ('Text("ToshLLM").font', 'Text("Kestrel").font', 1),
        ('Text("ToshLLM \u00b7 macOS")', 'Text("Kestrel \u00b7 macOS")', 1),
    ],
    "Sources/Hardware/DflashControl.swift": [("ToshDropdown", "KestrelDropdown", 1)],
    "Sources/Hardware/MTPControl.swift": [("ToshDropdown", "KestrelDropdown", 1)],
    "Sources/Hardware/VisionProjectorControl.swift": [("ToshDropdown", "KestrelDropdown", 2)],
    "Sources/Hardware/DflashMemoryWarningSheet.swift": [
        ("para que ToshLLM elija una configuraci\u00f3n segura", "para que Kestrel elija una configuraci\u00f3n segura", 1),
        ("so ToshLLM can choose a safe configuration", "so Kestrel can choose a safe configuration", 1),
    ],
}

FORBIDDEN_SUBSTRINGS = [
    ("TOSH_", "TOSH_ env var (must not appear inside an old-string pattern)"),
    ("Hackintosh", "Hackintosh false positive"),
    ("notesToShow", "notesToShow false positive"),
]

def main():
    # Validate every old pattern against forbidden substrings.
    for rel, edits in EDITS.items():
        for old, new, cnt in edits:
            for bad, why in FORBIDDEN_SUBSTRINGS:
                if bad in old:
                    sys.exit(f"FATAL: pattern for {rel} contains forbidden {bad}: {old!r}")

    changed = []
    # Apply per-file edits.
    for rel, edits in EDITS.items():
        p = ROOT / rel
        text = p.read_text(encoding="utf-8")
        if "\r" in text:
            sys.exit(f"FATAL: CRLF line endings in {rel}")
        for old, new, cnt in edits:
            found = text.count(old)
            if found != cnt:
                sys.exit(f"FATAL: {rel}: expected {cnt} of {old!r}, found {found}")
            text = text.replace(old, new)
        with open(p, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        changed.append(rel)

    # Apply headers to every scope file that contains them (exact line forms).
    scope_dirs = ["Sources/Models", "Sources/Benchmarks", "Sources/Images",
                  "Sources/Audio", "Sources/Workspace", "Sources/DynamicMoE",
                  "Sources/Hardware"]
    header_files = []
    for d in scope_dirs:
        for p in sorted((ROOT / d).rglob("*.swift")):
            rel = str(p.relative_to(ROOT))
            text = p.read_text(encoding="utf-8")
            if "\r" in text:
                sys.exit(f"FATAL: CRLF line endings in {rel}")
            mod = False
            for o, n in ((HDR1_OLD, HDR1_NEW), (HDR2_OLD, HDR2_NEW)):
                c = text.count(o)
                if c > 1:
                    sys.exit(f"FATAL: {rel}: header appears {c}x: {o!r}")
                if c == 1:
                    text = text.replace(o, n)
                    mod = True
            if mod:
                with open(p, "w", encoding="utf-8", newline="") as f:
                    f.write(text)
                header_files.append(rel)

    all_changed = sorted(set(changed) | set(header_files))
    print(f"OK: {len(changed)} body-edit files + {len(header_files)} header files -> {len(all_changed)} unique files changed")
    for r in all_changed:
        print(f"  {r}")

if __name__ == "__main__":
    main()
