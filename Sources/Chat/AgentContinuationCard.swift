// Kestrel - run LLMs locally on Intel Macs with AMD GPUs
// Copyright (C) 2026 Northlatch Labs <opensource@northlatchlabs.com>
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct AgentContinuationCard: View {
    let continueAction: () -> Void
    let stopAction: () -> Void
    var turnsUsed: Int?
    var toolsExecuted: Int?
    @EnvironmentObject private var loc: Localizer

    private var summary: String? {
        guard let turnsUsed else { return nil }
        let tools = toolsExecuted ?? 0
        return loc.t(
            "Ha usado \(turnsUsed) turnos y \(tools) herramientas.",
            "It used \(turnsUsed) turns and \(tools) tools.")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(loc.t("El agente alcanzó el límite de 8 turnos. ¿Continuar?",
                        "The agent reached its 8-turn limit. Continue?"),
                  systemImage: "arrow.clockwise.circle")
                .font(.callout)
            if let summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button(loc.t("Continuar", "Continue"), systemImage: "play.fill",
                       action: continueAction)
                    .buttonStyle(.borderedProminent)
                Button(loc.t("Detener", "Stop"), systemImage: "stop.fill",
                       role: .destructive, action: stopAction)
                    .glassButton()
            }
        }
        .padding(12)
        .frame(maxWidth: 560, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.secondary.opacity(0.25)))
        .accessibilityElement(children: .contain)
    }
}
