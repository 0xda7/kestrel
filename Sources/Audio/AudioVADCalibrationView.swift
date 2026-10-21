// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct AudioVADCalibrationView: View {
    @EnvironmentObject private var loc: Localizer

    @AppStorage(SettingsKeys.audioVADMode) private var modeRaw = AudioVADMode.defaultMode.rawValue
    @AppStorage(SettingsKeys.audioVADProfile) private var profileRaw = AudioVADProfile.defaultProfile.rawValue
    // Declared defaults single-sourced from the balanced profile — the same
    // fallback AudioVADPreferences reads (W4-4: two literal copies could drift).
    @AppStorage(SettingsKeys.audioVADThreshold) private var threshold = AudioVADProfile.balanced.calibration.threshold
    @AppStorage(SettingsKeys.audioVADMinSpeechMS) private var minSpeechMS = Double(AudioVADProfile.balanced.calibration.minSpeechDurationMS)
    @AppStorage(SettingsKeys.audioVADMinSilenceMS) private var minSilenceMS = Double(AudioVADProfile.balanced.calibration.minSilenceDurationMS)
    @AppStorage(SettingsKeys.audioVADMaxSpeechSeconds) private var maxSpeechSeconds = AudioVADProfile.balanced.calibration.maxSpeechDurationSeconds
    @AppStorage(SettingsKeys.audioVADSpeechPadMS) private var speechPadMS = Double(AudioVADProfile.balanced.calibration.speechPadMS)

    private var profile: AudioVADProfile {
        AudioVADProfile(rawValue: profileRaw) ?? .defaultProfile
    }

    private var mode: AudioVADMode {
        AudioVADMode(rawValue: modeRaw) ?? .defaultMode
    }

    private var calibration: AudioVADCalibration {
        if profile == .custom {
            .custom(threshold: threshold, minSpeechDurationMS: minSpeechMS,
                    minSilenceDurationMS: minSilenceMS,
                    maxSpeechDurationSeconds: maxSpeechSeconds,
                    speechPadMS: speechPadMS)
        } else {
            profile.calibration
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(loc.t("Detección de voz", "Voice detection"), selection: $modeRaw) {
                ForEach(AudioVADMode.allCases) { item in
                    Text(modeName(item)).tag(item.rawValue)
                }
            }
            .help(loc.t("Desactiva VAD, usa los valores nativos de Whisper.cpp o aplica una calibración de Kestrel.",
                        "Disables VAD, uses Whisper.cpp native values, or applies a Kestrel calibration."))

            Text(modeDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            if mode == .calibrated {
                Picker(loc.t("Calibración", "Calibration"), selection: $profileRaw) {
                    ForEach(AudioVADProfile.allCases) { item in
                        Text(profileName(item)).tag(item.rawValue)
                    }
                }
                .help(loc.t("Cambia cuánto debe parecerse una señal a voz antes de enviarla a Whisper.",
                            "Changes how strongly a signal must resemble speech before it is sent to Whisper."))

                Text(profileDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if profile == .custom {
                    AudioVADCustomControls(
                        threshold: $threshold, minSpeechMS: $minSpeechMS,
                        minSilenceMS: $minSilenceMS,
                        maxSpeechSeconds: $maxSpeechSeconds, speechPadMS: $speechPadMS
                    )
                }

                LabeledContent(loc.t("Umbral", "Threshold")) {
                    Text(calibration.threshold,
                         format: .number.precision(.fractionLength(2)))
                        .monospacedDigit()
                }
                .font(.caption)

                Label(loc.t("VAD reduce voces débiles, pero no puede aislar una voz principal si el fondo también se oye con claridad.",
                            "VAD reduces weak voices, but cannot isolate a main voice when background speech is also clearly audible."),
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help(loc.t("Para separar voces superpuestas haría falta un proceso distinto de separación de fuentes.",
                                "Separating overlapping voices would require a different source-separation process."))
            }
        }
    }

    private var modeDescription: String {
        switch mode {
        case .disabled:
            loc.t("Whisper procesa el audio completo, incluidos los silencios.",
                  "Whisper processes the complete audio, including silence.")
        case .standard:
            loc.t("Silero VAD usa los valores predeterminados de Whisper.cpp, sin calibración añadida.",
                  "Silero VAD uses Whisper.cpp defaults with no added calibration.")
        case .calibrated:
            loc.t("Kestrel ajusta la sensibilidad y los cortes de voz con el perfil elegido.",
                  "Kestrel adjusts speech sensitivity and segmentation with the selected profile.")
        }
    }

    private func modeName(_ mode: AudioVADMode) -> String {
        switch mode {
        case .disabled: loc.t("Desactivado", "Disabled")
        case .standard: loc.t("Predeterminado de Whisper", "Whisper default")
        case .calibrated: loc.t("Calibrado", "Calibrated")
        }
    }

    private var profileDescription: String {
        switch profile {
        case .sensitive:
            loc.t("Conserva voces suaves y fragmentos breves; puede aceptar más fondo.",
                  "Keeps quiet voices and brief fragments; may accept more background speech.")
        case .balanced:
            loc.t("Adecuado para reuniones y grabaciones limpias.",
                  "Suitable for meetings and clean recordings.")
        case .strict:
            loc.t("Exige voz más clara y sostenida; no separa voces de fondo que sigan siendo inteligibles.",
                  "Requires clearer, sustained speech; it does not separate background voices that remain intelligible.")
        case .custom:
            loc.t("Control manual de la detección y los cortes de voz.",
                  "Manual control over speech detection and segmentation.")
        }
    }

    private func profileName(_ profile: AudioVADProfile) -> String {
        switch profile {
        case .sensitive: loc.t("Sensible", "Sensitive")
        case .balanced: loc.t("Equilibrado", "Balanced")
        case .strict: loc.t("Estricto", "Strict")
        case .custom: loc.t("Personalizado", "Custom")
        }
    }

}
