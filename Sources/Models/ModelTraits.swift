// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import os

/// What a downloaded GGUF brings with it: experts, vision projector, MTP head, DFlash draft.
struct ModelTraits {
    let isMoE: Bool
    let hasVision: Bool
    let hasMTP: Bool
    let hasDflash: Bool

    /// Shown until the background warm has read the header.
    static let unknown = ModelTraits(isMoE: false, hasVision: false, hasMTP: false, hasDflash: false)

    static func of(path: String) -> ModelTraits {
        ModelTraits(isMoE: ServerSettings.modelIsMoE(at: path),
                    hasVision: ServerSettings.mmprojPath(forModel: path) != nil,
                    hasMTP: ServerSettings.modelUsesMTP(at: path),
                    hasDflash: ServerSettings.dflashDraftPath(forModel: path) != nil)
    }

    /// Compact markers for menu rows, where a badge can't be drawn.
    func pickerSuffix(spanish: Bool) -> String {
        var marks: [String] = []
        if isMoE { marks.append("MoE") }
        if hasVision { marks.append(spanish ? "Visión" : "Vision") }
        if hasMTP { marks.append("MTP") }
        if hasDflash { marks.append("DFlash") }
        return marks.isEmpty ? "" : "  ·  " + marks.joined(separator: " · ")
    }
}

/// Each read hits the file system and the GGUF header, and every model card and
/// model menu asks on redraw, so results are held until the folder is rescanned.
enum ModelTraitsCache {
    private static let entries = OSAllocatedUnfairLock<[String: ModelTraits]>(initialState: [:])

    static func traits(for path: String) -> ModelTraits {
        if let cached = entries.withLock({ $0[path] }) {
            return cached
        }
        let traits = ModelTraits.of(path: path)
        entries.withLock { $0[path] = traits }
        return traits
    }

    /// For view bodies: never reads the header, so drawing cannot block on it.
    static func cached(for path: String) -> ModelTraits? {
        entries.withLock { $0[path] }
    }

    static func warm(paths: [String], then done: @escaping () -> Void) {
        DispatchQueue.global(qos: .utility).async {
            for path in paths {
                autoreleasepool {
                    _ = traits(for: path)
                }
            }
            DispatchQueue.main.async(execute: done)
        }
    }

    static func invalidate() {
        entries.withLock { $0.removeAll() }
    }
}

struct ModelTraitBadges: View {
    let traits: ModelTraits
    @EnvironmentObject var loc: Localizer

    var body: some View {
        if traits.isMoE {
            TagBadge(text: "MoE", icon: "square.stack.3d.up", color: .appAccent)
                .help(loc.t("Mezcla de expertos: puedes descargar parte de los expertos a la RAM.",
                            "Mixture of experts: some experts can be offloaded to RAM."))
        }
        if traits.hasVision {
            TagBadge(text: loc.t("Visión", "Vision"), icon: "eye", color: .purple)
                .help(loc.t("Lee imágenes: tiene su proyector (mmproj) emparejado.",
                            "Reads images: its projector (mmproj) is paired."))
        }
        if traits.hasMTP {
            TagBadge(text: "MTP", icon: "hare", color: .green)
                .help(loc.t("El GGUF trae el cabezal de predicción multi-token: la decodificación especulativa se activa sola cuando conviene.",
                            "The GGUF ships the multi-token prediction head: speculative decoding turns on by itself when it pays off."))
        }
        if traits.hasDflash {
            TagBadge(text: "DFlash", icon: "bolt", color: .orange)
                .help(loc.t("Tiene descargado su modelo borrador DFlash para decodificación especulativa.",
                            "Its DFlash draft model for speculative decoding is downloaded."))
        }
    }
}
